# Multi-Agent Workflow Design v2

## Problem

Run 4-6 Claude agents on the same codebase, working autonomously on different tasks. They need to:

1. **Not step on each other** - No two agents editing the same files simultaneously
2. **Not harm the host** - They run with `--dangerously-skip-permissions`
3. **Self-coordinate** - Claim tasks, avoid duplicates, merge their own work
4. **Fail gracefully** - Escalate hard problems instead of making a mess

## Key Insight

The hard problems aren't the implementation details (Dockerfiles, shell scripts). They're:

1. **How do agents avoid conflicting edits?** → Worktrees + task-level isolation
2. **How do agents know what's available?** → Shared Beads state
3. **Who resolves merge conflicts?** → Agent who wrote the code (has context)
4. **What happens when push fails?** → Retry with rebase, then escalate

Everything else is plumbing.

## Design Decisions

### Why Docker on Host (Not VMs)?

**Threat model:** Careless Claude agents that overstep bounds, NOT malicious code or adversarial attacks.

We don't need to protect against kernel exploits or container escapes. We need to protect against an agent accidentally running `rm -rf /` or editing files outside its workspace.

| Option             | Startup | Memory/agent | Protection           | Verdict                        |
| ------------------ | ------- | ------------ | -------------------- | ------------------------------ |
| **Docker on host** | Seconds | ~200-500MB   | Filesystem isolation | ✓ Right choice                 |
| Single VM          | Minutes | ~1-2GB       | Stronger isolation   | Overkill                       |
| Docker in VM       | Minutes | ~200-500MB   | Maximum isolation    | Way overkill                   |
| Bare host          | N/A     | N/A          | None                 | Too risky with `--dangerously` |

**Docker on host wins because:**

- Fast startup (seconds, not minutes)
- Lightweight (4-6 agents in ~2-3GB total, not 6-12GB)
- Sufficient protection for careless (not malicious) agents
- Simple setup

**What Docker protects against:**

- Agent runs `rm -rf /` → Only sees mounted scratch folder
- Agent runs `npm install -g` globally → Contained to container
- Agent edits wrong files → Can only see workspace volume

**What Docker does NOT protect against:**

- Credential abuse (agent has `GITHUB_TOKEN`, `ANTHROPIC_API_KEY`)
- Resource exhaustion (can set limits)
- Agent pushing garbage to git (credential issue, not filesystem)

This is acceptable. We're not worried about agents maliciously abusing credentials - just about them accidentally trashing the host filesystem.

**Safe Docker config (required):**

```yaml
# Mount ONLY the scratch workspace - nothing else
volumes:
  - /Users/you/agent-workspace:/workspace
# Do NOT use any of these:
# privileged: true           # Would give host access
# /var/run/docker.sock       # Would allow container escape
# network_mode: host         # Would expose host network
# pid: host                  # Would expose host processes
```

### Why Shared Volume for Beads?

Agents need to see task state instantly. Options:

1. **Git remote only** - Too slow. Agents would claim same tasks.
2. **Shared filesystem** - Instant visibility. ✓
3. **External database** - Overkill for this.

The `.beads/` directory lives on a shared Docker volume. All agents see claims immediately.

### Why Worktrees (Not Branches)?

Each agent needs a working directory. Worktrees give:

- Separate working trees from one `.git`
- No checkout conflicts between agents
- Clean isolation with shared history

Branch-only approach would have checkout races.

### Why Agent Resolves Conflicts?

The agent who wrote the code has the freshest context. Making them resolve during rebase:

- Happens immediately after work (context is hot)
- Agent understands intent of their changes
- Only escalates truly hard cases

