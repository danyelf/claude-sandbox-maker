# Multi-Agent Workflow Design v2

## Goals

1. **Multiple agents** (4-6) working autonomously on the same codebase
2. **Safety** - Agents run in `--dangerously-skip-permissions` mode; must not be able to harm host
3. **Coordination** - Agents claim tasks, avoid duplicate work, handle conflicts
4. **Minimal manual intervention** - Auto-merge when possible, only escalate hard problems

## Architecture

### Container Setup

```
┌─────────────────────────────────────────────────────────┐
│                     Docker Host                         │
│                                                         │
│  ┌─────────────────────────────────────────────────┐   │
│  │            Docker Volume: workspace              │   │
│  │                                                  │   │
│  │  /workspace/                                     │   │
│  │  ├── .git/                                       │   │
│  │  ├── .beads/        (shared, instant sync)       │   │
│  │  ├── .worktrees/                                 │   │
│  │  │   ├── agent1/    (agent1's branch)            │   │
│  │  │   ├── agent2/    (agent2's branch)            │   │
│  │  │   └── ...                                     │   │
│  │  └── src/           (main branch - don't edit)   │   │
│  └─────────────────────────────────────────────────┘   │
│           ▲           ▲           ▲                     │
│           │           │           │                     │
│  ┌────────┴──┐ ┌──────┴────┐ ┌────┴──────┐             │
│  │  Agent 1  │ │  Agent 2  │ │  Agent 3  │  ...        │
│  │ Container │ │ Container │ │ Container │             │
│  └───────────┘ └───────────┘ └───────────┘             │
└─────────────────────────────────────────────────────────┘
          │
          │ push/pull
          ▼
   ┌─────────────┐
   │   GitHub    │
   │   Remote    │
   └─────────────┘
          ▲
          │ push/pull
          │
   ┌──────┴──────┐
   │  Your Host  │
   │  (safe)     │
   └─────────────┘
```

### Key Design Decisions

**Docker volume, not host mount:**

- Agents share a Docker-managed volume with each other
- Host `.git` is never mounted into containers
- Avoids git ownership/path issues between host and container
- Code flows through git remote, not filesystem sharing

**Shared volume between agents:**

- All agents mount the same `/workspace` volume
- Instant visibility of Beads state (shared `.beads/`)
- Worktrees provide soft isolation between agents

## Task Coordination via Beads

### Claiming Work

```bash
# Agent checks for available work
bd ready

# Agent claims a task (atomic operation)
bd update beads-123 --status in_progress --assignee $AGENT_ID
bd sync
```

### Race Condition Handling

If two agents try to claim the same task simultaneously:

1. Both run `bd update --status in_progress`
2. First one to commit/sync wins
3. Second agent sees the task is already claimed
4. Second agent picks a different task from `bd ready`

### Agent Identity

Each container receives an `AGENT_ID` environment variable:

- Used for worktree directory: `/workspace/.worktrees/$AGENT_ID`
- Used for branch names: `$AGENT_ID/beads-123`
- Used for Beads assignee field

## Git Workflow

### The Complete Cycle

