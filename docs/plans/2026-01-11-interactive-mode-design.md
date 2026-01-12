# Interactive Mode Design

**Issue:** csb-kva - Add interactive mode support
**Date:** 2026-01-11
**Status:** Ready for implementation

## Overview

Add a `--mode interactive` flag to csb that launches a terminal dashboard for supervising multiple agents. Instead of agents running fully autonomously, you get a control room view where you can monitor progress, approve merges, and hop into any agent's conversation.

## Key Behaviors

**Agents work autonomously** - They claim tasks from `bd ready` and execute without waiting for permission to start.

**Approval gates on features/bugs** - Before merging, agents pause and request approval. Chores and refactors auto-merge.

**Dashboard as home base** - Shows all agent status, recent output, and task board at a glance.

**Focus to chat** - Select an agent to drop into a direct conversation with it.

**Port mapping** - Each agent gets a predictable port (5181, 5182, etc.) so you can view dev servers in your browser.

## Mode Comparison

| Aspect | Autonomous | Interactive |
|--------|-----------|-------------|
| Task claiming | Auto | Auto |
| Work execution | Auto | Auto |
| Merge (feature/bug) | Auto | Needs approval |
| Merge (chore/refactor) | Auto | Auto |
| Visibility | Logs only | Live dashboard |
| Intervention | None | Anytime |

## Dashboard Layout

```
┌─ agent1 [working] ─────────┬─ agent2 [needs approval] ──┬─ agent3 [idle] ────────────┐
│ Task: csb-abc              │ Task: csb-def              │ Waiting for task...        │
│ 12m elapsed                │ Ready to merge             │                            │
│ > Running tests...         │ > All tests pass           │                            │
│   npm test                 │ > 3 files changed          │                            │
└────────────────────────────┴────────────────────────────┴────────────────────────────┘
┌─ Tasks ──────────────────────────────────────────────────────────────────────────────┐
│ ● csb-abc [agent1]  ○ csb-ghi [ready]  ○ csb-jkl [ready]  ✓ csb-mno [done]          │
│ ⚡ csb-def [approval]  ✗ csb-xyz [blocked]                                           │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

### Agent Panel Contents

Each agent panel shows:
- **Header:** Agent name and status (idle/working/needs approval/blocked)
- **Task:** Current task ID or "Waiting for task..."
- **Time:** Elapsed time on current task
- **Output:** Last 2-3 lines of agent output (scrollable when focused)

### Agent States

| State | Display | Meaning |
|-------|---------|---------|
| idle | `[idle]` | No task assigned, waiting |
| working | `[working]` | Actively executing a task |
| needs approval | `[needs approval]` | Feature/bug ready to merge, awaiting human |
| blocked | `[blocked]` | Task hit an issue, needs intervention |

### Task Bar Contents

Bottom bar shows all tasks with status icons:
- `●` In progress (with agent name)
- `○` Ready (unclaimed)
- `⚡` Needs approval
- `✗` Blocked
- `✓` Done

## Interaction Model

### Navigation

- **Arrow keys** - Move selection between agents/tasks
- **Enter** - Open action menu for selected item
- **Tab** - Switch focus between agent panels and task bar
- **q** - Quit dashboard (with confirmation if agents are working)

### Agent Actions Menu

When an agent is selected and you press Enter:

```
┌─ agent2 actions ───────────┐
│ > Focus (enter chat)       │
│   View full output         │
│   View dev server :5182    │
│   Restart agent            │
└────────────────────────────┘
```

### Approval Flow

When an agent has state `[needs approval]`:

```
┌─ agent2: Ready to merge ───────────────────────────────────────┐
│                                                                │
│ Task: csb-def - Add user profile page                          │
│ Type: feature                                                  │
│                                                                │
│ Changes:                                                       │
│   src/components/Profile.tsx  (+142, -12)                      │
│   src/api/user.ts             (+28, -3)                        │
│   tests/profile.test.ts       (+87)                            │
│                                                                │
│ Commit: Add user profile page with avatar upload               │
│                                                                │
│ Tests: ✓ All passing (23 tests)                                │
│                                                                │
│ [a] Approve  [r] Reject  [d] View diff  [f] Focus (chat)       │
└────────────────────────────────────────────────────────────────┘
```

**Approve** - Agent proceeds with merge and push, returns to idle.

**Reject** - Opens focus chat so you can explain what needs to change.

**View diff** - Opens full diff in pager (less).

**Focus** - Drop into agent conversation for detailed review/discussion.

## Port Mapping

Each agent gets a dedicated port for dev servers:

| Agent | Port |
|-------|------|
| agent1 | 5181 |
| agent2 | 5182 |
| agent3 | 5183 |
| agent4 | 5184 |

The dashboard shows port in the agent actions menu: "View dev server :5182"

Ports are forwarded from Lima VM to host, so `localhost:5182` reaches agent2's dev server.

### Implementation

In `docker-compose.yml`, ports are already mapped (5173-5273). We need to:
1. Set `PORT` environment variable per agent in interactive mode
2. Update agent `.profile` to use assigned port
3. Show port in dashboard UI

## Architecture

**Two independent components:**

1. **Agent loop** (runs in Docker/Lima) - Claims tasks, runs Claude, writes status files, waits for approval
2. **Dashboard** (runs on host Mac) - Reads status files, shows TUI, writes approval responses

**Communication:** Shared files in `/workspace/.csb/` (mounted volume visible to both).

**Session continuity:** Agents use `claude --continue` to resume conversations. No persistent Claude process needed - the conversation state persists in Claude's session files.

## Focus Mode (Chat)

When you focus on an agent, you attach to its tmux session and can resume its Claude conversation.

**Entering focus:**
- Select agent, press Enter, choose "Focus"
- Dashboard suspends, runs `csb attach agentN`
- You're now in the agent's tmux session (shell prompt)
- Run `claude --continue` to enter the conversation

**In focus mode:**
- Full conversation context preserved from agent's work
- You can review what happened, chat, give instructions
- Agent loop is paused (waiting for approval or between tasks)

**Exiting focus:**
- Exit Claude (Ctrl+C or `/exit`)
- Detach from tmux (`Ctrl+B d`)
- Dashboard resumes

## Agent Loop (Interactive Mode)

```bash
while true; do
  task=$(claim_next_task)
  task_type=$(get_task_type "$task")

  write_status "working" "$task"
  claude "Work on $task. Stop before merging."

  if [[ "$task_type" == "feature" || "$task_type" == "bug" ]]; then
    write_status "needs_approval" "$task"
    write_approval_request  # diff, commit msg, test results
    wait_for_approval       # poll for response file

    if [[ "$(cat approval_response)" == "approved" ]]; then
      claude --continue "Merge approved. Proceed with merge and push."
    else
      claude --continue "Changes requested. Review the feedback."
      continue  # loop back, don't merge
    fi
  fi

  # Chores/refactors auto-merge
  claude --continue "Proceed with merge and push."
  write_status "idle"
