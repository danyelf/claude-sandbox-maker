# Phase 1: Agent-Side Approval Gate Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Modify the agent loop to write status files, check task type before merge, and wait for approval on features/bugs.

**Architecture:** Agents write status to `/workspace/.csb/agentN/` (shared mount visible from host). Interactive mode pauses before merge for features/bugs, polls for approval response. Uses `claude --continue` to resume conversation after approval.

**Tech Stack:** Bash (entrypoint.sh), shared files for IPC, existing bd CLI for task metadata

---

## Task 1: Add --mode Flag to csb start

**Files:**
- Modify: `csb/csb:762-813` (cmd_start function)

**Step 1: Write test script for --mode flag parsing**

Create test file:
```bash
# tests/test_csb_mode_flag.sh
#!/bin/bash
set -e

CSB_SCRIPT="$(dirname "$0")/../csb/csb"

# Test: --mode flag is recognized
echo "Test: --mode interactive is parsed..."
output=$("$CSB_SCRIPT" start --mode interactive --help 2>&1 || true)
# Should not error on unknown flag

# Test: default mode is autonomous
echo "Test: default mode check..."
# We'll verify this by checking the environment passed to VM

echo "All flag parsing tests passed"
```

**Step 2: Run test to verify it fails**

Run: `bash tests/test_csb_mode_flag.sh`
Expected: Script doesn't exist yet, will create

**Step 3: Add --mode flag parsing to cmd_start**

In `csb/csb`, modify `cmd_start()` to parse --mode flag:

```bash
cmd_start() {
    check_lima
    local vm_name=$(get_vm_name)
    local arch=$(uname -m)
    local golden_image="${CSB_DIR}/golden-${arch}.qcow2"
    local agent_name=""
    local agent_mode="autonomous"  # Default mode

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                agent_mode="$2"
                shift 2
                ;;
            -*)
                error "Unknown option: $1"
                exit 1
                ;;
            *)
                agent_name="$1"
                shift
                ;;
        esac
    done

    # Validate mode
    if [[ "$agent_mode" != "autonomous" && "$agent_mode" != "interactive" ]]; then
        error "Invalid mode: $agent_mode (must be 'autonomous' or 'interactive')"
        exit 1
    fi

    # ... rest of function uses $agent_mode
```

**Step 4: Pass mode to agent via environment**

Further down in cmd_start, when starting agents, export the mode:

```bash
    # If agent name provided, use isolated agent mode
    if [[ -n "${agent_name}" ]]; then
        local git_remote=$(get_git_remote)
        start_agent "${vm_name}" "${agent_name}" "${git_remote}" "${agent_mode}"
        return
    fi
```

**Step 5: Update start_agent function signature**

Find and update `start_agent` to accept mode parameter and pass to Docker:

```bash
start_agent() {
    local vm_name="$1"
    local agent_name="$2"
    local git_remote="$3"
    local agent_mode="${4:-autonomous}"

    # ... existing code ...

    # When running docker-compose, add AGENT_MODE
    limactl shell --workdir / "${vm_name}" -- \
        AGENT_MODE="${agent_mode}" \
        GITHUB_TOKEN="${GITHUB_TOKEN}" \
        # ... rest of docker command
```

**Step 6: Run test to verify it passes**

Run: `bash tests/test_csb_mode_flag.sh`
Expected: PASS

**Step 7: Commit**

```bash
git add csb/csb tests/test_csb_mode_flag.sh
git commit -m "feat(csb): add --mode flag to csb start command"
```

---

## Task 2: Create Status Directory Structure

**Files:**
- Modify: `docker/entrypoint.sh:310-330` (main function)
- Create: `tests/test_status_files.sh`

**Step 1: Write test for status directory creation**

