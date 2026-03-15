# CI: Node.js 24 Fix + Automatic apps.json Update — Design

**Date:** 2026-03-15

## Goal

Update `.github/workflows/nightly.yaml` to fix the Node.js 20 deprecation warning and automatically update `apps.json` on every push to `main`.

## Approach

Extend the single existing workflow (Approach A). No new workflow files.

## Trigger

`push` to `main`. The bot's own commit uses `[skip ci]` in the message to prevent an infinite loop.

## Steps

1. **Checkout** — `actions/checkout@v4` (GitHub maintains this floating tag for Node.js 24 compatibility)
2. **Xcode setup** — replace `maxim-lobanov/setup-xcode@v1` with a direct `run` step:
   ```
   sudo xcode-select -s /Applications/Xcode_16.app/Contents/Developer
   ```
   The `macos-26` runner ships with Xcode; no third-party action needed.
3. **Build** — `chmod +x ./buildipa.sh && ./buildipa.sh` (unchanged)
4. **Upload artifact** — `actions/upload-artifact@v4` (unchanged, kept for debugging)
5. **Upload to GitHub Release** — `gh release upload beta build/Shirox.ipa --clobber`
   Overwrites the IPA asset in the existing `beta` release.
6. **Patch apps.json** — inline shell:
   - Size: `wc -c < build/Shirox.ipa`
   - Date: `date -u +%Y-%m-%d`
   - Patch via `jq`: update `apps[0].versions[0].size` and `apps[0].versions[0].date`
   - Commit: `git commit -am "chore: update apps.json [skip ci]" && git push`

## Permissions

Job requires `contents: write` to push the commit and upload the release asset.

## apps.json fields updated automatically

| Field | Source |
|---|---|
| `apps[0].versions[0].date` | `date -u +%Y-%m-%d` at build time |
| `apps[0].versions[0].size` | `wc -c` byte count of the IPA |

Fields left static: `version`, `buildVersion`, `downloadURL`.
