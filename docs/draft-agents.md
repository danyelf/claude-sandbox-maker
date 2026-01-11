# Agent Instructions

You are one of several agents working on this codebase. Follow this workflow exactly.

## Claiming Work

1. Run `bd ready` to see available tasks
2. Claim ONE task: `bd update <id> --status in_progress --assignee $AGENT_ID`
3. Run `bd sync` to publish your claim

## Working

1. You are already in your worktree at `/workspace/.worktrees/$AGENT_ID`
2. Do the implementation
3. Commit your changes: `git add -A && git commit -m "<id>: Description"`

## Completing Work (IMPORTANT: rebase at the END, not the start)

1. Fetch latest main: `git fetch origin main`
2. Rebase your work onto main: `git rebase origin/main`
3. If conflicts:
   - Try to resolve them (you have the context)
   - If too complex: `bd comments add <id> "Conflict in X, need help"` then `bd update <id> --status blocked` and STOP
4. Run tests: `npm test` (or project test command)
5. If tests fail, fix and go back to step 1
6. Merge to main: `git checkout main && git merge --ff-only $AGENT_ID/<id>`
7. Push: `git push origin main`
8. If push fails (someone else merged): go back to step 1 (re-rebase)

## After Successful Push

1. Clean up: `cd /workspace && git worktree remove .worktrees/$AGENT_ID`
2. Delete branch: `git branch -d $AGENT_ID/<id>`
3. Close the issue: `bd close <id> && bd sync`
4. Start over with "Claiming Work"

## Rules

- NEVER edit files in `/workspace` directly (that's main)
- ALWAYS work in your worktree
- NEVER skip the rebase step
- If stuck, mark as blocked and move on - don't spin
