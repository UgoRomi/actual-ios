---
name: release-testflight
description: Publish a TestFlight build of what is on origin/main by running scripts/release-testflight.sh. Use when the user asks to ship, release, or publish a TestFlight build.
disable-model-invocation: true
---

# Publish a TestFlight build

`scripts/release-testflight.sh` tags `origin/main` with `testflight/<UTC timestamp>` and pushes the tag. The tag starts the Xcode Cloud TestFlight workflow, which archives the `ActualNative` scheme and uploads the build to the internal testing group. See "Xcode Cloud and TestFlight" in `README.md`.

Every pushed `testflight/*` tag uploads a build to testers. Only push one through this script, and only once per invocation of this skill. Never create or push the tag by hand.

## 1. See what the build will contain

```sh
git fetch -q origin main --tags
last=$(git tag -l 'testflight/*' --sort=-creatordate | head -1)
git log --oneline "$last"..origin/main
git log --oneline origin/main..main                  # local commits that will NOT be built
```

- If `origin/main` has no commits since the last tag, stop and tell the user. The build would be identical to the last one. Run the script only if they confirm they still want it.
- If local `main` is ahead of `origin/main`, those commits won't be in the build. Tell the user and ask whether to push `main` first (or run `/merge-worktree` if the work is still on a worktree branch).
- If the session is in a worktree with commits that aren't on `origin/main`, point that out too.

## 2. Check the version

```sh
git show origin/main:ActualNative.xcodeproj/project.pbxproj | grep -m1 MARKETING_VERSION
```

Xcode Cloud assigns the build number. Mention the marketing version in the report. Don't change it unless the user asks for a new version. That change is a normal commit that has to land on `origin/main` before release.

## 3. Release

Run the script from any checkout of this repo:

```sh
scripts/release-testflight.sh
```

It prints the tag and the commit it points at. If it fails, report the error. Don't retry with a hand-made tag.

## 4. Report

Report the tag, the short commit, the marketing version, and the commits included since the previous tag. Xcode Cloud then builds the commit and uploads it. Progress shows in App Store Connect under **Xcode Cloud** and **TestFlight**. External testers only get the build once someone adds it to an external group. The first build of a new version waits for Beta App Review.