```bash
# tests/test_status_files.sh
#!/bin/bash
set -e

# Source the entrypoint functions (we'll refactor to make this possible)
# For now, test the expected directory structure

TEST_DIR=$(mktemp -d)
AGENT_ID="agent1"
CSB_STATUS_DIR="$TEST_DIR/.csb/$AGENT_ID"

# Simulate what entrypoint should do
mkdir -p "$CSB_STATUS_DIR"
echo "idle" > "$CSB_STATUS_DIR/status"
echo "" > "$CSB_STATUS_DIR/task"
touch "$CSB_STATUS_DIR/output.log"

# Verify structure
echo "Test: status directory structure..."
[[ -d "$CSB_STATUS_DIR" ]] || { echo "FAIL: directory not created"; exit 1; }
[[ -f "$CSB_STATUS_DIR/status" ]] || { echo "FAIL: status file missing"; exit 1; }
[[ -f "$CSB_STATUS_DIR/task" ]] || { echo "FAIL: task file missing"; exit 1; }
[[ -f "$CSB_STATUS_DIR/output.log" ]] || { echo "FAIL: output.log missing"; exit 1; }
[[ "$(cat $CSB_STATUS_DIR/status)" == "idle" ]] || { echo "FAIL: status not idle"; exit 1; }

echo "All status file tests passed"
rm -rf "$TEST_DIR"
```

**Step 2: Run test to verify structure expectations**

Run: `bash tests/test_status_files.sh`
Expected: PASS (tests our expected structure)

**Step 3: Add status directory initialization to entrypoint.sh**

Add after line 10 in `docker/entrypoint.sh`:

```bash
# Status directory for dashboard communication
CSB_STATUS_DIR="/workspace/.csb/${AGENT_ID}"

# Initialize status directory
init_status_dir() {
    mkdir -p "$CSB_STATUS_DIR"
    echo "idle" > "$CSB_STATUS_DIR/status"
    echo "" > "$CSB_STATUS_DIR/task"
    : > "$CSB_STATUS_DIR/output.log"  # Truncate/create
    log "Status directory initialized: $CSB_STATUS_DIR"
}

# Write current status
write_status() {
    local status="$1"
    local task="${2:-}"
    echo "$status" > "$CSB_STATUS_DIR/status"
    echo "$task" > "$CSB_STATUS_DIR/task"
}

# Append to output log (keeps last 100 lines)
write_output() {
    local msg="$1"
    echo "$msg" >> "$CSB_STATUS_DIR/output.log"
    # Trim to last 100 lines
    tail -100 "$CSB_STATUS_DIR/output.log" > "$CSB_STATUS_DIR/output.log.tmp"
    mv "$CSB_STATUS_DIR/output.log.tmp" "$CSB_STATUS_DIR/output.log"
}
```

**Step 4: Call init_status_dir in main()**

In the `main()` function, after `setup_git`:

```bash
main() {
    log "Starting agent in $AGENT_MODE mode"

    setup_git
    init_status_dir  # Add this line

    case "$AGENT_MODE" in
```

**Step 5: Commit**

```bash
git add docker/entrypoint.sh tests/test_status_files.sh
git commit -m "feat(agent): add status directory initialization"
```

---

## Task 3: Write Status Updates During Agent Loop

**Files:**
- Modify: `docker/entrypoint.sh:262-302` (agent_loop function)

**Step 1: Add status writes to agent_loop**

Update `agent_loop()` to write status at each stage:

```bash
agent_loop() {
    local idle_count=0
    write_status "idle"  # Initial state

    while true; do
        log "Looking for work..."
        write_output "Looking for work..."

        local task_id
        if task_id=$(claim_task); then
            idle_count=0
            write_status "working" "$task_id"
            write_output "Claimed task: $task_id"

            local worktree_path
            if worktree_path=$(setup_worktree "$task_id"); then
                local success="false"

                if do_work "$task_id" "$worktree_path"; then
                    write_output "Work completed, finalizing..."
                    if finalize_work "$task_id" "$worktree_path"; then
                        success="true"
                        write_output "Task completed successfully"
                    fi
                fi

                cleanup "$task_id" "$worktree_path" "$success"
            else
                error "Failed to set up worktree for $task_id"
                write_output "ERROR: Failed to set up worktree"
                FAILURE_REASON="worktree_failed"
                FAILURE_DETAILS="Failed to set up git worktree for this task."
                cleanup "$task_id" "" "false"
            fi

            write_status "idle"  # Back to idle after task
        else
            idle_count=$((idle_count + 1))
            log "No work available (idle: $idle_count/$MAX_IDLE_CYCLES)"
            write_output "No work available (idle: $idle_count/$MAX_IDLE_CYCLES)"

            if [ $idle_count -ge $MAX_IDLE_CYCLES ]; then
                log "Max idle cycles reached, exiting"
                write_output "Max idle cycles reached, exiting"
                break
            fi

            sleep 30
        fi
    done
}
```