```bash
# ─────────────────────────────────────────────────────────
# 1. CLAIM TASK
# ─────────────────────────────────────────────────────────
bd ready                                    # Find available work
bd update beads-123 --status in_progress --assignee $AGENT_ID
bd sync

# ─────────────────────────────────────────────────────────
# 2. SET UP WORKTREE
# ─────────────────────────────────────────────────────────
cd /workspace
git fetch origin main
git worktree add .worktrees/$AGENT_ID -b $AGENT_ID/beads-123 origin/main
cd .worktrees/$AGENT_ID

# ─────────────────────────────────────────────────────────
# 3. DO THE WORK
# ─────────────────────────────────────────────────────────
# ... Claude does the implementation ...
git add -A && git commit -m "beads-123: Description of changes"

# ─────────────────────────────────────────────────────────
# 4. REBASE ONTO CURRENT MAIN (after work is complete!)
# ─────────────────────────────────────────────────────────
git fetch origin main
git rebase origin/main

# If conflict is resolvable: agent resolves it (has full context)
# If conflict is too hard: see "Conflict Escalation" below

# ─────────────────────────────────────────────────────────
# 5. RUN TESTS
# ─────────────────────────────────────────────────────────
npm test  # or project-specific test command
# If tests fail: fix and recommit, go back to step 4

# ─────────────────────────────────────────────────────────
# 6. MERGE TO MAIN
# ─────────────────────────────────────────────────────────
git checkout main
git merge --ff-only $AGENT_ID/beads-123

# ─────────────────────────────────────────────────────────
# 7. PUSH (with retry for race conditions, max 5 attempts)
# ─────────────────────────────────────────────────────────
attempt=0
max_attempts=5
while ! git push origin main; do
  attempt=$((attempt + 1))
  if [ $attempt -ge $max_attempts ]; then
    # Escalate to human
    bd comments add beads-123 "Failed to push after $max_attempts attempts"
    bd update beads-123 --status blocked
    exit 1
  fi

  sleep $((2 ** attempt))

  # Someone else merged first - rebase and retry
  git checkout $AGENT_ID/beads-123
  git fetch origin main
  git rebase origin/main

  npm test || break  # bail if rebase broke tests

  git checkout main
  git merge --ff-only $AGENT_ID/beads-123
done

# ─────────────────────────────────────────────────────────
# 8. CLEANUP
# ─────────────────────────────────────────────────────────
cd /workspace
git worktree remove .worktrees/$AGENT_ID
git branch -d $AGENT_ID/beads-123
bd close beads-123
bd sync
```

### Conflict Escalation

When an agent encounters a conflict it cannot resolve:

```bash
# Add detailed comment explaining the conflict
bd comments add beads-123 "Conflict in src/auth.ts: merge changes to login() with agent2's session handling. Need human decision on approach."

# Mark as blocked
bd update beads-123 --status blocked

# Agent stops working on this task and picks up another
# The agent should exit/fail loudly so you notice
```

You resolve by:

1. Check `bd list --status=blocked` or `bd blocked`
2. Read the comment for context
3. Manually resolve and complete the merge
4. `bd update beads-123 --status in_progress` and let an agent finish, or complete it yourself

## Container Specification

### Dockerfile

```dockerfile
FROM ubuntu:24.04

# System dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    nodejs \
    npm \
    python3 \
    python3-pip \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code (verify actual package name)
RUN npm install -g @anthropic-ai/claude-code  # TODO: verify package name

# Install Beads (see https://github.com/steveyegge/beads/)
RUN npm install -g beads-cli  # TODO: verify package name

# Git config for pushing
RUN git config --global user.name "Claude Agent" \
    && git config --global user.email "agent@example.com"

WORKDIR /workspace

# Entrypoint script handles the workflow
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
```

### docker-compose.yml

```yaml
version: "3.8"

volumes:
  workspace:

services:
  init:
    image: alpine/git
    volumes:
      - workspace:/workspace
    environment:
      - GITHUB_TOKEN
    command: >
      sh -c "
        if [ ! -d /workspace/.git ]; then
          git clone https://oauth2:$GITHUB_TOKEN@github.com/you/repo.git /workspace
        fi
      "

  agent1:
    build: .
    depends_on:
      init:
        condition: service_completed_successfully
    volumes:
      - workspace:/workspace
    environment:
      - AGENT_ID=agent1
      - CLAUDE_OAUTH_TOKEN
      - GITHUB_TOKEN

  agent2:
    build: .
    depends_on:
      init:
        condition: service_completed_successfully
    volumes:
      - workspace:/workspace
    environment:
      - AGENT_ID=agent2
      - CLAUDE_OAUTH_TOKEN
      - GITHUB_TOKEN

  agent3:
    build: .
    depends_on:
      init:
        condition: service_completed_successfully
    volumes:
      - workspace:/workspace
    environment:
      - AGENT_ID=agent3
      - CLAUDE_OAUTH_TOKEN
      - GITHUB_TOKEN

  agent4:
    build: .
    depends_on:
      init:
        condition: service_completed_successfully
    volumes:
      - workspace:/workspace
    environment:
      - AGENT_ID=agent4
      - CLAUDE_OAUTH_TOKEN
      - GITHUB_TOKEN
```