done
```

## CLI Interface

```bash
# Start in interactive mode (new)
csb start --mode interactive

# Start in autonomous mode (current default)
csb start --mode autonomous
csb start  # defaults to autonomous for backwards compatibility

# Start specific agents in interactive mode
csb start agent1 agent2 --mode interactive
```

## Implementation Approach

### Phase 1: Agent-Side Approval Gate

Modify `entrypoint.sh` to support interactive mode:
1. Add `--mode` flag to `csb start`, pass `AGENT_MODE=interactive` to docker-compose
2. Create `/workspace/.csb/agentN/` directory structure on startup
3. Write status files (`status`, `task`, `output.log`) as agent works
4. Check task type before merge - features/bugs write approval request and wait
5. Use `claude --continue` pattern for multi-step conversations

### Phase 2: Basic Dashboard (Host-Side)

Standalone Python + Textual app that runs on host Mac:
1. Create `csb-dashboard` script (or `csb dashboard` subcommand)
2. Poll `/workspace/.csb/*/status` files every ~1s
3. Display agent panels with status, task, recent output
4. Display task bar from `bd list` output
5. Implement keyboard navigation (arrows, tab, enter)

### Phase 3: Approval UI

Add approval handling to dashboard:
1. Detect `needs_approval` status, show approval dialog
2. Read approval request (diff summary, commit msg, test results)
3. Handle approve/reject keypresses
4. Write approval response file for agent to read

### Phase 4: Focus Mode

Connect dashboard to agent sessions:
1. On "Focus" action, call `app.suspend()` in Textual
2. Spawn `csb attach agentN` subprocess
3. User is in tmux session, can run `claude --continue`
4. On subprocess exit, resume Textual dashboard

### Phase 5: Port Mapping

Ensure dev server access works:
1. Assign fixed ports: agent1→5181, agent2→5182, etc.
2. Set `PORT` env var in docker-compose per agent
3. Show port in dashboard agent panel
4. Verify Lima forwards ports correctly from VM to host

## State Management

Agents communicate status via shared files in `/workspace/.csb/`:

```
/workspace/.csb/
├── agent1/
│   ├── status          # idle|working|needs_approval|blocked
│   ├── task            # current task ID
│   ├── output.log      # recent output (tail for dashboard)
│   └── approval/       # approval request details
│       ├── type        # feature|bug|chore|refactor
│       ├── diff        # git diff output
│       ├── message     # commit message
│       └── response    # approved|rejected (written by dashboard)
├── agent2/
│   └── ...
└── tasks.json          # cached bd list output
```

## Technology Decisions

1. **Dashboard implementation:** Python + Textual (host-side)
   - Runs on Mac, not in Docker - simpler, native tmux access
   - Full TUI framework built on Rich
   - Handles live updates, keyboard navigation, and panel layouts well
   - Reads shared files from Lima-mounted `/workspace/.csb/`

2. **Agent-dashboard communication:** Shared files
   - Simple, debuggable (just `cat` the files)
   - Works across Docker/Lima boundary via mounted volume
   - ~1s polling latency is acceptable for dashboard

3. **Session continuity:** `claude --continue`
   - No persistent Claude process needed
   - Conversation state persists in Claude's session files
   - Human can resume same conversation via `claude --continue`

4. **Focus mode:** tmux + subprocess
   - Agents run in tmux sessions (via existing `csb attach`)
   - Dashboard suspends Textual, spawns `csb attach agentN`
   - User runs `claude --continue` in the attached session
   - Detach returns to dashboard

5. **Agent output streaming:** Last N lines, no timestamps
   - Simple tail of recent output (3-4 lines per panel)
   - Start simple, add timestamps later if needed

## Success Criteria

- [ ] `csb start --mode interactive` launches dashboard
- [ ] Dashboard shows all agent status in real-time
- [ ] Features/bugs pause for approval before merge
- [ ] Chores/refactors auto-merge without approval
- [ ] Can approve/reject from dashboard
- [ ] Can focus into agent chat and return to dashboard
- [ ] Can view dev server in browser via mapped port
- [ ] Clean exit when quitting dashboard