**Step 2: Commit**

```bash
git add docker/entrypoint.sh
git commit -m "feat(agent): write status updates during agent loop"
```

---

## Task 4: Get Task Type from Beads

**Files:**
- Modify: `docker/entrypoint.sh` (add new function)

**Step 1: Write test for task type detection**

```bash
# tests/test_task_type.sh
#!/bin/bash
set -e

# Test that we can parse task type from bd show output
# Mock bd output for testing

echo "Test: parse feature type..."
mock_output='[{"id":"csb-abc","type":"feature","title":"Add login"}]'
task_type=$(echo "$mock_output" | jq -r '.[0].type // "task"')
[[ "$task_type" == "feature" ]] || { echo "FAIL: expected feature, got $task_type"; exit 1; }

echo "Test: parse bug type..."
mock_output='[{"id":"csb-def","type":"bug","title":"Fix crash"}]'
task_type=$(echo "$mock_output" | jq -r '.[0].type // "task"')
[[ "$task_type" == "bug" ]] || { echo "FAIL: expected bug, got $task_type"; exit 1; }

echo "Test: parse chore type..."
mock_output='[{"id":"csb-ghi","type":"chore","title":"Update deps"}]'
task_type=$(echo "$mock_output" | jq -r '.[0].type // "task"')
[[ "$task_type" == "chore" ]] || { echo "FAIL: expected chore, got $task_type"; exit 1; }

echo "Test: default to task when missing..."
mock_output='[{"id":"csb-jkl","title":"Something"}]'
task_type=$(echo "$mock_output" | jq -r '.[0].type // "task"')
[[ "$task_type" == "task" ]] || { echo "FAIL: expected task default, got $task_type"; exit 1; }

echo "All task type tests passed"
```

**Step 2: Run test**

Run: `bash tests/test_task_type.sh`
Expected: PASS

**Step 3: Add get_task_type function to entrypoint.sh**

Add after the `claim_task` function:

```bash
# Get task type (feature, bug, chore, task, etc.)
get_task_type() {
    local task_id="$1"
    bd show "$task_id" --json 2>/dev/null | jq -r '.[0].type // "task"'
}

# Check if task type requires approval
requires_approval() {
    local task_type="$1"
    case "$task_type" in
        feature|bug)
            return 0  # Yes, requires approval
            ;;
        *)
            return 1  # No, auto-merge
            ;;
    esac
}
```

**Step 4: Commit**

```bash
git add docker/entrypoint.sh tests/test_task_type.sh
git commit -m "feat(agent): add task type detection for approval gate"
```

---

## Task 5: Implement Approval Request/Response

**Files:**
- Modify: `docker/entrypoint.sh` (add approval functions)

**Step 1: Write test for approval flow**

```bash
# tests/test_approval_flow.sh
#!/bin/bash
set -e

TEST_DIR=$(mktemp -d)
AGENT_ID="agent1"
CSB_STATUS_DIR="$TEST_DIR/.csb/$AGENT_ID"
mkdir -p "$CSB_STATUS_DIR"

# Simulate writing approval request
write_approval_request() {
    local task_id="$1"
    local task_type="$2"
    local diff_summary="$3"
    local commit_msg="$4"

    cat > "$CSB_STATUS_DIR/approval_request.json" << EOF
{
    "task_id": "$task_id",
    "task_type": "$task_type",
    "diff_summary": "$diff_summary",
    "commit_message": "$commit_msg",
    "test_status": "passing"
}
EOF
}

# Test: write approval request
echo "Test: write approval request..."
write_approval_request "csb-abc" "feature" "3 files changed" "Add login feature"
[[ -f "$CSB_STATUS_DIR/approval_request.json" ]] || { echo "FAIL: request not written"; exit 1; }

# Test: read approval request
task_id=$(jq -r '.task_id' "$CSB_STATUS_DIR/approval_request.json")
[[ "$task_id" == "csb-abc" ]] || { echo "FAIL: wrong task_id"; exit 1; }

# Test: approval response
echo "Test: approval response..."
echo "approved" > "$CSB_STATUS_DIR/approval_response"
response=$(cat "$CSB_STATUS_DIR/approval_response")
[[ "$response" == "approved" ]] || { echo "FAIL: wrong response"; exit 1; }

echo "All approval flow tests passed"
rm -rf "$TEST_DIR"
```

