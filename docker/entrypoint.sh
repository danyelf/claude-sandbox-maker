#!/bin/bash
# Multi-Agent Entrypoint Script
# Runs the autonomous agent loop for task coordination

set -euo pipefail

AGENT_ID="${AGENT_ID:-agent}"
AGENT_MODE="${AGENT_MODE:-autonomous}"
MAX_PUSH_RETRIES=3
PUSH_RETRY_DELAY=5
MAX_IDLE_CYCLES=10  # Exit after this many cycles with no work

# Status directory for agent coordination
CSB_DIR="/workspace/.csb"
AGENT_STATUS_DIR="${CSB_DIR}/${AGENT_ID}"

# Failure context (set by finalize_work for cleanup to use)
FAILURE_REASON=""
FAILURE_DETAILS=""

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$AGENT_ID] $*" >&2
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$AGENT_ID] ERROR: $*" >&2
}

# Set up status directory for this agent
setup_status_dir() {
    mkdir -p "$AGENT_STATUS_DIR"
    log "Status directory: $AGENT_STATUS_DIR"
}

# Write agent status for dashboard polling
# Usage: write_status <status> [task_id]
# Status values: idle, working, needs_approval, blocked
write_status() {
    local status="$1"
    local task_id="${2:-}"

    echo "$status" > "$AGENT_STATUS_DIR/status"

    if [ -n "$task_id" ]; then
        echo "$task_id" > "$AGENT_STATUS_DIR/task"
    fi
}

# Write output to both stderr (logs) and output.log (dashboard)
# Usage: tee_output <message>
tee_output() {
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Write to stderr with full log format
    echo "[$timestamp] [$AGENT_ID] $message" >&2

    # Append to output.log for dashboard (without timestamp for cleaner display)
    echo "$message" >> "$AGENT_STATUS_DIR/output.log"
}

# Clear the output log (call when starting new task)
clear_output_log() {
    : > "$AGENT_STATUS_DIR/output.log"
}

# Write approval request for dashboard to display
# Creates approval/ directory with type, diff, and message files
# Usage: write_approval_request <task_type>
write_approval_request() {
    local task_type="$1"
    local approval_dir="$AGENT_STATUS_DIR/approval"

    mkdir -p "$approval_dir"

    # Write task type
    echo "$task_type" > "$approval_dir/type"

    # Write git diff (staged and unstaged changes compared to origin/main)
    git diff origin/main...HEAD > "$approval_dir/diff" 2>/dev/null || true

    # Write commit message (most recent commit on this branch)
    git log -1 --format='%s%n%n%b' > "$approval_dir/message" 2>/dev/null || true

    log "Approval request written to $approval_dir"
}

# Wait for approval response from dashboard
# Polls for response file and returns its contents
# Usage: wait_for_approval
# Returns: "approved" or "rejected" (or empty if timeout/error)
wait_for_approval() {
    local approval_dir="$AGENT_STATUS_DIR/approval"
    local response_file="$approval_dir/response"
    local poll_interval=2

    log "Waiting for approval..."

    while true; do
        if [ -f "$response_file" ]; then
            local response
            response=$(cat "$response_file")
            log "Received approval response: $response"
            echo "$response"
            return 0
        fi

        sleep "$poll_interval"
    done
}

# Clear approval request files after processing
# Usage: clear_approval_request
clear_approval_request() {
    local approval_dir="$AGENT_STATUS_DIR/approval"

    if [ -d "$approval_dir" ]; then
        rm -rf "$approval_dir"
        log "Cleared approval request"
    fi
}

# Get the task type from beads
# Usage: get_task_type <task_id>
# Returns: feature, bug, chore, refactor, task, epic, etc.
get_task_type() {
    local task_id="$1"
    bd show "$task_id" --json 2>/dev/null | jq -r '.[0].issue_type // "unknown"'
}

# Check if a task type requires human approval before merging
# Usage: requires_approval <task_type>
# Returns: 0 (true) for features/bugs, 1 (false) for chores/refactors
requires_approval() {
    local task_type="$1"
    case "$task_type" in
        feature|bug)
            return 0  # Requires approval
            ;;
        *)
            return 1  # Auto-merge allowed
            ;;
    esac
}

# Get list of conflicting files during a failed rebase/merge
get_conflict_files() {
    git diff --name-only --diff-filter=U 2>/dev/null | tr '\n' ', ' | sed 's/,$//'
}

# Get a summary of the conflict situation
get_conflict_summary() {
    local conflict_files
    conflict_files=$(get_conflict_files)

    if [ -n "$conflict_files" ]; then
        echo "Conflicting files: $conflict_files"
    else
        echo "Unable to determine conflicting files"
    fi
}

