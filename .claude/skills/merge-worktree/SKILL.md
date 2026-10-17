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
- Call the main checkout path `$MAIN` below. Confirm `git -C "$MAIN" rev-parse --abbrev-ref HEAD` prints `main`. If it doesn't, stop and report; don't switch the user's checkout.

## 2. Commit and push the branch

- Run `git status --short`. If there are uncommitted changes that belong to this task, commit them with a descriptive message. If they look unrelated or half-finished, show them and ask before committing.
- If the work changed behaviour that `docs/` or `README.md` describes, make sure those docs were updated (see `AGENTS.md`).
- Push the branch: `git push -u origin HEAD`.

## 3. Bring the branch up to date with main

```sh
git fetch -q origin main
git -C "$MAIN" status --short --branch
```

- If local `main` is behind `origin/main`, fast-forward it: `git -C "$MAIN" merge --ff-only origin/main`. If it has diverged, stop and report.
- Tracked, uncommitted changes in `$MAIN` that touch files the merge changes will block it. Untracked files such as `plan.json` are fine unless the branch adds the same path. Don't stash or discard the user's changes. Stop and report instead.
- If the branch doesn't contain `main` (`git merge-base --is-ancestor main HEAD` fails), merge main into the branch here in the worktree first: `git merge main`. Resolve any conflicts in the worktree, rerun the relevant `scripts/test-*.sh` for the touched area, commit, and push again. Main itself should only ever receive a conflict-free merge.

Scripts that need the Actual checkout don't find `../actual` from a worktree, so run them with `ACTUAL_SOURCE=/Users/ugowork/Projects/Personal/actual`.

## 4. Merge and push main

```sh
git -C "$MAIN" merge --no-ff --no-edit <branch>      # "Merge branch '<branch>'"
git -C "$MAIN" push origin main
```

If the merge stops for any reason, run `git -C "$MAIN" merge --abort`, go back to step 3, and fix the problem in the worktree.

## 5. Report

Report the merge commit (`git -C "$MAIN" log -1 --oneline`) and confirm that `origin/main` matches it. Leave the worktree and branch in place unless the user asks to remove them. Pushing main does not start a TestFlight build. Mention `/release-testflight` if the user wants one.