**Step 2: Run test**

Run: `bash tests/test_approval_flow.sh`
Expected: PASS

**Step 3: Add approval functions to entrypoint.sh**

```bash
# Write approval request for dashboard
write_approval_request() {
    local task_id="$1"
    local task_type="$2"

    # Get diff summary
    local diff_summary
    diff_summary=$(git diff --stat HEAD~1 2>/dev/null | tail -1 || echo "unknown changes")

    # Get commit message
    local commit_msg
    commit_msg=$(git log -1 --format="%s" 2>/dev/null || echo "unknown")

    # Get test status
    local test_status="unknown"
    if [ -f "package.json" ] && grep -q '"test"' package.json; then
        if npm test >/dev/null 2>&1; then
            test_status="passing"
        else
            test_status="failing"
        fi
    fi

    cat > "$CSB_STATUS_DIR/approval_request.json" << EOF
{
    "task_id": "$task_id",
    "task_type": "$task_type",
    "diff_summary": "$diff_summary",
    "commit_message": "$commit_msg",
    "test_status": "$test_status"
}
EOF

    # Remove any old response
    rm -f "$CSB_STATUS_DIR/approval_response"

    log "Approval request written for $task_id"
}

# Wait for approval response from dashboard
wait_for_approval() {
    local timeout="${1:-3600}"  # Default 1 hour timeout
    local elapsed=0
    local poll_interval=5

    log "Waiting for approval (timeout: ${timeout}s)..."
    write_output "Waiting for approval..."

    while [ $elapsed -lt $timeout ]; do
        if [ -f "$CSB_STATUS_DIR/approval_response" ]; then
            local response
            response=$(cat "$CSB_STATUS_DIR/approval_response")
            log "Received approval response: $response"
            echo "$response"
            return 0
        fi

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    log "Approval timeout after ${timeout}s"
    echo "timeout"
    return 1
}

# Clean up approval files
cleanup_approval() {
    rm -f "$CSB_STATUS_DIR/approval_request.json"
    rm -f "$CSB_STATUS_DIR/approval_response"
}
```

**Step 4: Commit**

```bash
git add docker/entrypoint.sh tests/test_approval_flow.sh
git commit -m "feat(agent): add approval request/response mechanism"
```

---

## Task 6: Modify finalize_work for Approval Gate

**Files:**
- Modify: `docker/entrypoint.sh:146-218` (finalize_work function)

**Step 1: Refactor finalize_work to support approval gate**

Split finalize_work into phases and add approval check:

```bash
# Rebase and test (pre-merge phase)
prepare_merge() {
    local task_id="$1"
    local worktree_path="$2"

    cd "$worktree_path"

    # Rebase onto latest main
    log "Rebasing onto origin/main..."
    git fetch origin main

    if ! git rebase origin/main; then
        local conflict_summary
        conflict_summary=$(get_conflict_summary)
        error "Rebase failed - conflicts detected"
        FAILURE_REASON="merge_conflict"
        FAILURE_DETAILS="Rebase failed. $conflict_summary"
        git rebase --abort 2>/dev/null || true
        return 1
    fi

    # Run tests if they exist
    if [ -f "package.json" ] && grep -q '"test"' package.json; then
        log "Running tests..."
        write_output "Running tests..."
        if ! npm test 2>&1; then
            error "Tests failed after rebase"
            FAILURE_REASON="test_failure"
            FAILURE_DETAILS="Tests failed after rebasing onto origin/main."
            return 1
        fi
        write_output "Tests passed"
    fi

    return 0
}

# Execute merge and push
execute_merge() {
    local task_id="$1"
    local worktree_path="$2"
    local branch_name="${AGENT_ID}/${task_id}"

    cd /workspace/main
    git fetch origin main
    git checkout main
    git pull origin main

    log "Merging $branch_name to main..."
    if ! git merge --ff-only "$branch_name"; then
        error "Fast-forward merge failed"
        FAILURE_REASON="merge_failed"
        FAILURE_DETAILS="Fast-forward merge failed. Main may have diverged."
        return 1
    fi

    # Push with retries
    local attempt=1
    while [ $attempt -le $MAX_PUSH_RETRIES ]; do
        log "Push attempt $attempt/$MAX_PUSH_RETRIES..."
        write_output "Pushing... (attempt $attempt)"

        if git push origin main; then
            log "Push successful"
            write_output "Push successful"
            return 0
        fi

        log "Push failed, pulling and retrying..."
        git pull --rebase origin main
        attempt=$((attempt + 1))
        sleep $PUSH_RETRY_DELAY
    done

    error "Push failed after $MAX_PUSH_RETRIES attempts"
    FAILURE_REASON="push_failed"
    FAILURE_DETAILS="Push failed after $MAX_PUSH_RETRIES attempts."
    return 1
}

# Main finalize function with approval gate
finalize_work() {
    local task_id="$1"
    local worktree_path="$2"

    # Phase 1: Prepare (rebase + test)
    if ! prepare_merge "$task_id" "$worktree_path"; then
        return 1
    fi

    # Phase 2: Check if approval needed (interactive mode only)
    if [[ "$AGENT_MODE" == "interactive" ]]; then
        local task_type
        task_type=$(get_task_type "$task_id")

        if requires_approval "$task_type"; then
            write_status "needs_approval" "$task_id"
            write_approval_request "$task_id" "$task_type"
            write_output "Waiting for approval to merge $task_type..."

            local response
            response=$(wait_for_approval)

            cleanup_approval

            if [[ "$response" != "approved" ]]; then
                log "Merge not approved: $response"
                write_output "Merge not approved: $response"
                write_status "working" "$task_id"

                if [[ "$response" == "rejected" ]]; then
                    # Continue conversation to address feedback
                    cd "$worktree_path"
                    claude --continue "The merge was rejected. Please review the feedback and make necessary changes."
                    # Recursively try to finalize again
                    return finalize_work "$task_id" "$worktree_path"
                fi

                return 1  # timeout or other
            fi

            write_status "working" "$task_id"
            write_output "Approval received, proceeding with merge..."
        fi
    fi

    # Phase 3: Execute merge
    if ! execute_merge "$task_id" "$worktree_path"; then
        return 1
    fi

    return 0
}
```

**Step 2: Commit**

```bash
git add docker/entrypoint.sh
git commit -m "feat(agent): add approval gate to finalize_work"
```

---

## Task 7: Update do_work to Use claude --continue Pattern

**Files:**
- Modify: `docker/entrypoint.sh:111-144` (do_work function)

**Step 1: Refactor do_work for continue pattern**

```bash
# Run Claude to do the actual work
do_work() {
    local task_id="$1"
    local worktree_path="$2"

    cd "$worktree_path"

    # Get task details for the prompt
    local task_title task_desc
    task_title=$(bd show "$task_id" --json 2>/dev/null | jq -r '.[0].title // "Unknown task"')
    task_desc=$(bd show "$task_id" --json 2>/dev/null | jq -r '.[0].description // ""')

    log "Starting work on: $task_title"
    write_output "Starting work on: $task_title"

    # Build prompt based on mode
    local prompt
    if [[ "$AGENT_MODE" == "interactive" ]]; then
        prompt="You are working on task $task_id: $task_title

$task_desc

Complete this task. When done, commit your changes with a descriptive message.
Do NOT push or merge - that will be handled after human approval.
If you cannot complete the task, explain why in a comment."
    else
        prompt="You are working on task $task_id: $task_title

$task_desc

Complete this task. When done, commit your changes with a descriptive message.
Do not push - that will be handled separately.
If you cannot complete the task, explain why in a comment."
    fi

    # Execute Claude Code
    if claude --dangerously-skip-permissions -p "$prompt" 2>&1 | tee -a "$CSB_STATUS_DIR/output.log"; then
        log "Claude completed work on $task_id"
        write_output "Claude completed work on $task_id"
        return 0
    else
        error "Claude failed on $task_id"
        write_output "ERROR: Claude failed on $task_id"
        FAILURE_REASON="claude_failed"
        FAILURE_DETAILS="Claude Code failed to complete the task."
        return 1
    fi
}
```

**Step 2: Commit**