# Configure git identity for this agent
setup_git() {
    cd /workspace/main
    git config user.name "$AGENT_ID"
    git config user.email "${AGENT_ID}@agent.local"

    # Configure credential helper for GITHUB_TOKEN
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        git config credential.helper '!f() { echo "password=${GITHUB_TOKEN}"; }; f'
    fi

    log "Git configured for $AGENT_ID"
}

# Find and claim a task
claim_task() {
    local task_id

    # Get first available task
    task_id=$(bd ready --json 2>/dev/null | jq -r '.[0].id // empty')

    if [ -z "$task_id" ]; then
        return 1  # No work available
    fi

    log "Attempting to claim task: $task_id"

    # Try to claim it (redirect all output to avoid capture)
    if bd update "$task_id" --status in_progress --assignee "$AGENT_ID" >/dev/null 2>&1; then
        bd sync >/dev/null 2>&1 || true

        # Verify we got it (another agent might have claimed it)
        local assignee
        assignee=$(bd show "$task_id" --json 2>/dev/null | jq -r '.[0].assignee // empty')

        if [ "$assignee" = "$AGENT_ID" ]; then
            log "Successfully claimed task: $task_id"
            echo "$task_id"
            return 0
        else
            log "Task $task_id claimed by another agent ($assignee)"
            return 1
        fi
    fi

    return 1
}

# Set up worktree for a task
setup_worktree() {
    local task_id="$1"
    local worktree_path="/workspace/$AGENT_ID"
    local branch_name="${AGENT_ID}/${task_id}"

    cd /workspace/main
    git fetch origin main >/dev/null 2>&1

    # Clean up any existing worktree
    if [ -d "$worktree_path" ]; then
        git worktree remove "$worktree_path" --force >/dev/null 2>&1 || true
    fi

    # Create fresh worktree (redirect git output to avoid capture)
    git worktree add "$worktree_path" -b "$branch_name" origin/main >/dev/null 2>&1

    log "Created worktree at $worktree_path on branch $branch_name"
    echo "$worktree_path"
}

# Run Claude to do the actual work
do_work() {
    local task_id="$1"
    local worktree_path="$2"

    cd "$worktree_path"

    # Get task details for the prompt
    local task_title task_desc
    task_title=$(bd show "$task_id" --json 2>/dev/null | jq -r '.[0].title // "Unknown task"')
    task_desc=$(bd show "$task_id" --json 2>/dev/null | jq -r '.[0].description // ""')

    # Clear output log and update status for dashboard
    clear_output_log
    write_status "working" "$task_id"
    tee_output "Starting work on: $task_title"

    # Build the prompt based on mode
    local prompt
    if [ "$AGENT_MODE" = "interactive" ]; then
        # In interactive mode, stop before merging so human can review/approve
        prompt="You are working on task $task_id: $task_title

$task_desc

Complete this task. When done:
1. Commit your changes with a descriptive message
2. STOP - do not merge or push

Wait for approval before proceeding with merge. The human will review your changes and either approve or request changes via 'claude --continue'."
    else
        # Autonomous mode - complete the full task
        prompt="You are working on task $task_id: $task_title

$task_desc

Complete this task. When done, commit your changes with a descriptive message.
Do not push - that will be handled separately.
If you cannot complete the task, explain why in a comment."
    fi

    # Execute Claude Code with output captured for dashboard
    local exit_code=0
    if claude --dangerously-skip-permissions -p "$prompt" 2>&1 | tee -a "$AGENT_STATUS_DIR/output.log"; then
        tee_output "Claude completed work on $task_id"
        return 0
    else
        exit_code=$?
        tee_output "ERROR: Claude failed on $task_id"
        FAILURE_REASON="claude_failed"
        FAILURE_DETAILS="Claude Code failed to complete the task. This may require manual intervention or the task may need to be broken down into smaller pieces."
        return $exit_code
    fi
}

# Resume Claude session after approval to proceed with merge and push
# Usage: continue_with_merge <task_id> <worktree_path>
continue_with_merge() {
    local task_id="$1"
    local worktree_path="$2"

    cd "$worktree_path"

    tee_output "Resuming Claude to merge approved changes for $task_id"

    local prompt="Your changes have been APPROVED. Please proceed with:
1. Rebase onto origin/main (git fetch origin main && git rebase origin/main)
2. Merge to main using fast-forward only
3. Push to origin

If you encounter conflicts during rebase, abort and report the issue."

    local exit_code=0
    if claude --dangerously-skip-permissions --continue -p "$prompt" 2>&1 | tee -a "$AGENT_STATUS_DIR/output.log"; then
        tee_output "Claude completed merge for $task_id"
        return 0
    else
        exit_code=$?
        tee_output "ERROR: Claude failed to merge $task_id"
        FAILURE_REASON="merge_failed"
        FAILURE_DETAILS="Claude Code failed to complete the merge after approval. Manual intervention may be required."
        return $exit_code
    fi
}