Human-resolves-all doesn't scale to 4-6 agents.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Your Host Machine                       │
│                                                              │
│   /Users/you/                                                │
│   ├── Documents/        (agents CANNOT see)                  │
│   ├── code/             (agents CANNOT see)                  │
│   └── agent-workspace/  (agents CAN see - mounted volume)    │
│                                                              │
│   ┌──────────────────────────────────────────────────────┐  │
│   │              Docker Engine (on host)                  │  │
│   │                                                       │  │
│   │  ┌─────────────────────────────────────────────────┐ │  │
│   │  │         Shared Volume: /workspace                │ │  │
│   │  │                                                  │ │  │
│   │  │  /workspace/                                     │ │  │
│   │  │  ├── main/          (main checkout)              │ │  │
│   │  │  │   ├── .git/                                   │ │  │
│   │  │  │   ├── .beads/    (shared, instant sync)       │ │  │
│   │  │  │   └── src/                                    │ │  │
│   │  │  ├── agent1/        (worktree)                   │ │  │
│   │  │  ├── agent2/        (worktree)                   │ │  │
│   │  │  └── agent3/        (worktree)                   │ │  │
│   │  └─────────────────────────────────────────────────┘ │  │
│   │           ▲           ▲           ▲                   │  │
│   │           │           │           │                   │  │
│   │  ┌────────┴──┐ ┌──────┴────┐ ┌────┴──────┐           │  │
│   │  │  Agent 1  │ │  Agent 2  │ │  Agent 3  │  ...      │  │
│   │  │ Container │ │ Container │ │ Container │           │  │
│   │  └───────────┘ └───────────┘ └───────────┘           │  │
│   └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ push/pull (via GITHUB_TOKEN)
                              ▼
                       ┌─────────────┐
                       │   GitHub    │
                       │   Remote    │
                       └─────────────┘
```

**Key points:**

- Agents run in Docker containers directly on your host (no VM)
- Containers can ONLY see the mounted workspace, not your other files
- Shared volume gives instant Beads visibility between agents
- Code flows to/from GitHub via git (agents have `GITHUB_TOKEN`)
- You get completed work by `git pull` on your host

## The Workflow (Conceptual)

Each agent runs this loop:

```
1. FIND WORK      → bd ready
2. CLAIM IT       → bd update --status in_progress (first to sync wins)
3. SET UP         → git worktree add (isolated working directory)
4. DO THE WORK    → Claude implements the task
5. REBASE         → git rebase origin/main (resolve conflicts if any)
6. TEST           → run project tests
7. MERGE & PUSH   → ff-only merge to main, push (retry if race)
8. CLEANUP        → remove worktree, close task
```

When something fails:

- Conflict too hard? Mark blocked, add comment explaining why, move on
- Tests fail after rebase? Mark blocked, move on
- Push keeps failing? Mark blocked after N retries

## Two Modes: Autonomous vs Interactive

Not all work is the same. The system needs to support both:

### Autonomous Mode

**Good for:** Well-specified tasks, cleanup work, mechanical changes, batch operations

- Agent runs in a loop: pick task → do work → merge → repeat
- No human in the loop until something blocks
- Optimized for throughput

**Example tasks:**

- "Add error handling to all API endpoints"
- "Update all imports to use new module path"
- "Add tests for untested functions in src/utils/"

### Interactive Mode

**Good for:** UI work, underspecified tasks, prototyping, tasks needing feedback

- Human picks the task and watches progress
- Agent can run dev server, human can see results
- Back-and-forth until it's right

**Example tasks:**

- "Build a settings page" (needs visual feedback)
- "Improve the checkout flow" (underspecified, needs iteration)
- "Debug why login is slow" (exploratory)

### What's Different

| Aspect          | Autonomous                  | Interactive                     |
| --------------- | --------------------------- | ------------------------------- |
| Task selection  | Agent picks from `bd ready` | Human assigns                   |
| Feedback loop   | None until blocked          | Continuous                      |
| Dev server      | Not needed                  | Often needed                    |
| Merge timing    | Immediately after work      | When human approves             |
| Port allocation | N/A                         | Each agent gets dedicated ports |

Interactive mode needs port mapping so you can hit agent1's dev server at `localhost:5181`, agent2 at `localhost:5182`, etc.

The entrypoint script can take a `--mode` flag, or you can run different compose profiles.

## Open Questions

### 1. Task Granularity

How big should tasks be? Too small = overhead. Too big = conflicts.

**Hypothesis:** Tasks should be ~1-4 hours of work, touching distinct areas of code.

**To validate:** Try a few different sizes, see what causes conflicts.

### 2. Conflict Resolution Quality

Can Claude actually resolve merge conflicts well?

**Hypothesis:** Yes, for straightforward conflicts. Complex semantic conflicts need escalation.

**To validate:** Deliberately create conflicting tasks, see how agents handle.

### 3. Beads Claiming Atomicity

Is `bd update --status in_progress && bd sync` atomic enough?

**Hypothesis:** Shared filesystem means instant visibility, so races are rare. When they happen, second agent sees claim and backs off.

**To validate:** Run 4 agents, all trying to claim same task simultaneously.

### 4. Recovery from Crashes

What if an agent crashes mid-task?

**Hypothesis:** Task stays `in_progress` with stale worktree. Need cleanup mechanism.

**To validate:** Kill agent mid-work, see what state things are in.

## Minimum Viable Experiment

Before building the full system, validate the core assumptions:

### Phase 1: Manual Two-Agent Test

1. Start two Docker containers with shared volume
2. Manually run the workflow commands
3. Verify: claiming works, worktrees work, push retry works

### Phase 2: Single Automated Agent

1. Write entrypoint script
2. Run one agent against real tasks
3. Verify: completes work, handles failures, cleans up

### Phase 3: Multi-Agent Integration

1. Run 2-4 agents simultaneously
2. Create 6-8 independent tasks
3. Verify: no collisions, all work completes

## Implementation Details

_Detailed Dockerfiles, docker-compose.yml, and shell scripts are in the appendix. They're straightforward once the design is settled._

---

## Appendix: Implementation Sketches

### Task Coordination

```bash
# Agent checks for available work
bd ready

