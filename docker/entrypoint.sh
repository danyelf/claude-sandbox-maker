#!/bin/bash
# Multi-Agent Entrypoint Script
# Runs the autonomous agent loop for task coordination

set -euo pipefail

AGENT_ID="${AGENT_ID:-agent}"
AGENT_MODE="${AGENT_MODE:-autonomous}"
MAX_PUSH_RETRIES=3
PUSH_RETRY_DELAY=5
MAX_IDLE_CYCLES=10  # Exit after this many cycles with no work

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$AGENT_ID] $*"
}

error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$AGENT_ID] ERROR: $*" >&2
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

    # Try to claim it
    if bd update "$task_id" --status in_progress --assignee "$AGENT_ID" 2>/dev/null; then
        bd sync 2>/dev/null || true

        # Verify we got it (another agent might have claimed it)
        local assignee
        assignee=$(bd show "$task_id" --json 2>/dev/null | jq -r '.assignee // empty')

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
    git fetch origin main

    # Clean up any existing worktree
    if [ -d "$worktree_path" ]; then
        git worktree remove "$worktree_path" --force 2>/dev/null || true
    fi

    # Create fresh worktree
    git worktree add "$worktree_path" -b "$branch_name" origin/main

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
    task_title=$(bd show "$task_id" --json 2>/dev/null | jq -r '.title // "Unknown task"')
    task_desc=$(bd show "$task_id" --json 2>/dev/null | jq -r '.description // ""')

    log "Starting work on: $task_title"

    # Run Claude Code in non-interactive mode
    local prompt="You are working on task $task_id: $task_title

$task_desc

Complete this task. When done, commit your changes with a descriptive message.
Do not push - that will be handled separately.
If you cannot complete the task, explain why in a comment."

    # Execute Claude Code
    if claude --dangerously-skip-permissions -p "$prompt" 2>&1; then
        log "Claude completed work on $task_id"
        return 0
    else
        error "Claude failed on $task_id"
        return 1
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
        error "Rebase failed - conflicts detected"
        git rebase --abort 2>/dev/null || true
        return 1
    fi

    # Run tests if they exist
    if [ -f "package.json" ] && grep -q '"test"' package.json; then
        log "Running tests..."
        if ! npm test 2>&1; then
            error "Tests failed after rebase"
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
    return 1
}

# Clean up after task completion
cleanup() {
    local task_id="$1"
    local worktree_path="$2"
    local success="$3"
    local branch_name="${AGENT_ID}/${task_id}"

    cd /workspace/main

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
        log "Marking task $task_id as blocked"
        bd comments add "$task_id" "Agent $AGENT_ID encountered an error and could not complete this task" 2>/dev/null || true
        bd update "$task_id" --status blocked 2>/dev/null || true
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

# Interactive mode - just start a shell
interactive_mode() {
    log "Starting interactive mode"
    exec /bin/bash
}

# Main
main() {
    log "Starting agent in $AGENT_MODE mode"

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