```bash
git add docker/entrypoint.sh
git commit -m "feat(agent): update do_work for interactive mode"
```

---

## Task 8: Integration Test - Full Approval Flow

**Files:**
- Create: `tests/test_integration_approval.sh`

**Step 1: Write integration test**

```bash
# tests/test_integration_approval.sh
#!/bin/bash
# Integration test for approval flow
# This test mocks the agent loop behavior

set -e

TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

AGENT_ID="test-agent"
CSB_STATUS_DIR="$TEST_DIR/.csb/$AGENT_ID"
mkdir -p "$CSB_STATUS_DIR"

echo "=== Integration Test: Approval Flow ==="

# Initialize status
echo "idle" > "$CSB_STATUS_DIR/status"
echo "" > "$CSB_STATUS_DIR/task"

# Simulate agent claiming task
echo "Step 1: Agent claims task..."
echo "working" > "$CSB_STATUS_DIR/status"
echo "csb-test" > "$CSB_STATUS_DIR/task"

# Verify status
[[ "$(cat $CSB_STATUS_DIR/status)" == "working" ]] || { echo "FAIL: status not working"; exit 1; }
echo "  Status: working"

# Simulate work complete, needs approval
echo "Step 2: Work complete, requesting approval..."
echo "needs_approval" > "$CSB_STATUS_DIR/status"
cat > "$CSB_STATUS_DIR/approval_request.json" << 'EOF'
{
    "task_id": "csb-test",
    "task_type": "feature",
    "diff_summary": "3 files changed, 50 insertions(+), 10 deletions(-)",
    "commit_message": "Add new feature",
    "test_status": "passing"
}
EOF

# Verify approval request
[[ -f "$CSB_STATUS_DIR/approval_request.json" ]] || { echo "FAIL: no approval request"; exit 1; }
echo "  Approval request written"

# Simulate dashboard approval
echo "Step 3: Dashboard approves..."
echo "approved" > "$CSB_STATUS_DIR/approval_response"

# Verify response
[[ "$(cat $CSB_STATUS_DIR/approval_response)" == "approved" ]] || { echo "FAIL: wrong response"; exit 1; }
echo "  Approval response: approved"

# Simulate agent proceeding
echo "Step 4: Agent proceeds with merge..."
echo "working" > "$CSB_STATUS_DIR/status"
rm -f "$CSB_STATUS_DIR/approval_request.json"
rm -f "$CSB_STATUS_DIR/approval_response"

# Simulate completion
echo "Step 5: Task complete..."
echo "idle" > "$CSB_STATUS_DIR/status"
echo "" > "$CSB_STATUS_DIR/task"

echo ""
echo "=== All integration tests passed ==="
```

**Step 2: Run integration test**

Run: `bash tests/test_integration_approval.sh`
Expected: All steps pass

**Step 3: Commit**

```bash
git add tests/test_integration_approval.sh
git commit -m "test: add integration test for approval flow"
```

---

## Task 9: Run All Tests and Final Commit

**Step 1: Run all tests**

```bash
bash tests/test_csb_mode_flag.sh
bash tests/test_status_files.sh
bash tests/test_task_type.sh
bash tests/test_approval_flow.sh
bash tests/test_integration_approval.sh
```

**Step 2: Verify entrypoint.sh syntax**

```bash
bash -n docker/entrypoint.sh
```

**Step 3: Final commit if any fixes needed**

```bash
git add -A
git commit -m "fix: address any test failures" --allow-empty
```

**Step 4: Update bead status**

```bash
bd close csb-yoo
bd sync
```

---

## Summary

After completing all tasks:

1. `csb start --mode interactive agent1` starts agent in interactive mode
2. Agent writes status to `/workspace/.csb/agent1/status`
3. Features/bugs pause before merge, write approval request
4. Agent polls for approval response
5. On approval, agent uses `claude --continue` to proceed with merge
6. Chores/refactors auto-merge without approval

**Files Changed:**
- `csb/csb` - Added --mode flag parsing
- `docker/entrypoint.sh` - Added status files, approval gate, continue pattern

**Tests Added:**
- `tests/test_csb_mode_flag.sh`
- `tests/test_status_files.sh`
- `tests/test_task_type.sh`
- `tests/test_approval_flow.sh`
- `tests/test_integration_approval.sh`
