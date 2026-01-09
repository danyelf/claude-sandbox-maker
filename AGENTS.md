# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd onboard` to get started.

# Bead Instructions

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --status in_progress  # Claim work
bd close <id>         # Complete work
bd sync               # Sync with git
```

## Worktree-Based Development

Use git worktrees to isolate work on each issue:

**Starting work on an issue:**

```bash
# From main branch, mark the issue as in-progress
bd update <id> --status in_progress
bd sync

# Create a worktree for the issue
git worktree add ../<project>-<id> -b <id>
cd ../<project>-<id>
```

**While working:**
- Do all work in the worktree only
- Keep main clean for other tasks or reviews

**Completing work:**

```bash
# In the worktree: commit your changes
git add -A && git commit -m "Description of changes"

# Rebase against main
git fetch origin main
git rebase origin/main

# Switch to main and merge
cd /path/to/main
git merge <id> --ff-only

# Clean up the worktree
git worktree remove ../<project>-<id>
git branch -d <id>

# Close the issue and push
bd close <id>
bd sync
git push
```

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd sync
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**

- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