# Resume Claude session after rejection with feedback to make changes
# Usage: continue_with_feedback <task_id> <worktree_path> <feedback>
continue_with_feedback() {
    local task_id="$1"
    local worktree_path="$2"
    local feedback="$3"

    cd "$worktree_path"

    tee_output "Resuming Claude with feedback for $task_id"

    local prompt="Your changes were REJECTED with the following feedback:

$feedback

Please:
1. Review the feedback carefully
2. Make the requested changes
3. Commit your updates with a descriptive message
4. STOP - do not merge or push

Wait for approval again after making changes."

    local exit_code=0
    if claude --dangerously-skip-permissions --continue -p "$prompt" 2>&1 | tee -a "$AGENT_STATUS_DIR/output.log"; then
        tee_output "Claude completed revisions for $task_id"
        return 0
    else
        exit_code=$?
        tee_output "ERROR: Claude failed to apply feedback for $task_id"
        FAILURE_REASON="revision_failed"
        FAILURE_DETAILS="Claude Code failed to apply the requested changes from feedback. The task may need manual intervention."
        return $exit_code
    fi
}

# Rebase, test, merge, and push
finalize_work() {
    local task_id="$1"
    local worktree_path="$2"
    local branch_name="${AGENT_ID}/${task_id}"

    cd "$worktree_path"

    # Rebase onto latest main
    log "Rebasing onto origin/main..."
    git fetch origin main

    if ! git rebase origin/main; then
        local conflict_summary
        conflict_summary=$(get_conflict_summary)
        error "Rebase failed - conflicts detected"
        error "$conflict_summary"

        FAILURE_REASON="merge_conflict"
        FAILURE_DETAILS="Rebase onto origin/main failed. $conflict_summary. Agent cannot automatically resolve these conflicts."

        git rebase --abort 2>/dev/null || true
        return 1
    fi

    # Run tests if they exist
    if [ -f "package.json" ] && grep -q '"test"' package.json; then
        log "Running tests..."
        if ! npm test 2>&1; then
            error "Tests failed after rebase"
            FAILURE_REASON="test_failure"
            FAILURE_DETAILS="Tests failed after rebasing onto origin/main. The changes may have introduced breaking behavior or conflicted with recent changes in main."
            return 1
        fi
    fi

    # Merge to main (ff-only)
    cd /workspace/main
    git fetch origin main
    git checkout main
    git pull origin main

    log "Merging $branch_name to main..."
    if ! git merge --ff-only "$branch_name"; then
        error "Fast-forward merge failed"
        FAILURE_REASON="merge_failed"
        FAILURE_DETAILS="Fast-forward merge of $branch_name to main failed. Main branch has diverged since the rebase. This may indicate a race condition with another agent."
        return 1
    fi

    # Push with retries
    local attempt=1
    while [ $attempt -le $MAX_PUSH_RETRIES ]; do
        log "Push attempt $attempt/$MAX_PUSH_RETRIES..."

        if git push origin main; then
            log "Push successful"
            return 0
        fi

        # Pull and retry
        log "Push failed, pulling and retrying..."
        git pull --rebase origin main

        attempt=$((attempt + 1))
        sleep $PUSH_RETRY_DELAY
    done

    error "Push failed after $MAX_PUSH_RETRIES attempts"
    FAILURE_REASON="push_failed"
    FAILURE_DETAILS="Push to origin/main failed after $MAX_PUSH_RETRIES attempts with ${PUSH_RETRY_DELAY}s delays between retries. This may indicate persistent conflicts with other agents or remote access issues."
    return 1
}

# Clean up after task completion
cleanup() {
    local task_id="$1"
    local worktree_path="$2"
    local success="$3"
    local branch_name="${AGENT_ID}/${task_id}"

    cd /workspace/main

    # Clear any pending approval request
    clear_approval_request

    # Remove worktree
    if [ -d "$worktree_path" ]; then
        git worktree remove "$worktree_path" --force 2>/dev/null || true
    fi

    # Remove branch
    git branch -D "$branch_name" 2>/dev/null || true

    if [ "$success" = "true" ]; then
        log "Closing task $task_id"
        bd close "$task_id" 2>/dev/null || true
    else
        log "Marking task $task_id as blocked (reason: ${FAILURE_REASON:-unknown})"

        # Build detailed comment based on failure reason
        local comment
        if [ -n "$FAILURE_DETAILS" ]; then
            comment="[Agent $AGENT_ID] $FAILURE_DETAILS"
        else
            comment="[Agent $AGENT_ID] Encountered an error and could not complete this task."
        fi

        bd comments add "$task_id" "$comment" 2>/dev/null || true
        bd update "$task_id" --status blocked 2>/dev/null || true

        # Reset failure context for next task
        FAILURE_REASON=""
        FAILURE_DETAILS=""
    fi

    bd sync 2>/dev/null || true
}