### entrypoint.sh (sketch)

```bash
#!/bin/bash
set -e

MAX_PUSH_ATTEMPTS=5

# Configure git credentials
git config --global credential.helper '!f() { echo "password=$GITHUB_TOKEN"; }; f'
git config --global url."https://oauth2:${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"

cd /workspace

# Cleanup function for failures
cleanup_worktree() {
  cd /workspace
  if [ -d ".worktrees/$AGENT_ID" ]; then
    git worktree remove --force .worktrees/$AGENT_ID 2>/dev/null || true
    git branch -D $AGENT_ID/$TASK 2>/dev/null || true
  fi
}

# Mark task as blocked with message
mark_blocked() {
  local msg="$1"
  bd comments add $TASK "$msg"
  bd update $TASK --status blocked
  bd sync
}

# Clean up any stale worktree from previous crash
cleanup_worktree

# Main loop: pick up work, do it, repeat
while true; do
  TASK=""
  trap cleanup_worktree EXIT

  # Sync beads state
  bd sync
  git pull origin main

  # Find available work
  TASK=$(bd ready --json | jq -r '.[0].id // empty')

  if [ -z "$TASK" ]; then
    echo "No work available, waiting..."
    sleep 30
    continue
  fi

  # Claim the task
  bd update $TASK --status in_progress --assignee $AGENT_ID
  bd sync

  # Set up worktree
  git fetch origin main
  git worktree add .worktrees/$AGENT_ID -b $AGENT_ID/$TASK origin/main
  cd .worktrees/$AGENT_ID

  # Get full task context (description, comments, dependencies)
  TASK_CONTEXT=$(bd show $TASK)

  # Run Claude on the task
  if ! claude --dangerously-skip-permissions --print "Complete this task:

$TASK_CONTEXT"; then
    mark_blocked "Claude failed or exited with error"
    cleanup_worktree
    continue
  fi

  # Attempt merge workflow with retry limit
  attempt=0
  success=false
  failure_reason=""

  while [ $attempt -lt $MAX_PUSH_ATTEMPTS ]; do
    git fetch origin main

    if ! git rebase origin/main; then
      git rebase --abort 2>/dev/null || true
      failure_reason="Rebase conflict after $attempt attempts - need human"
      break
    fi

    # Run tests (TODO: make configurable via env var or script in repo)
    if ! npm test 2>/dev/null; then
      failure_reason="Tests failed after rebase"
      break
    fi

    git checkout main
    git merge --ff-only $AGENT_ID/$TASK

    if git push origin main; then
      success=true
      break
    fi

    # Push failed, retry
    git checkout $AGENT_ID/$TASK
    attempt=$((attempt + 1))
    sleep $((2 ** attempt))
  done

  # Handle max attempts exhausted (loop exited without break)
  if [ "$success" = false ] && [ -z "$failure_reason" ]; then
    failure_reason="Failed to push after $MAX_PUSH_ATTEMPTS attempts"
  fi

  # Single cleanup path
  cleanup_worktree

  if [ "$success" = true ]; then
    bd close $TASK
    bd sync
  else
    mark_blocked "$failure_reason"
  fi
done
```

### AGENTS.md (for the workspace)

The cloned repo needs an `AGENTS.md` that teaches Claude the workflow. This is how agents learn the lifecycle.

See draft: [`docs/draft-agents.md`](../draft-agents.md)

This file should be committed to the target repo before agents start.

## Solved Problems

These are fundamental requirements, not open questions:

### 1. Merge Conflicts

**Solution:** Agent resolves during rebase.

