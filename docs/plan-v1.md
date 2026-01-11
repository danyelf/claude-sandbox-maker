# Multi-Agent Workflow Plan v1

## Goals

1. Multiple agents working autonomously on the same codebase
2. Run in `--dangerously` mode to avoid permission prompts for every action
3. Isolate agents in a VM/Docker for safety (protect host data from being stomped)
4. Shared todo list using [Beads](https://github.com/steveyegge/beads/) for coordination

## Current Architecture

### Infrastructure
- **Single VM** containing the main repository
- **Three worktrees** created inside the VM:
  - `agent1/`
  - `agent2/`
  - `agent3/`
- **Separate shell** for merge operations (human-controlled)

### Directory Structure
```
/workspace/              # Main repo (DO NOT edit here)
/workspace-agent1/       # Worktree for agent 1
/workspace-agent2/       # Worktree for agent 2
/workspace-agent3/       # Worktree for agent 3
```

### Agent Workflow

**Starting a task:**
```bash
cd /workspace-agentN
git fetch origin main
git rebase main
# Pick task from beads, start working
```

**While working:**
- Agent works exclusively in their worktree
- Commits changes to their branch
- Should NOT touch /workspace (main)

**Completing a task:**
```bash
git add -A
git commit -m "Description of changes"
# Signal completion (beads update)
```

### Coordinator Workflow (Separate Shell)

**Merging completed work:**
```bash
cd /workspace
git merge agent1  # or agent2, agent3
# Resolve conflicts if any
git push
```

## Problems Encountered

1. **Agents editing main**: Initially had agents start in `/workspace`, but they would edit code in main instead of their worktree
2. **Solution**: Explicitly create separate worktree directories and ensure agents start there

## Open Questions

- How to handle merge conflicts when multiple agents touch the same files?
- How to coordinate task assignment via Beads to avoid duplicate work?
- Should agents be able to see each other's in-progress work?