# Main agent loop
agent_loop() {
    local idle_count=0

    while true; do
        log "Looking for work..."

        local task_id
        if task_id=$(claim_task); then
            idle_count=0

            local worktree_path
            if worktree_path=$(setup_worktree "$task_id"); then
                local success="false"

                if do_work "$task_id" "$worktree_path"; then
                    if finalize_work "$task_id" "$worktree_path"; then
                        success="true"
                    fi
                fi

                cleanup "$task_id" "$worktree_path" "$success"
            else
                error "Failed to set up worktree for $task_id"
                FAILURE_REASON="worktree_failed"
                FAILURE_DETAILS="Failed to set up git worktree for this task. This may indicate git repository issues or disk space problems."
                cleanup "$task_id" "" "false"
            fi
        else
            idle_count=$((idle_count + 1))
            log "No work available (idle: $idle_count/$MAX_IDLE_CYCLES)"

            if [ $idle_count -ge $MAX_IDLE_CYCLES ]; then
                log "Max idle cycles reached, exiting"
                break
            fi

            sleep 30
        fi
    done
}

# Interactive agent loop - works on one task with approval gates
# Unlike agent_loop(), this processes a single task and exits
interactive_agent_loop() {
    log "Looking for work..."
    write_status "idle"

    local task_id
    if ! task_id=$(claim_task); then
        log "No work available"
        write_status "idle"
        return 0
    fi

    local worktree_path
    if ! worktree_path=$(setup_worktree "$task_id"); then
        error "Failed to set up worktree for $task_id"
        FAILURE_REASON="worktree_failed"
        FAILURE_DETAILS="Failed to set up git worktree for this task. This may indicate git repository issues or disk space problems."
        cleanup "$task_id" "" "false"
        return 1
    fi

    local success="false"

    # Do the work (Claude implements the task)
    if ! do_work "$task_id" "$worktree_path"; then
        cleanup "$task_id" "$worktree_path" "$success"
        return 1
    fi

    # Check task type to determine if approval is needed
    local task_type
    task_type=$(get_task_type "$task_id")
    log "Task type: $task_type"

    if requires_approval "$task_type"; then
        # Features and bugs require human approval
        log "Task requires approval (type: $task_type)"
        write_status "needs_approval" "$task_id"
        write_approval_request "$task_type"

        # Wait for human response
        local response
        response=$(wait_for_approval)
        clear_approval_request

        if [ "$response" = "approved" ]; then
            log "Changes approved, proceeding with merge"
            write_status "working" "$task_id"

            if continue_with_merge "$task_id" "$worktree_path"; then
                success="true"
            fi
        else
            # Response is feedback - extract it from the approval directory
            local feedback_file="$AGENT_STATUS_DIR/approval/feedback"
            local feedback=""
            if [ -f "$feedback_file" ]; then
                feedback=$(cat "$feedback_file")
            else
                feedback="$response"
            fi

            log "Changes rejected, applying feedback"
            write_status "working" "$task_id"

            if continue_with_feedback "$task_id" "$worktree_path" "$feedback"; then
                # After applying feedback, need approval again
                # Recursively wait for approval (simplified: just re-request)
                write_status "needs_approval" "$task_id"
                write_approval_request "$task_type"

                response=$(wait_for_approval)
                clear_approval_request

                if [ "$response" = "approved" ]; then
                    write_status "working" "$task_id"
                    if continue_with_merge "$task_id" "$worktree_path"; then
                        success="true"
                    fi
                fi
            fi
        fi
    else
        # Chores and refactors auto-merge
        log "Task auto-merging (type: $task_type)"

        if finalize_work "$task_id" "$worktree_path"; then
            success="true"
        fi
    fi

    cleanup "$task_id" "$worktree_path" "$success"

    if [ "$success" = "true" ]; then
        return 0
    else
        return 1
    fi
}

# Interactive mode - run the interactive agent loop
interactive_mode() {
    log "Starting interactive mode"
    interactive_agent_loop
}

# Main
main() {
    log "Starting agent in $AGENT_MODE mode"

    setup_status_dir
    setup_git

    case "$AGENT_MODE" in
        autonomous)
            agent_loop
            ;;
        interactive)
            interactive_mode
            ;;
        *)
            error "Unknown mode: $AGENT_MODE"
            exit 1
            ;;
    esac
}

main "$@"