- Agent has freshest context - they just wrote the code
- Rebase happens immediately after work, while context is hot
- If too complex: mark as `blocked`, add explanatory comment, fail loudly
- Human resolves edge cases

### 2. Task Assignment Races

**Solution:** Beads provides atomic claiming.

- `bd update --status in_progress` is the claim mechanism
- First agent to sync wins
- Losing agent sees status changed, picks different task
- Shared Docker volume means instant visibility

### 3. Work Visibility

**Solution:** Shared `.beads/` directory + Beads commands.

- All agents see same state via `bd list`, `bd ready`, `bd blocked`
- No push/pull delay for Beads coordination (shared volume)
- Git changes still go through remote (push/pull)

### 4. Push Race Conditions

**Solution:** Retry loop with exponential backoff.

- If push fails, another agent merged first
- Re-rebase onto new main
- Re-run tests (rebase might have broken something)
- Retry push
- Exponential backoff prevents thundering herd

## Interactive Development Mode

For prototyping work where you want to talk with agents and see demos running:

### Port Allocation

Each agent gets dedicated ports for dev servers:

| Agent  | Vite/Frontend | Express/Backend | Other |
|--------|---------------|-----------------|-------|
| agent1 | 5181          | 3001            | 8081  |
| agent2 | 5182          | 3002            | 8082  |
| agent3 | 5183          | 3003            | 8083  |
| agent4 | 5184          | 3004            | 8084  |

docker-compose.yml:
```yaml
agent1:
  ports:
    - "5181:5173"
    - "3001:3000"
    - "8081:8080"
```

### Interactive Wrapper Script

Instead of the autonomous entrypoint, use an interactive script:

```bash
#!/bin/bash
# agent-interactive.sh

while true; do
  echo "=== Available tasks ==="
  bd ready

  echo ""
  read -p "Enter task ID (or 'q' to quit): " TASK
  [ "$TASK" = "q" ] && break

  # Claim and set up
  bd update $TASK --status in_progress --assignee $AGENT_ID
  bd sync
  git fetch origin main
  git worktree add .worktrees/$AGENT_ID -b $AGENT_ID/$TASK origin/main
  cd .worktrees/$AGENT_ID

  # Run Claude interactively
  TASK_CONTEXT=$(bd show $TASK)
  claude --dangerously-skip-permissions -p "Work on this task:

$TASK_CONTEXT"

  # Post-work options
  echo ""
  echo "What now?"
  echo "  1) Merge and close"
  echo "  2) Mark blocked"
  echo "  3) Abandon (reopen task)"
  echo "  4) Run dev server"
  echo "  5) Open shell"
  echo "  6) Back to Claude (continue working)"
  read -p "Choice: " choice

  case $choice in
    1) git fetch origin main && git rebase origin/main && \
       npm test && git checkout main && \
       git merge --ff-only $AGENT_ID/$TASK && git push && \
       bd close $TASK ;;
    2) bd update $TASK --status blocked ;;
    3) bd update $TASK --status open ;;
    4) npm run dev ;;
    5) bash ;;
    6) continue ;;  # back to top, same task
  esac

  # Cleanup (unless continuing)
  [ "$choice" != "6" ] && {
    cd /workspace
    git worktree remove .worktrees/$AGENT_ID 2>/dev/null
    bd sync
  }
done
```

### Tmux Multi-Pane Setup

For richer interaction, run tmux inside the container:

```bash
#!/bin/bash
# agent-tmux.sh - start agent with multiple panes

tmux new-session -d -s $AGENT_ID -n main

# Pane 0: Claude / main work
tmux send-keys -t $AGENT_ID:main.0 "cd /workspace && ./agent-interactive.sh" Enter

# Pane 1: Dev server (split right)
tmux split-window -h -t $AGENT_ID:main
tmux send-keys -t $AGENT_ID:main.1 "# Dev server pane - run 'npm run dev' here" Enter

# Pane 2: Shell (split bottom of pane 0)
tmux select-pane -t $AGENT_ID:main.0
tmux split-window -v -t $AGENT_ID:main
tmux send-keys -t $AGENT_ID:main.2 "# Shell pane - explore, run tests, etc." Enter

tmux attach -t $AGENT_ID
```

