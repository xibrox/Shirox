# CI: Fix Xcode Path + Node.js 24 — Design

**Date:** 2026-03-15

## Problem

Two issues in `.github/workflows/nightly.yaml`:

1. `sudo xcode-select -s /Applications/Xcode_16.app/Contents/Developer` fails on the `macos-26` ARM64 runner with "invalid developer directory" — the path doesn't exist on macOS 26.
2. `actions/checkout@v4` and `actions/upload-artifact@v4` still run on Node.js 20, producing deprecation warnings.

## Fix

Two changes to `.github/workflows/nightly.yaml`:

1. **Delete the `Set up Xcode` step** — the `macos-26` runner has Xcode pre-installed and pre-selected; the step is unnecessary and was the direct cause of the build failure.

2. **Add `FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true` as a top-level workflow `env` var** — silences the Node.js 20 deprecation warning for all actions in the job without requiring version pins.

## Result

Workflow goes from 7 steps to 6 steps. No other changes.
