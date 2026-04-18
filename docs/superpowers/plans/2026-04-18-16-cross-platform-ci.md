# Cross-Platform CI (Windows + macOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add continuous integration coverage for Windows and macOS so that every push exercises `zig build check` and `zig build test --summary all` on Linux, Windows, and macOS, closing GAP-0018 and GAP-0019.

**Architecture:** The current CI is GitLab-only and uses `company`-tagged Linux runners (Debian Bookworm Docker images). GitLab runners tagged `windows` / `macos` are not currently available to this project, so the primary path is to publish a GitHub Actions workflow that uses GitHub-hosted `ubuntu-latest`, `windows-latest`, and `macos-latest` runners via a repository mirror. A secondary Option A (GitLab-native jobs) is documented for later if the org provisions tagged runners.

**Tech Stack:** Zig 0.16.0, GitHub Actions, `mlugg/setup-zig@v2` (actively maintained fork of `goto-bus-stop/setup-zig`), PowerShell Core (Windows), Bash (Linux/macOS), optional GitLab CI PowerShell job.

---

## Unblock Prerequisites

This plan is partly **infra-blocked**. The following must be completed by a human (not an agent) before Tasks 2 through 7 are executed. Task 1 documents and verifies these prerequisites.

1. **GitHub mirror provisioned.** The repo is GitLab-primary (`gitlab.com/devnw/zig/toml`). A GitHub mirror (e.g. `github.com/devnw/zig-toml`) must exist and be push-mirrored from GitLab, or be the new canonical remote. Pull requests / pushes must trigger GitHub Actions on the mirror. Assignee: repo maintainer.
2. **GitHub Actions enabled.** On the mirror, Settings -> Actions -> General -> "Allow all actions and reusable actions" (or the org's equivalent allowlist entry for `mlugg/setup-zig` and `actions/checkout`).
3. **(Option A only - deferred) GitLab runners tagged `windows` and `macos`.** Required only if/when the org decides to run cross-platform jobs inside GitLab CI. Assignee: platform ops. If these never arrive, Option A stays parked and Option B is the production answer.
4. **Secrets/tokens review.** No secrets are required for Option B. Confirm `GITHUB_TOKEN` default permissions are sufficient (read-only for `contents` is enough; no packages, no pages). No Zig signing key needed.
5. **Runner cost acceptance.** macOS GitHub-hosted minutes are billed at 10x the Linux rate on private repos. Confirm with billing owner that the expected volume (one macOS job per push + PR) is acceptable, or make the repo public so runners are free.

**Status gate:** Task 1 ends with a go/no-go decision. If prerequisites 1-2 are not satisfied, this plan pauses. Do not attempt to create GitHub workflow files inside a repo that has no GitHub remote.

---

## File Structure

Files created or modified by this plan:

- **Create:** `.github/workflows/ci.yml` - single reusable matrix workflow covering Linux, Windows, macOS. One file keeps configuration DRY and is the established idiom for multi-OS Zig projects.
- **Create (conditional):** `.gitattributes` - pin LF line endings for text files (Task 4 Step 1 only if not already present).
- **Modify:** `README.md` - add CI status badge near the top of the file.
- **Modify:** `CONTRIBUTING.md` - add a "Cross-platform builds" section with Windows/macOS developer notes.
- **Modify:** `docs/GAP_ANALYSIS.md` - mark GAP-0018 and GAP-0019 as closed.
- **Modify:** `CHANGELOG.md` - record the CI addition in the unreleased section.
- **Modify (Option A, deferred):** `.gitlab-ci.yml` - add `build-windows` and `build-macos` jobs and a PowerShell install snippet. Only edit if Prerequisite 3 lands.

Each file has one responsibility: `ci.yml` drives CI execution; `README.md` advertises status; `CONTRIBUTING.md` onboards contributors; `.gitlab-ci.yml` remains the GitLab primary. No refactor of existing files beyond additive edits.

---

## Tasks

### Task 1: Verify Prerequisites and Record Decision

**Files:**

- Modify: `docs/superpowers/plans/2026-04-18-16-cross-platform-ci.md` (this file) - check the boxes below as you confirm each item.

- [ ] **Step 1: Confirm GitHub mirror URL**

Ask the maintainer (or check `git remote -v`) for the GitHub remote. Record the URL here in this plan (replace the placeholder):

```text
GitHub remote: <TBD, e.g. https://github.com/devnw/zig-toml>
```

If there is no GitHub remote, STOP. Option B cannot proceed. Report to the user: "GitHub mirror required; Tasks 2-5 blocked."

- [ ] **Step 2: Confirm Actions are enabled**

Navigate to `https://<github-remote>/settings/actions`. Verify "Allow all actions and reusable actions" is selected (or the specific allowlist includes `mlugg/setup-zig` and `actions/checkout`). If Actions are disabled, STOP and request enablement.

- [ ] **Step 3: Confirm billing / visibility**

If the GitHub repo is **public**, runner minutes on all three OSes are free - proceed.
If the GitHub repo is **private**, confirm with the billing owner that macOS minutes (10x multiplier) are acceptable. Record decision:

```text
Visibility: <public|private>
Billing approved: <yes|no|n/a>
```

- [ ] **Step 4: Record the go/no-go decision**

If Steps 1-3 all pass: write `DECISION: GO (Option B)` below and continue to Task 2.
If any prerequisite is unmet: write `DECISION: BLOCKED - <reason>` and STOP. The plan remains on file and can resume once unblocked.

```text
DECISION: <TBD>
```

- [ ] **Step 5: Commit the decision record**

```bash
git add docs/superpowers/plans/2026-04-18-16-cross-platform-ci.md
git commit -m "docs(plan): record cross-platform CI prerequisite check"
```

---

### Task 2: Create the GitHub Actions Workflow File

**Files:**

- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Create the `.github/workflows/` directory**

Run:

```bash
mkdir -p .github/workflows
```

Expected: directory exists, no error. If it already exists, that is fine.

- [ ] **Step 2: Write the workflow file**

Create `.github/workflows/ci.yml` with **exactly** the following contents. Note: the Zig version pin must match `.gitlab-ci.yml` (currently `0.16.0`).

```yaml
# GitHub Actions CI for toml
# SPDX-License-Identifier: Apache-2.0
#
# Closes GAP-0018 (Windows CI) and GAP-0019 (macOS CI).
# Mirror of the Linux coverage in .gitlab-ci.yml, extended to Windows and macOS
# via GitHub-hosted runners. GitLab CI remains the primary pipeline; this
# workflow exists specifically to exercise non-Linux targets.

name: ci

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

# Cancel superseded runs on the same ref to save runner minutes.
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read

jobs:
  test:
    name: test (${{ matrix.os }})
    runs-on: ${{ matrix.os }}
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, windows-latest, macos-latest]
    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 1

      - name: Configure git line endings (Windows)
        if: runner.os == 'Windows'
        shell: pwsh
        run: |
          git config --global core.autocrlf false
          git config --global core.eol lf

      - name: Install Zig
        uses: mlugg/setup-zig@v2
        with:
          version: 0.16.0

      - name: zig version
        run: zig version

      - name: zig build check
        run: zig build check

      - name: zig build test (Linux/macOS)
        if: runner.os != 'Windows'
        shell: bash
        run: |
          set -o pipefail
          zig build test --summary all 2>&1 | tee test.log
          if grep -qE "(memory leak detected|not freed)" test.log; then
            echo "LEAK GATE: Zig test allocator reported leaked allocations." >&2
            exit 1
          fi
          if ! grep -qE "Build Summary: [0-9]+/[0-9]+ steps succeeded;" test.log; then
            echo "LEAK GATE: no Build Summary line -- test runner aborted early." >&2
            exit 1
          fi
          if grep -qE "[0-9]+ failed" test.log; then
            echo "LEAK GATE: test summary reports failures." >&2
            exit 1
          fi

      - name: zig build test (Windows)
        if: runner.os == 'Windows'
        shell: pwsh
        run: |
          $ErrorActionPreference = 'Stop'
          zig build test --summary all 2>&1 | Tee-Object -FilePath test.log
          if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
          if (Select-String -Path test.log -Pattern 'memory leak detected|not freed' -Quiet) {
            Write-Error 'LEAK GATE: Zig test allocator reported leaked allocations.'
            exit 1
          }
          if (-not (Select-String -Path test.log -Pattern 'Build Summary: [0-9]+/[0-9]+ steps succeeded;' -Quiet)) {
            Write-Error 'LEAK GATE: no Build Summary line -- test runner aborted early.'
            exit 1
          }
          if (Select-String -Path test.log -Pattern '[0-9]+ failed' -Quiet) {
            Write-Error 'LEAK GATE: test summary reports failures.'
            exit 1
          }

      - name: Upload test log on failure
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: test-log-${{ matrix.os }}
          path: test.log
          retention-days: 7
```

- [ ] **Step 3: Lint the YAML locally (if `yq` is available)**

Run:

```bash
yq eval '.' .github/workflows/ci.yml > /dev/null
```

Expected: no output, exit 0. If `yq` is not installed, skip this step - the real validation happens when GitHub parses it.

- [ ] **Step 4: Verify the workflow matches `.gitlab-ci.yml` Zig version**

Run:

```bash
grep ZIG_VERSION .gitlab-ci.yml
grep -E 'version: [0-9]' .github/workflows/ci.yml
```

Expected: both print `0.16.0`. If they disagree, update `ci.yml` (not `.gitlab-ci.yml`) so the two stay in lockstep.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add cross-platform GitHub Actions workflow

Closes GAP-0018 (Windows CI) and GAP-0019 (macOS CI) by running
'zig build check' and 'zig build test --summary all' on
ubuntu-latest, windows-latest, and macos-latest via
GitHub-hosted runners. The leak gate from .gitlab-ci.yml is
mirrored in both Bash (Linux/macOS) and PowerShell (Windows)
forms so leak regressions fail the job on every platform."
```

---

### Task 3: Push and Observe the First Workflow Run

**Files:** none (observation only).

- [ ] **Step 1: Push the branch to GitHub**

If the GitHub remote is named `github` (adjust as needed):

```bash
git push github HEAD
```

Expected: push succeeds. If the remote is `origin` and points to GitHub, use that instead. If only GitLab is configured, add the GitHub remote first:

```bash
git remote add github <github-url-from-task-1>
git push github HEAD
```

- [ ] **Step 2: Watch the workflow run**

Run:

```bash
gh run watch --exit-status
```

Expected: all three matrix legs (ubuntu-latest, windows-latest, macos-latest) reach conclusion. Exit 0 means all passed.

- [ ] **Step 3: If any leg fails, collect the artifact**

```bash
gh run download --name test-log-windows-latest
gh run download --name test-log-macos-latest
gh run download --name test-log-ubuntu-latest
```

Read `test.log` from the failing leg to diagnose. Do not proceed to Task 4 until Task 3 is green. Known categories of failures that Task 4 addresses:

- Path separator assumptions (`/` vs `\`)
- CRLF line endings in fixture files
- Allocator behavior differences (e.g. `std.testing.allocator` on Windows)
- Missing system tools (e.g. `grep`, `sha256sum`)

- [ ] **Step 4: Commit any trivial workflow fixes discovered during observation**

If the workflow itself needs a typo/syntax fix (not a code fix), edit `.github/workflows/ci.yml` and commit:

```bash
git add .github/workflows/ci.yml
git commit -m "ci: fix workflow syntax from first run"
git push github HEAD
```

Repeat Steps 2-4 until the run is green or a genuine code bug is isolated (hand off to Task 4).

---

### Task 4: Fix Windows-Specific Test Failures (if any)

**Files (likely candidates - only edit files that actually fail):**

- `src/**/*.zig` - any code that constructs paths via string concatenation instead of `std.fs.path.join`.
- `tests/**/*.zig` - any fixture loader that hard-codes `/` separators or LF-only comparisons.
- `tests/fixtures/*.toml` - verify these are checked in as LF via `.gitattributes`.

- [ ] **Step 1: Add a `.gitattributes` if missing**

Run:

```bash
test -f .gitattributes && cat .gitattributes || echo "MISSING"
```

If missing, create `.gitattributes` with exactly these contents:

```text
* text=auto eol=lf
*.zig text eol=lf
*.toml text eol=lf
*.md text eol=lf
*.png binary
*.jpg binary
*.gz binary
```

Commit:

```bash
git add .gitattributes
git commit -m "chore: enforce LF line endings via .gitattributes"
```

- [ ] **Step 2: Identify the failing test name**

From the Windows `test.log` (Task 3, Step 3) extract the first failing test's full name. Example: `parser.test.parses basic key=value`.

- [ ] **Step 3: Write a targeted regression test (TDD)**

If the failure is a bug in production code, first add a minimal failing test that reproduces the cross-platform issue. Example pattern for a path-separator bug:

```zig
test "path join is platform-correct" {
    const allocator = std.testing.allocator;
    const joined = try std.fs.path.join(allocator, &.{ "a", "b", "c" });
    defer allocator.free(joined);
    // On Windows this is "a\\b\\c"; on POSIX "a/b/c". Both are correct.
    try std.testing.expect(joined.len == 5);
}
```

Add this to the most relevant existing test file (e.g. `tests/path_test.zig` if one exists, otherwise the file that owns the failing subject).

- [ ] **Step 4: Run the new test on Linux to confirm it passes here**

```bash
zig build test --summary all
```

Expected: PASS on Linux (this confirms the test isn't broken - the bug is platform-specific).

- [ ] **Step 5: Push and confirm it fails on Windows**

```bash
git add tests/
git commit -m "test: reproduce Windows path-separator regression"
git push github HEAD
gh run watch --exit-status || true
```

Expected: Windows leg fails on the new test. This is the reproduction.

- [ ] **Step 6: Fix the production code**

Replace hard-coded `/` separators with `std.fs.path.join`. Replace direct string compares of file contents with a normalizer that treats CRLF and LF as equivalent if fixture files are semantically line-based.

Example fix pattern:

```zig
// BEFORE:
// const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, file });

// AFTER:
const path = try std.fs.path.join(allocator, &.{ dir, file });
defer allocator.free(path);
```

- [ ] **Step 7: Run tests locally, commit, push, watch**

```bash
zig build test --summary all
git add src/ tests/
git commit -m "fix: use std.fs.path.join for cross-platform paths"
git push github HEAD
gh run watch --exit-status
```

Expected: all three legs green. If further failures surface, repeat Steps 2-7 for each one (one test, one fix, one commit - keep each change small).

- [ ] **Step 8: If no failures were observed in Task 3, skip Task 4 entirely**

Mark the task complete with a no-op note in your progress log: "Task 4 skipped - no platform-specific failures observed in Task 3."

---

### Task 5: Add CI Status Badge to README

**Files:**

- Modify: `README.md`

- [ ] **Step 1: Read the current top of `README.md` to locate the badge row**

```bash
head -n 20 README.md
```

Identify where existing badges (if any) live. Badges conventionally go immediately below the title `#` line.

- [ ] **Step 2: Add the GitHub Actions badge**

Insert this line below the existing badge row (or below the title if no badges exist). Replace `<owner>/<repo>` with the GitHub mirror path recorded in Task 1.

```markdown
[![CI](https://github.com/<owner>/<repo>/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/<owner>/<repo>/actions/workflows/ci.yml)
```

- [ ] **Step 3: Verify the badge renders**

```bash
grep -n 'actions/workflows/ci.yml/badge.svg' README.md
```

Expected: one matching line. Open the README in a markdown preview to confirm it renders as an image link.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: add GitHub Actions CI badge to README"
```

- [ ] **Step 5: Push**

```bash
git push github HEAD
```

---

### Task 6 (DEFERRED - Option A): Add Windows + macOS Jobs to `.gitlab-ci.yml`

**Status:** BLOCKED on Prerequisite 3 (GitLab runners tagged `windows` and `macos`). Do not execute this task unless a runner operator has confirmed tagged runners are online and available to this project. If unblocked, execute; otherwise leave this task unchecked.

**Files:**

- Modify: `.gitlab-ci.yml`

- [ ] **Step 1: Confirm runner availability**

Ask the runner admin to provide:

```text
Windows runner tag: <e.g. windows-shell>
macOS runner tag:   <e.g. macos-arm64>
Shell on Windows:   <powershell|pwsh>
```

If any field is missing, STOP and leave Task 6 unchecked.

- [ ] **Step 2: Add a PowerShell install-zig anchor**

Append the following block to `.gitlab-ci.yml` immediately after the existing `.install-zig: &install-zig` block (lines 39-77 in the current file):

```yaml
# PowerShell variant of install-zig for Windows runners.
# Uses the same SHA-256 verification flow as the POSIX variant.
.install-zig-windows: &install-zig-windows
  - |
    $ErrorActionPreference = 'Stop'
    $ZigArch = 'x86_64'
    $Major = [int]($env:ZIG_VERSION.Split('.')[0])
    $Minor = [int]($env:ZIG_VERSION.Split('.')[1])
    if ($Major -eq 0 -and $Minor -lt 15) {
      $ArchiveBase = "zig-windows-$ZigArch-$env:ZIG_VERSION"
    } else {
      $ArchiveBase = "zig-$ZigArch-windows-$env:ZIG_VERSION"
    }
    $Zip = "$ArchiveBase.zip"
    if (-not (Test-Path "zig-$env:ZIG_VERSION\zig.exe")) {
      Invoke-WebRequest -UseBasicParsing -Uri 'https://ziglang.org/download/index.json' -OutFile 'index.json'
      $idx = Get-Content index.json -Raw | ConvertFrom-Json
      $expected = $idx.$env:ZIG_VERSION."$ZigArch-windows".shasum
      if (-not $expected) { throw "SHA-256 not found for $env:ZIG_VERSION/$ZigArch-windows" }
      Invoke-WebRequest -UseBasicParsing -Uri "https://ziglang.org/download/$env:ZIG_VERSION/$Zip" -OutFile $Zip
      $actual = (Get-FileHash -Algorithm SHA256 $Zip).Hash.ToLower()
      if ($actual -ne $expected) { throw "SHA-256 mismatch: expected $expected got $actual" }
      Expand-Archive -Path $Zip -DestinationPath .
      Rename-Item -Path $ArchiveBase -NewName "zig-$env:ZIG_VERSION"
      Remove-Item $Zip, index.json
    }
    $env:PATH = "$PWD\zig-$env:ZIG_VERSION;$env:PATH"
    zig version
```

- [ ] **Step 3: Add the Windows build+test job**

Append this job after `test-release-small` (around line 167 in the current file):

```yaml
build-windows:
  stage: build
  tags:
    - windows  # REPLACE with the exact tag from Task 6 Step 1
  before_script:
    - *install-zig-windows
  script:
    - zig build check
    - zig build test --summary all

build-macos:
  stage: build
  tags:
    - macos  # REPLACE with the exact tag from Task 6 Step 1
  before_script:
    - *install-zig
  script:
    - zig build check
    - zig build test --summary all
```

Note: macOS runners usually have bash, so they reuse `*install-zig`. Confirm in Step 1 that the macOS runner tag is a shell runner (not Docker-on-macOS, which is rare).

- [ ] **Step 4: Validate the YAML locally**

```bash
yq eval '.' .gitlab-ci.yml > /dev/null
```

Expected: exit 0.

- [ ] **Step 5: Push and confirm GitLab picks up the jobs**

```bash
git add .gitlab-ci.yml
git commit -m "ci: add Windows and macOS jobs to GitLab pipeline"
git push origin HEAD
```

Open the merge request's pipeline view. Expected: two new jobs `build-windows` and `build-macos` both green.

- [ ] **Step 6: If jobs stay pending > 10 minutes**

The tagged runners are not picking up the jobs. Revert the commit and revisit Prerequisite 3:

```bash
git revert HEAD
git push origin HEAD
```

Report to the user: "Option A reverted; GitLab runners tagged as requested are not actually handling jobs."

---

### Task 7: Update `CONTRIBUTING.md` with Cross-Platform Build Notes

**Files:**

- Modify: `CONTRIBUTING.md`

- [ ] **Step 1: Read the current file to pick an insertion point**

```bash
grep -n '^##' CONTRIBUTING.md
```

Identify a sensible location - usually after a "Building" or "Development" section. If no such section exists, append the new section at the end.

- [ ] **Step 2: Add the Cross-Platform Builds section**

Append (or insert) **exactly** this block. Do not paraphrase; the exact commands matter:

````markdown
## Cross-Platform Builds

This project's CI runs `zig build check` and `zig build test --summary all` on
Linux, Windows, and macOS. If you develop on one platform, please be aware
of the following cross-platform pitfalls before opening a merge request.

### Paths

Always use `std.fs.path.join` (or `std.fs.path.joinZ`) rather than
concatenating path strings with `/`. On Windows the native separator is `\`,
and hard-coded `/` will surface in file-not-found errors that only manifest
in the Windows CI leg.

### Line endings

The repository pins all text files to LF via `.gitattributes`. If you are
on Windows, make sure your clone preserves LF:

```bash
git config --global core.autocrlf false
git config --global core.eol lf
```

Fixture files under `tests/fixtures/` must be committed as LF; CRLF will
change byte offsets and break parser tests.

### Allocator leak checks

`std.testing.allocator` is a `GeneralPurposeAllocator` with leak checking
enabled. A leak on any platform will fail CI via the leak gate (see
`.gitlab-ci.yml` and `.github/workflows/ci.yml`). When debugging a
Windows-only leak, remember that `GeneralPurposeAllocator`'s page-size
assumptions can differ from POSIX - use `std.heap.page_allocator` only
when the test specifically requires a non-leak-checked allocator.

### Running the full suite locally

```bash
zig build check
zig build test --summary all
```

To exercise release-mode tests the way CI does:

```bash
zig build test -Doptimize=ReleaseSafe --summary all
zig build test -Doptimize=ReleaseFast --summary all
zig build test -Doptimize=ReleaseSmall --summary all
```
````

- [ ] **Step 3: Verify the section was inserted once (not duplicated)**

```bash
grep -c '^## Cross-Platform Builds' CONTRIBUTING.md
```

Expected: `1`.

- [ ] **Step 4: Commit**

```bash
git add CONTRIBUTING.md
git commit -m "docs: add cross-platform build notes to CONTRIBUTING"
```

- [ ] **Step 5: Push**

```bash
git push github HEAD
git push origin HEAD
```

Expected: both remotes updated; the GitHub Actions run on this commit is still green.

---

### Task 8: Close the Gap Entries and Update CHANGELOG

**Files:**

- Modify: `docs/GAP_ANALYSIS.md` - mark GAP-0018 and GAP-0019 as closed.
- Modify: `CHANGELOG.md` - note the CI addition under the unreleased / next-release section.

- [ ] **Step 1: Mark GAP-0018 as closed**

In `docs/GAP_ANALYSIS.md`, locate the GAP-0018 block (starts at line ~199 currently) and append a `Status` line immediately after the `Recommended fix:` line.

The block's last line currently is:

```markdown
- **Recommended fix:** Add Windows runner job or cross-build + test via wine/actions runner.
```

After edit:

```markdown
- **Recommended fix:** Add Windows runner job or cross-build + test via wine/actions runner.
- **Status:** Closed - `.github/workflows/ci.yml` runs `windows-latest` leg.
```

- [ ] **Step 2: Mark GAP-0019 as closed**

Same pattern, in the GAP-0019 block:

```markdown
- **Status:** Closed - `.github/workflows/ci.yml` runs `macos-latest` leg.
```

- [ ] **Step 3: Add a CHANGELOG entry**

Read the top of `CHANGELOG.md` to confirm the "Unreleased" section header (format varies; common is `## [Unreleased]`). Add under "Added" (create the subsection if missing):

```markdown
### Added
- Cross-platform CI via GitHub Actions on Linux, Windows, and macOS
  (closes GAP-0018, GAP-0019).
```

- [ ] **Step 4: Verify both gaps now show Closed**

```bash
grep -A1 'GAP-0018\|GAP-0019' docs/GAP_ANALYSIS.md | grep -c 'Status:'
```

Expected: `2`.

- [ ] **Step 5: Commit**

```bash
git add docs/GAP_ANALYSIS.md CHANGELOG.md
git commit -m "docs: close GAP-0018 and GAP-0019 (cross-platform CI)"
```

- [ ] **Step 6: Push both remotes**

```bash
git push github HEAD
git push origin HEAD
```

Expected: GitHub Actions green on this commit.

---

## Design Notes

- **Why `mlugg/setup-zig` and not a hand-rolled download?** The Linux GitLab job hand-rolls the download+SHA-256 check because the Debian Docker image is minimal and we control the runner. GitHub-hosted runners already have `curl`/`Invoke-WebRequest`, but recreating the SHA-256 flow in three shells (bash, zsh, pwsh) triples the surface area for bugs. `mlugg/setup-zig` is an actively maintained fork of `goto-bus-stop/setup-zig`, pins Zig by version, and caches between runs. The trade-off (trusting a third-party action) is mitigated by pinning to `@v2` and auditing it once.
- **Why keep `.gitlab-ci.yml` as primary?** The company SAST, SBOM, and release components live in GitLab and are not trivially portable. Adding GitHub Actions as a *parallel* CI purely for cross-platform coverage avoids a big-bang migration.
- **Why mirror the leak gate in PowerShell?** The leak regression detector in `.gitlab-ci.yml` is the reason Linux CI catches allocator leaks today. Without a PowerShell equivalent, Windows could silently pass a leak regression. The PowerShell block in Task 2 Step 2 is a line-for-line port.
- **Why `fail-fast: false`?** A Windows-only failure is more informative if macOS still completes in the same run; aborting siblings hides the pattern.
- **Why `concurrency` with `cancel-in-progress: true`?** A push that supersedes a prior push on the same branch does not need the old run to finish. Saves minutes.
- **macOS-latest runner architecture.** `macos-latest` currently resolves to arm64 (Apple Silicon). Zig cross-compiles cleanly to aarch64-macos, and `mlugg/setup-zig` handles the arch detection. No action needed.
- **What Option A buys us if it unblocks.** It folds cross-platform coverage back into the GitLab pipeline, so a single MR view shows all statuses and the release component can gate on non-Linux tests. Until runners exist, Option B is strictly additive and loses nothing.
- **Path separators and fixture bytes.** Parser tests in this repo read fixture `.toml` files and compare byte offsets. A stray CRLF changes those offsets. The `.gitattributes` file pinned in Task 4 Step 1 is the only robust fix; relying on contributor git config alone is not sufficient.
- **Why a single matrix job and not three separate jobs?** A matrix keeps step definitions DRY and ensures all three platforms stay aligned on the Zig version and the leak gate. If a platform needs divergent behavior, gate the step with `if: runner.os == 'X'` (as done for the PowerShell variant).

---

## Self-Review Checklist (run before handoff)

- [ ] Every task's files section lists exact paths, not glob hand-waves.
- [ ] Every code block is complete and copy-pasteable (no `...` or `TBD` inside code).
- [ ] The Zig version pin matches between `.gitlab-ci.yml` (`ZIG_VERSION: "0.16.0"`) and `.github/workflows/ci.yml` (`version: 0.16.0`).
- [ ] The leak gate exists on all three OSes (Task 2 Step 2).
- [ ] Task 1's DECISION line is filled in before any later task runs.
- [ ] `.gitattributes` is added before Task 4 attempts any CRLF-related fix.
- [ ] GAP-0018 and GAP-0019 both get a `Status: Closed` line (Task 8).
- [ ] README badge URL uses the GitHub remote recorded in Task 1 - no placeholder `<owner>/<repo>` remains in the committed file.
- [ ] Option A (Task 6) is clearly marked DEFERRED and will not be executed without Prerequisite 3.
- [ ] Every task ends with a commit.

**Spec coverage check:**

- GAP-0018 (Windows CI) -> Task 2 adds `windows-latest` leg; Task 4 covers any Windows-specific bug fixes; Task 8 closes the gap entry. Covered.
- GAP-0019 (macOS CI) -> Task 2 adds `macos-latest` leg; Task 8 closes the gap entry. Covered.
- Unblock Prerequisites (runners, PowerShell Zig, GitHub mirror) -> Task 1 (mirror + Actions + billing), Task 6 Step 2 (PowerShell Zig install anchor for Option A). Covered.
- Option A vs Option B documentation -> "Architecture" section up front, Task 6 for Option A, Tasks 2-5 for Option B. Covered.
- README badge -> Task 5. Covered.
- CONTRIBUTING cross-platform notes -> Task 7. Covered.

**Placeholder scan:** `<TBD>` appears only inside Task 1 Step 1, Step 3, and Step 4 where it is explicitly a fill-in-the-blank for the human prerequisite check. `<owner>/<repo>` appears in Task 5 Step 2 with an explicit instruction to replace. `<e.g. ...>` placeholders in Task 6 Step 1 are runner-tag fields the admin must supply. No other placeholders.

**Type/name consistency:** Job names `build-windows` / `build-macos` used consistently across Task 6 Steps 3 and 5. Artifact names `test-log-${{ matrix.os }}` used consistently in Task 2 Step 2 and Task 3 Step 3. File paths `.github/workflows/ci.yml` and `.gitlab-ci.yml` used consistently throughout.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-04-18-16-cross-platform-ci.md`.

Because Task 1 is a human-gated prerequisite check and Task 6 is deferred pending runner provisioning, recommended execution mode is **Subagent-Driven**: dispatch a fresh subagent per task starting at Task 2 (after the maintainer completes Task 1 in-session), with review between tasks. Tasks 2-5, 7, and 8 can all run back-to-back once Task 1 returns `DECISION: GO`.

If Prerequisite 3 later unblocks, re-enter the plan at Task 6 only.
