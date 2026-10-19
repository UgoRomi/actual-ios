---
name: merge-worktree
description: Merge the current worktree's branch into local main and push main to origin. Use when the user asks to merge, land, or ship the current worktree.
disable-model-invocation: true
---

# Merge the current worktree into main

Work lands on local `main` as a `--no-ff` merge of a `worktree-*` branch, then `main` is pushed to `origin/main`. Origin's default branch (`feature/native-ios`) is stale; never merge into it or base anything on it.

## 1. Check where you are

```sh
git rev-parse --abbrev-ref HEAD                      # the branch to merge
git rev-parse --git-dir --git-common-dir             # differ inside a worktree
git worktree list --porcelain | sed -n '1s/^worktree //p'   # main checkout path
```

- Stop if the current branch is `main`, or if the session is not in a linked worktree. Ask which worktree to merge instead of guessing.
- Call the main checkout path `$MAIN` below. Steps 2–3 run in the worktree. Step 4 runs from `$MAIN` itself, because an isolated session can't point git at the shared checkout with `git -C`.

## 2. Commit and push the branch

- Run `git status --short`. If there are uncommitted changes that belong to this task, commit them with a descriptive message. If they look unrelated or half-finished, show them and ask before committing.
- If the work changed behaviour that `docs/` or `README.md` describes, make sure those docs were updated (see `AGENTS.md`).
- Push the branch: `git push -u origin HEAD`.

## 3. Bring the branch up to date with main

```sh
git fetch -q origin main
git rev-list --left-right --count main...origin/main   # "<local-only> <origin-only>"
git merge-base --is-ancestor main HEAD && git merge-base --is-ancestor origin/main HEAD
```

- If local `main` and `origin/main` have both moved (neither count is 0), stop and report.
- If the branch is missing commits from either one, merge the newer of the two into the branch here in the worktree: `git merge origin/main` or `git merge main`. Resolve any conflicts in the worktree, rerun the relevant `scripts/test-*.sh` for the touched area, commit, and push again. Main itself should only ever receive a conflict-free merge.

Scripts that need the Actual checkout don't find `../actual` from a worktree, so run them with `ACTUAL_SOURCE=/Users/ugowork/Projects/Personal/actual`.

## 4. Merge and push main

If this session entered the worktree with `EnterWorktree`, leave it with `ExitWorktree` (`action: "keep"`), which returns to `$MAIN`. Then run these from `$MAIN`:

```sh
git status --short --branch                          # must be on main
git merge --ff-only origin/main                      # only if main is behind origin/main
git merge --no-ff --no-edit <branch>                 # "Merge branch '<branch>'"
git push origin main
```

- If `$MAIN` isn't on `main`, stop and report. Don't switch the user's checkout.
- Tracked, uncommitted changes in `$MAIN` that touch files the merge changes will block it. Untracked files such as `plan.json` are fine unless the branch adds the same path. Don't stash or discard the user's changes. Stop and report instead.
- If the merge stops for any reason, run `git merge --abort` and go back to step 3 in the worktree (`EnterWorktree` with its `path`) to fix the problem.

## 5. Report

Report the merge commit (`git log -1 --oneline`) and confirm that `origin/main` matches it. Leave the worktree and branch in place unless the user asks to remove them. Pushing main does not start a TestFlight build. Mention `/release-testflight` if the user wants one.
