#!/usr/bin/env bash
# Starts the Xcode Cloud TestFlight workflow by pushing a testflight/* tag at
# origin/main, so only pushed commits are built. The workflow's start condition
# is a tag beginning with testflight/; see README.md.
set -euo pipefail

git fetch -q origin main --tags
tag="testflight/$(date -u +%Y%m%d-%H%M%S)"
git tag -a "${tag}" -m "TestFlight build" origin/main
git push -q origin "${tag}"
echo "Pushed ${tag} at $(git rev-parse --short origin/main); Xcode Cloud will build and upload it."
