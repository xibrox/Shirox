# CI: Node.js 24 Fix + Automatic apps.json Update — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Update `.github/workflows/nightly.yaml` so it builds on Node.js 24-compatible actions, uploads the IPA to the `beta` GitHub Release, and auto-patches `apps.json` with the new size and date on every push to `main`.

**Architecture:** Single workflow file (`nightly.yaml`) extended with two new jobs steps. The `maxim-lobanov/setup-xcode` third-party action is replaced with a direct shell command. After the build, `gh` CLI (pre-installed on macOS runners) uploads the IPA to the existing `beta` release and patches `apps.json` using `jq`, then commits back with `[skip ci]` to avoid re-triggering.

**Tech Stack:** GitHub Actions, `gh` CLI, `jq`, bash

---

### Task 1: Replace `maxim-lobanov/setup-xcode` and fix Node.js 24

**Files:**
- Modify: `.github/workflows/nightly.yaml`

The `macos-26` runner ships with Xcode 16. We select it with `xcode-select` directly, removing the unmaintained third-party action. `actions/checkout@v4` and `actions/upload-artifact@v4` are maintained by GitHub and will be updated for Node.js 24 automatically — no version pin change needed.

**Step 1: Edit the workflow — remove `Set up Xcode` step, replace with shell command**

Open `.github/workflows/nightly.yaml` and replace:

```yaml
    - name: Set up Xcode
      uses: maxim-lobanov/setup-xcode@v1
      with:
        xcode-version: latest-stable
```

With:

```yaml
    - name: Set up Xcode
      run: sudo xcode-select -s /Applications/Xcode_16.app/Contents/Developer
```

**Step 2: Validate YAML syntax**

Run:
```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/nightly.yaml'))" && echo "YAML OK"
```
Expected: `YAML OK`

**Step 3: Commit**

```bash
git add .github/workflows/nightly.yaml
git commit -m "ci: replace maxim-lobanov/setup-xcode with direct xcode-select"
```

---

### Task 2: Add `contents: write` permission and GitHub Release upload step

**Files:**
- Modify: `.github/workflows/nightly.yaml`

The `gh` CLI needs `contents: write` to upload assets to a release. We also need to ensure the `beta` release exists before uploading (use `gh release create` with `--update` flag if needed).

**Step 1: Add `permissions` block to the job**

In `.github/workflows/nightly.yaml`, add a `permissions` block to the `build-ios` job, right after `runs-on`:

```yaml
jobs:
  build-ios:
    name: Build iOS IPA
    runs-on: macos-26
    permissions:
      contents: write
```

**Step 2: Add the release upload step after `Upload IPA`**

Append after the existing `Upload IPA` step:

```yaml
    - name: Upload IPA to beta release
      env:
        GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      run: |
        gh release create beta --title "beta" --notes "Latest nightly build" 2>/dev/null || true
        gh release upload beta build/Shirox.ipa --clobber
```

`|| true` on `gh release create` means: create the release if it doesn't exist; silently no-op if it already does. `--clobber` overwrites the existing `Shirox.ipa` asset.

**Step 3: Validate YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/nightly.yaml'))" && echo "YAML OK"
```
Expected: `YAML OK`

**Step 4: Commit**

```bash
git add .github/workflows/nightly.yaml
git commit -m "ci: upload IPA to beta GitHub Release on every push to main"
```

---

### Task 3: Auto-patch apps.json with size and date

**Files:**
- Modify: `.github/workflows/nightly.yaml`

After uploading the IPA, we read its byte size, get today's UTC date, patch `apps.json` using `jq`, then commit and push. The commit message includes `[skip ci]` so GitHub Actions does not re-trigger the workflow.

**Step 1: Add the apps.json patch step**

Append after `Upload IPA to beta release`:

```yaml
    - name: Update apps.json
      env:
        GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
      run: |
        IPA_SIZE=$(wc -c < build/Shirox.ipa | tr -d ' ')
        BUILD_DATE=$(date -u +%Y-%m-%d)
        jq --argjson size "$IPA_SIZE" --arg date "$BUILD_DATE" \
          '.apps[0].versions[0].size = $size | .apps[0].versions[0].date = $date' \
          apps.json > apps.json.tmp && mv apps.json.tmp apps.json
        git config user.name "github-actions[bot]"
        git config user.email "github-actions[bot]@users.noreply.github.com"
        git add apps.json
        git diff --cached --quiet || git commit -m "chore: update apps.json [skip ci]"
        git push
```

`git diff --cached --quiet || ...` means: only commit if `apps.json` actually changed (prevents empty commits on identical builds).

**Step 2: Validate YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/nightly.yaml'))" && echo "YAML OK"
```
Expected: `YAML OK`

**Step 3: Verify the final workflow looks like this**

The complete `.github/workflows/nightly.yaml` should be:

```yaml
name: Build and upload nightly ipa

on:
  push:
    branches:
      - main

jobs:
  build-ios:
    name: Build iOS IPA
    runs-on: macos-26
    permissions:
      contents: write
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Set up Xcode
        run: sudo xcode-select -s /Applications/Xcode_16.app/Contents/Developer

      - name: Make build script executable
        run: chmod +x ./buildipa.sh

      - name: Build iOS IPA
        run: ./buildipa.sh

      - name: Upload IPA
        uses: actions/upload-artifact@v4
        with:
          name: Shirox-Nightly-IPA
          path: build/Shirox.ipa

      - name: Upload IPA to beta release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh release create beta --title "beta" --notes "Latest nightly build" 2>/dev/null || true
          gh release upload beta build/Shirox.ipa --clobber

      - name: Update apps.json
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          IPA_SIZE=$(wc -c < build/Shirox.ipa | tr -d ' ')
          BUILD_DATE=$(date -u +%Y-%m-%d)
          jq --argjson size "$IPA_SIZE" --arg date "$BUILD_DATE" \
            '.apps[0].versions[0].size = $size | .apps[0].versions[0].date = $date' \
            apps.json > apps.json.tmp && mv apps.json.tmp apps.json
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add apps.json
          git diff --cached --quiet || git commit -m "chore: update apps.json [skip ci]"
          git push
```

**Step 4: Commit**

```bash
git add .github/workflows/nightly.yaml
git commit -m "ci: auto-patch apps.json with IPA size and date on every push to main"
```

---

### Task 4: Push and verify

**Step 1: Push to main**

```bash
git push
```

**Step 2: Watch the workflow run**

Go to `https://github.com/xibrox/Shirox/actions` and confirm:
- All steps pass (green)
- `Upload IPA to beta release` step shows "Uploaded 1 asset"
- `Update apps.json` step shows a commit pushed (or "nothing to commit" if size/date unchanged)

**Step 3: Verify apps.json was updated**

```bash
git pull && cat apps.json | python3 -m json.tool | grep -E '"date"|"size"'
```
Expected: `"date"` is today's UTC date, `"size"` matches the actual IPA byte count.

**Step 4: Verify the beta release has the new IPA**

Go to `https://github.com/xibrox/Shirox/releases/tag/beta` and confirm `Shirox.ipa` is listed as a release asset.
