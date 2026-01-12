# Phase 1: Agent-Side Approval Gate Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Modify entrypoint.sh to support interactive mode with human approval gate for features/bugs before merge.

**Architecture:** Add status directory management and approval flow to the existing agent loop. Interactive mode writes status files that a dashboard (Phase 2) will read. Features/bugs pause and wait for approval; chores/refactors auto-merge.

**Tech Stack:** Bash, beads CLI, file-based IPC

---

## Task 1: Add CSB Status Directory Setup

**Files:**
- Modify: `docker/entrypoint.sh:1-20` (add after AGENT_MODE line)

**Step 1: Add CSB_DIR constant and setup function**

Add after line 12 (after `MAX_IDLE_CYCLES=10`):

```bash
# Status directory for dashboard communication
CSB_DIR="/workspace/.csb"
AGENT_STATUS_DIR="${CSB_DIR}/${AGENT_ID}"
```

Add new function after `error()` function (around line 24):

```bash
# Set up status directory for dashboard communication
setup_status_dir() {
    mkdir -p "${AGENT_STATUS_DIR}/approval"
    echo "idle" > "${AGENT_STATUS_DIR}/status"
    echo "" > "${AGENT_STATUS_DIR}/task"
    : > "${AGENT_STATUS_DIR}/output.log"
    log "Status directory created: ${AGENT_STATUS_DIR}"
}
```

**Step 2: Call setup in main()**

In the `main()` function, add after `setup_git`:

```bash
setup_status_dir
```

**Step 3: Verify manually**

```bash
cd /Users/danyel/code/MISC/sbmaker-2/docker
# Check syntax
bash -n entrypoint.sh && echo "Syntax OK"
```

**Step 4: Commit**

```bash
git add docker/entrypoint.sh
git commit -m "feat: add CSB status directory setup for dashboard communication

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 2: Add Status Writing Functions

**Files:**
- Modify: `docker/entrypoint.sh` (add after `setup_status_dir` function)

**Step 1: Add write_status function**

```bash
# Write agent status (idle|working|needs_approval|blocked)
write_status() {
    local status="$1"
    local task_id="${2:-}"
    echo "$status" > "${AGENT_STATUS_DIR}/status"
    echo "$task_id" > "${AGENT_STATUS_DIR}/task"
    log "Status: $status${task_id:+ (task: $task_id)}"
}
```

**Step 2: Add tee_output function for logging**

```bash
# Tee output to both console and log file for dashboard
tee_output() {
    tee -a "${AGENT_STATUS_DIR}/output.log"
}

# Clear output log (call at start of each task)
clear_output_log() {
    : > "${AGENT_STATUS_DIR}/output.log"
}
```

**Step 3: Verify syntax**

```bash
bash -n docker/entrypoint.sh && echo "Syntax OK"
```

**Step 4: Commit**

```bash
git add docker/entrypoint.sh
git commit -m "feat: add status writing functions for dashboard

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 3: Add Task Type Detection

**Files:**
- Modify: `docker/entrypoint.sh` (add after status functions)

**Step 1: Add get_task_type function**

```bash
# Get task type from beads (feature|bug|task|chore|refactor|docs)
get_task_type() {
    local task_id="$1"
    bd show "$task_id" --json 2>/dev/null | jq -r '.[0].type // "task"'
}

# Check if task type requires approval
requires_approval() {
    local task_type="$1"
    case "$task_type" in
        feature|bug)
            return 0  # Requires approval
            ;;
        *)
            return 1  # Auto-merge
            ;;
    esac
}
```

**Step 2: Verify syntax**

```bash
bash -n docker/entrypoint.sh && echo "Syntax OK"
```

**Step 3: Commit**

```bash
git add docker/entrypoint.sh
git commit -m "feat: add task type detection for approval gating

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 4: Add Approval Request and Wait Functions

**Files:**
- Modify: `docker/entrypoint.sh` (add after task type functions)

**Step 1: Add write_approval_request function**

```bash
# Write approval request for dashboard to display
write_approval_request() {
    local task_id="$1"
    local task_type="$2"
    local worktree_path="$3"

    local approval_dir="${AGENT_STATUS_DIR}/approval"

    # Get task title
    local task_title
    task_title=$(bd show "$task_id" --json 2>/dev/null | jq -r '.[0].title // "Unknown"')

    # Write request details
    echo "$task_type" > "${approval_dir}/type"
    echo "$task_title" > "${approval_dir}/title"

    # Get diff summary
    cd "$worktree_path"
    git diff --stat origin/main > "${approval_dir}/diff" 2>/dev/null || true

    # Get commit message (most recent commit)
    git log -1 --format='%s%n%n%b' > "${approval_dir}/message" 2>/dev/null || true

    # Clear any previous response
    rm -f "${approval_dir}/response"

    log "Approval request written for $task_id ($task_type)"
}
```

**Step 2: Add wait_for_approval function**

```bash
# Wait for approval response from dashboard
# Returns 0 if approved, 1 if rejected
wait_for_approval() {
    local response_file="${AGENT_STATUS_DIR}/approval/response"
    local poll_interval=5

    log "Waiting for approval..."

    while true; do
        if [ -f "$response_file" ]; then
            local response
            response=$(cat "$response_file")

            case "$response" in
                approved)
                    log "Approval received"
                    return 0
                    ;;
                rejected)
                    log "Changes rejected"
                    return 1
                    ;;
                *)
                    log "Unknown response: $response"
                    return 1
                    ;;
            esac
        fi

        sleep $poll_interval
    done
}