# Agent claims a task (first to sync wins)
bd update beads-123 --status in_progress --assignee $AGENT_ID
bd sync
```

Race handling: Second agent sees task already claimed, picks different one.

### Git Workflow (per task)

```bash
# Set up worktree (from /workspace/main)
git fetch origin main
git worktree add /workspace/$AGENT_ID -b $AGENT_ID/beads-123 origin/main
cd /workspace/$AGENT_ID

# ... do work, commit ...

# Rebase and merge
git fetch origin main
git rebase origin/main
npm test
cd /workspace/main
git merge --ff-only $AGENT_ID/beads-123
git push origin main  # retry with backoff if fails

# Cleanup
git worktree remove /workspace/$AGENT_ID
bd close beads-123
```

### Conflict Escalation

```bash
# When agent can't resolve
bd comments add beads-123 "Conflict in src/auth.ts - need human decision"
bd update beads-123 --status blocked
# Agent moves on to next task
```

### Container Setup (sketch)

```dockerfile
FROM ubuntu:24.04
RUN apt-get update && apt-get install -y git nodejs npm jq
RUN npm install -g @anthropic-ai/claude-code beads-cli
WORKDIR /workspace/main
COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
```

```yaml
# docker-compose.yml
volumes:
  workspace:

services:
  init:
    image: alpine/git
    volumes: [workspace:/workspace]
    command: git clone ... /workspace/main

  agent1:
    build: .
    volumes: [workspace:/workspace]
    working_dir: /workspace/main
    environment: [AGENT_ID=agent1, CLAUDE_OAUTH_TOKEN, GITHUB_TOKEN]
```

Full scripts omitted - they're mechanical once the workflow is clear.

## Test Plan

### Must Work Before Proceeding

- [ ] Two containers can see each other's Beads changes instantly
- [ ] Worktree creation/cleanup works reliably
- [ ] Agent can claim task, work, merge, push
- [ ] Push retry handles concurrent pushes correctly

### Nice to Have

- [ ] Interactive mode for debugging
- [ ] Tmux multi-pane setup
- [ ] Port allocation for dev servers

## What Changed from v1

| Aspect       | v1                    | v2                                    |
| ------------ | --------------------- | ------------------------------------- |
| Isolation    | Single VM             | Docker containers                     |
| Git          | Host mount (problems) | Docker volume (clean)                 |
| Conflicts    | Human resolves all    | Agent resolves (escalates hard cases) |
| Coordination | Ad-hoc                | Shared Beads, atomic claiming         |

ççç
