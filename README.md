# Multi-Agent Docker Infrastructure

Run multiple Claude Code agents in Docker containers, coordinated via [beads](https://github.com/steveyegge/beads) issue tracking.

## How It Works

1. **Init service** clones your repo into a shared Docker volume
2. **Agent containers** run Claude Code in autonomous loops
3. Each agent claims tasks from beads, works in isolated git worktrees
4. Completed work is rebased, tested, and pushed to main
5. Failed tasks are marked blocked with detailed comments

## Quick Start

```bash
cd docker

# Set up environment
cp .env.example .env
# Edit .env with your tokens:
#   GITHUB_TOKEN=ghp_xxx
#   CLAUDE_OAUTH_TOKEN=sk-ant-xxx
#   GIT_REPO_URL=https://github.com/owner/repo.git

# Initialize workspace (clone repo)
docker compose up init

# Run a single agent
docker compose up agent1

# Run all 4 agents
docker compose up
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `GITHUB_TOKEN` | GitHub PAT for repo access and pushing |
| `CLAUDE_OAUTH_TOKEN` | Claude Code OAuth token |
| `GIT_REPO_URL` | Repository to work on |
| `AGENT_MODE` | `autonomous` (default) or `interactive` |

## Services

- **init** - Clones repo into shared workspace volume
- **agent1-4** - Autonomous Claude Code agents
- **interactive** - Shell access with port mapping for dev servers

## Interactive Mode

For hands-on work with dev server access:

```bash
docker compose --profile interactive run --service-ports interactive
```

Mapped ports:
- 5181 → 5173 (Vite)
- 3000 → 3000 (Node)
- 8080 → 8080 (API)

## Agent Workflow

Each autonomous agent runs this loop:

1. `bd ready` - Find available tasks
2. Claim task with `bd update --status in_progress`
3. Create git worktree on fresh branch from main
4. Run Claude Code with task prompt
5. Rebase onto latest main
6. Run tests (if present)
7. Fast-forward merge to main
8. Push (with retries)
9. Close task or mark blocked with failure details
10. Clean up worktree, repeat

## Failure Handling

When agents fail, they:
- Abort any partial git operations
- Add detailed comment explaining the failure
- Mark the task as blocked
- Move on to next available task

Failure types tracked:
- `claude_failed` - Claude couldn't complete the task
- `merge_conflict` - Conflicts during rebase
- `test_failure` - Tests failed after rebase
- `push_failed` - Couldn't push after retries

## Architecture

```
┌─────────────────────────────────────────────┐
│              Docker Host                     │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐       │
│  │ agent1  │ │ agent2  │ │ agent3  │  ...  │
│  └────┬────┘ └────┬────┘ └────┬────┘       │
│       │           │           │             │
│       └───────────┼───────────┘             │
│                   ▼                         │
│         ┌─────────────────┐                 │
│         │ workspace volume │                 │
│         │  /workspace/main │ ← shared repo  │
│         │  /workspace/agent1│ ← worktrees   │
│         │  /workspace/agent2│               │
│         └─────────────────┘                 │
└─────────────────────────────────────────────┘
                    │
                    ▼
            GitHub (origin)
```

## Requirements

- Docker with Compose v2
- GitHub repo with beads initialized (`bd init`)
- Valid Claude Code OAuth token
- GitHub PAT with repo access

## License

MIT