# Clean up approval directory after handling
clear_approval_request() {
    rm -f "${AGENT_STATUS_DIR}/approval/"*
}
```

**Step 3: Verify syntax**

```bash
bash -n docker/entrypoint.sh && echo "Syntax OK"
```

**Step 4: Commit**

```bash
git add docker/entrypoint.sh
git commit -m "feat: add approval request and wait functions

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 5: Modify do_work for Interactive Mode

**Files:**
- Modify: `docker/entrypoint.sh:112-144` (do_work function)

**Step 1: Update do_work to support --continue pattern**

Replace the `do_work` function with:

```bash
# Run Claude to do the actual work
# In interactive mode, tells Claude to stop before merging
do_work() {
    local task_id="$1"
    local worktree_path="$2"

    cd "$worktree_path"

    # Get task details for the prompt
    local task_title task_desc
    task_title=$(bd show "$task_id" --json 2>/dev/null | jq -r '.[0].title // "Unknown task"')
    task_desc=$(bd show "$task_id" --json 2>/dev/null | jq -r '.[0].description // ""')

    log "Starting work on: $task_title"

    # Build prompt based on mode
    local prompt
    if [ "$AGENT_MODE" = "interactive" ]; then
        prompt="You are working on task $task_id: $task_title

$task_desc

Complete this task. When done, commit your changes with a descriptive message.
IMPORTANT: Do NOT merge or push - stop after committing. The merge will be handled after approval."
    else
        prompt="You are working on task $task_id: $task_title

$task_desc

Complete this task. When done, commit your changes with a descriptive message.
Do not push - that will be handled separately.
If you cannot complete the task, explain why in a comment."
    fi

    # Execute Claude Code, capture output for dashboard
    if [ "$AGENT_MODE" = "interactive" ]; then
        if claude --dangerously-skip-permissions -p "$prompt" 2>&1 | tee_output; then
            log "Claude completed work on $task_id"
            return 0
        else
            error "Claude failed on $task_id"
            FAILURE_REASON="claude_failed"
            FAILURE_DETAILS="Claude Code failed to complete the task."
            return 1
        fi
    else
        if claude --dangerously-skip-permissions -p "$prompt" 2>&1; then
            log "Claude completed work on $task_id"
            return 0
        else
            error "Claude failed on $task_id"
            FAILURE_REASON="claude_failed"
            FAILURE_DETAILS="Claude Code failed to complete the task."
            return 1
        fi
    fi
}
```

**Step 2: Verify syntax**

```bash
bash -n docker/entrypoint.sh && echo "Syntax OK"
```

**Step 3: Commit**

```bash
git add docker/entrypoint.sh
git commit -m "feat: update do_work to support interactive mode

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 6: Add continue_with_merge Function

**Files:**
- Modify: `docker/entrypoint.sh` (add after do_work)

**Step 1: Add function to continue Claude session for merge**

```bash
# Continue Claude session to perform merge (after approval)
continue_with_merge() {
    local task_id="$1"
    local worktree_path="$2"

    cd "$worktree_path"

    log "Continuing Claude session for merge..."

    local prompt="Merge has been approved. Proceed with:
1. Rebase onto origin/main
2. Run tests if available
3. Merge to main (fast-forward)
4. Push to origin

If any step fails, report the error."

    if claude --dangerously-skip-permissions --continue -p "$prompt" 2>&1 | tee_output; then
        log "Merge completed for $task_id"
        return 0
    else
        error "Merge failed for $task_id"
        FAILURE_REASON="merge_failed"
        FAILURE_DETAILS="Claude failed to complete the merge process."
        return 1
    fi
}

# Continue Claude session with rejection feedback
continue_with_feedback() {
    local task_id="$1"
    local worktree_path="$2"

    cd "$worktree_path"

    local feedback_file="${AGENT_STATUS_DIR}/approval/feedback"
    local feedback=""
    if [ -f "$feedback_file" ]; then
        feedback=$(cat "$feedback_file")
    fi

    log "Continuing Claude session with feedback..."

    local prompt="Changes were rejected. Please review and address the following feedback:

$feedback

Make the necessary changes and commit again. Do NOT merge or push."

    if claude --dangerously-skip-permissions --continue -p "$prompt" 2>&1 | tee_output; then
        log "Revisions completed for $task_id"
        return 0
    else
        error "Revision failed for $task_id"
        return 1
    fi
}
```

**Step 2: Verify syntax**

```bash
bash -n docker/entrypoint.sh && echo "Syntax OK"
```

**Step 3: Commit**

```bash
git add docker/entrypoint.sh
git commit -m "feat: add continue_with_merge and feedback functions

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 7: Create Interactive Agent Loop