Layout:
```
┌─────────────────────┬─────────────────────┐
│                     │                     │
│   Claude / Tasks    │    Dev Server       │
│                     │    (npm run dev)    │
│                     │                     │
├─────────────────────┤                     │
│                     │                     │
│   Shell             │                     │
│                     │                     │
└─────────────────────┴─────────────────────┘
```

### Attaching to Agents

```bash
# Start container in background
docker-compose up -d agent1

# Attach to tmux session inside container
docker exec -it agent1 tmux attach -t agent1

# Detach: Ctrl-b, d
# Switch panes: Ctrl-b, arrow keys
```

## Operational Commands

```bash
# Start all agents
docker-compose up -d

# View agent logs
docker-compose logs -f agent1

# Check blocked work
docker-compose exec agent1 bd blocked

# Check overall progress
docker-compose exec agent1 bd stats

# Stop all agents
docker-compose down

# Reset (destroy volume and start fresh)
docker-compose down -v
```

## What You Do

1. **Before starting:** Push any work you want agents to pick up
2. **Start agents:** `docker-compose up -d`
3. **Monitor:** Check `bd blocked` periodically for stuck work
4. **Resolve conflicts:** When agents mark work as blocked
5. **Get results:** `git pull` on your host to see completed work
6. **Stop:** `docker-compose down`

## Test Plan

### Phase 1: Container Basics
- [ ] Dockerfile builds successfully
- [ ] Container can run `git`, `claude`, `bd`, `jq` commands
- [ ] Volume init service clones repo correctly
- [ ] Multiple containers can mount shared volume

### Phase 2: Single Agent Workflow (manual)
- [ ] Agent can run `bd ready` and see tasks
- [ ] Agent can claim a task with `bd update --status in_progress`
- [ ] Agent can create worktree and work in it
- [ ] Agent can rebase onto main
- [ ] Agent can merge --ff-only and push
- [ ] Agent cleans up worktree after success

### Phase 3: Failure Handling (manual)
- [ ] Rebase conflict → agent marks task blocked with comment
- [ ] Test failure → agent marks task blocked
- [ ] Claude failure → agent marks task blocked
- [ ] Push failure → agent retries with backoff
- [ ] Max push attempts exceeded → agent marks blocked
- [ ] Stale worktree on startup → cleaned up automatically

### Phase 4: Multi-Agent (integration)
- [ ] Two agents claim different tasks (no collision)
- [ ] Two agents race to claim same task → one wins, other picks different
- [ ] Two agents push simultaneously → one retries and succeeds
- [ ] Beads state visible to all agents instantly (shared volume)

### Phase 5: End-to-End
- [ ] Create 3-4 tasks in beads
- [ ] Start 2 agents
- [ ] Agents complete all tasks without human intervention
- [ ] All work merged to main and pushed

### Testing Notes
- Start with mocked/simple tasks (e.g., "add a comment to file X")
- Use `--dry-run` or echo commands before real git operations during development
- Log verbosely during testing: `set -x` in entrypoint

## Comparison: v1 vs v2

| Aspect        | v1 (original)                | v2 (this design)                   |
| ------------- | ---------------------------- | ---------------------------------- |
| Isolation     | Single VM, manual worktrees  | Docker containers, shared volume   |
| Git issues    | Host .git mounted → problems | Docker volume → clean              |
| Task claiming | Ad-hoc                       | Beads atomic claiming              |
| Merging       | You manually merge           | Agents self-merge after rebase     |
| Conflicts     | You resolve all              | Agent resolves (or escalates)      |
| Rebase timing | Confusing (at start?)        | Clear: after work, before merge    |
| Setup         | Manual                       | `docker-compose up`                |
| Coordination  | ?                            | Shared .beads/, instant visibility |
