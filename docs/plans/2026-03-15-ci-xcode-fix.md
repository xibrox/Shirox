# CI: Fix Xcode Path + Node.js 24 — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix the failing `Build iOS IPA` workflow by removing the broken `Set up Xcode` step and silencing the Node.js 20 deprecation warning.

**Architecture:** Two edits to `.github/workflows/nightly.yaml` — delete 2 lines, add 2 lines. No other files touched.

**Tech Stack:** GitHub Actions YAML

---

### Task 1: Fix `.github/workflows/nightly.yaml`

**Files:**
- Modify: `.github/workflows/nightly.yaml`

The current file looks like this (relevant sections):

```yaml
# shamelessly copied from ...

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
       ...
```

**Step 1: Add top-level `env` block after `on:` block**

Insert these two lines between the `on:` block (ending at line 8) and `jobs:` (line 10):

```yaml
env:
  FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true
```

The result should be:

```yaml
on:
 push:
   branches:
     - main

env:
 FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true

jobs:
```

Note: match the existing 1-space indentation style of the file.

**Step 2: Delete the `Set up Xcode` step entirely**

Remove these 2 lines:

```yaml
     - name: Set up Xcode
       run: sudo xcode-select -s /Applications/Xcode_16.app/Contents/Developer
```

Leave a blank line between `Checkout repository` and `Make build script executable` steps (or don't — either is fine, consistency with the rest of the file is fine).

**Step 3: Validate YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/nightly.yaml'))" && echo "YAML OK"
```

Expected: `YAML OK`

**Step 4: Verify the final file looks correct**

```bash
cat .github/workflows/nightly.yaml
```

Expected structure (6 steps total, no `Set up Xcode`, `env:` block at workflow level):

```yaml
# shamelessly copied from https://github.com/cranci1/Luna/blob/main/.github/workflows/build.yml

name: Build and upload nightly ipa

on:
 push:
   branches:
     - main

env:
 FORCE_JAVASCRIPT_ACTIONS_TO_NODE24: true

jobs:
 build-ios:
   name: Build iOS IPA
   runs-on: macos-26
   permissions:
     contents: write
   steps:
     - name: Checkout repository
       uses: actions/checkout@v4

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
         git diff --cached --quiet || (git commit -m "chore: update apps.json [skip ci]" && git push origin HEAD:main)
```

**Step 5: Commit and push**

```bash
git add .github/workflows/nightly.yaml
git commit -m "ci: remove broken xcode-select step, add Node.js 24 env var"
git push
```

**Step 6: Verify on GitHub**

Go to `https://github.com/xibrox/Shirox/actions` and confirm the new workflow run passes all steps (no more exit code 1, no Node.js 20 warning).