**Files:**
- Modify: `docker/entrypoint.sh` (add new function, modify main)

**Step 1: Add interactive_agent_loop function**

Add before the existing `agent_loop` function:

```bash
# Interactive agent loop with approval gates
interactive_agent_loop() {
    local idle_count=0

    while true; do
        write_status "idle"
        log "Looking for work..."

        local task_id
        if task_id=$(claim_task); then
            idle_count=0
            clear_output_log

            local task_type
            task_type=$(get_task_type "$task_id")
            log "Task type: $task_type"

            local worktree_path
            if worktree_path=$(setup_worktree "$task_id"); then
                write_status "working" "$task_id"

                # Phase 1: Do the work (stop before merge)
                if do_work "$task_id" "$worktree_path"; then

                    # Check if approval is required
                    if requires_approval "$task_type"; then
                        # Request approval
                        write_status "needs_approval" "$task_id"
                        write_approval_request "$task_id" "$task_type" "$worktree_path"

                        # Wait for response
                        if wait_for_approval; then
                            # Approved - proceed with merge
                            clear_approval_request
                            write_status "working" "$task_id"

                            if continue_with_merge "$task_id" "$worktree_path"; then
                                cleanup "$task_id" "$worktree_path" "true"
                            else
                                cleanup "$task_id" "$worktree_path" "false"
                            fi
                        else
                            # Rejected - get feedback and retry
                            clear_approval_request
                            write_status "working" "$task_id"

                            if continue_with_feedback "$task_id" "$worktree_path"; then
                                # Loop back to approval
                                continue
                            else
                                cleanup "$task_id" "$worktree_path" "false"
                            fi
                        fi
                    else
                        # Auto-merge for chores/refactors/tasks
                        if continue_with_merge "$task_id" "$worktree_path"; then
                            cleanup "$task_id" "$worktree_path" "true"
                        else
                            cleanup "$task_id" "$worktree_path" "false"
                        fi
                    fi
                else
                    write_status "blocked" "$task_id"
                    cleanup "$task_id" "$worktree_path" "false"
                fi
            else
                error "Failed to set up worktree for $task_id"
                FAILURE_REASON="worktree_failed"
                FAILURE_DETAILS="Failed to set up git worktree for this task."
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

    write_status "idle"
}
```

**Step 2: Update interactive_mode to use the new loop**

Replace the existing `interactive_mode` function:

```bash
# Interactive mode - runs agent loop with approval gates
interactive_mode() {
    log "Starting interactive agent loop"
    interactive_agent_loop
}
```

**Step 3: Verify syntax**

```bash
bash -n docker/entrypoint.sh && echo "Syntax OK"
```

**Step 4: Commit**

```bash
git add docker/entrypoint.sh
git commit -m "feat: add interactive agent loop with approval gates

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 8: Update cleanup to Clear Status

**Files:**
- Modify: `docker/entrypoint.sh:221-260` (cleanup function)

**Step 1: Add status clearing to cleanup**

At the end of the `cleanup` function, before `bd sync`, add:

```bash
    # Clear approval request if any
    clear_approval_request
```

**Step 2: Verify syntax**

```bash
bash -n docker/entrypoint.sh && echo "Syntax OK"
```

**Step 3: Commit**

```bash
git add docker/entrypoint.sh
git commit -m "feat: clear approval request in cleanup

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 9: Integration Test

**Files:**
- None (manual testing)

**Step 1: Verify all syntax is correct**

```bash
cd /Users/danyel/code/MISC/sbmaker-2
bash -n docker/entrypoint.sh && echo "All syntax OK"
```

**Step 2: Verify shell variables are used correctly**

```bash
# Check for common issues
grep -n '${.*}' docker/entrypoint.sh | head -20
```

**Step 3: Review the complete file**

Read through the entire entrypoint.sh to verify the flow makes sense.

**Step 4: Final commit if needed**

```bash
git status
# If any uncommitted changes
git add docker/entrypoint.sh
git commit -m "fix: address integration issues

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Summary

After completing all tasks, the entrypoint.sh will:

1. Create status directory `/workspace/.csb/${AGENT_ID}/` on startup
2. Write status files as the agent works (idle, working, needs_approval, blocked)
3. For features/bugs: pause after work, write approval request, wait for response
4. For chores/refactors/tasks: auto-merge without waiting
5. Use `claude --continue` to resume sessions after approval

The status directory structure:
```
/workspace/.csb/
├── agent1/
│   ├── status          # idle|working|needs_approval|blocked
│   ├── task            # current task ID
│   ├── output.log      # recent output
│   └── approval/
│       ├── type        # feature|bug|chore|refactor
│       ├── title       # task title
│       ├── diff        # git diff --stat
│       ├── message     # commit message
│       ├── response    # approved|rejected (written by dashboard)
│       └── feedback    # rejection reason (optional)
├── agent2/
│   └── ...
```
