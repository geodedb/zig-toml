# Supply-Chain Signed Tags & Two-Reviewer Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close S-10 (CWE-1357 / CWE-829) by enforcing a two-reviewer approval policy for `build.zig.zon` bumps and verifying signed tags from the `thread_pool` upstream before CI consumes them.

**Architecture:** Two workstreams. **(A) Signed-tag verification** — a pre-fetch CI job clones `gitlab.com/devnw/zig/thread-pool`, runs `git tag -v <tag>` against a committed allowlist of public keys, and fails the pipeline if verification fails. **(B) MR approval policy** — `CODEOWNERS` requires `@security-team` on `build.zig.zon`, and `SECURITY.md` documents the rationale. Workstream B ships first (unblocked); Workstream A is gated on upstream publishing signed tags and cannot complete today.

**Tech Stack:** GitLab CI (`.gitlab-ci.yml`), Git (`git tag -v`, GPG keyring), GPG 2.x, Markdown docs, Zig package manager (`build.zig.zon`).

---

## Unblock Prerequisites

**This plan cannot be fully executed until all three prerequisites are satisfied.** Tasks 1–3 and Task 6 Step 1 ship immediately. Tasks 4–5 and the remaining Task 6 steps are blocked on upstream cooperation and MUST NOT be started until verified complete.

- [ ] **Prereq 1: Upstream `devnw/zig/thread-pool` publishes signed tags**
  - Verify: `git clone https://gitlab.com/devnw/zig/thread-pool.git /tmp/thread-pool-verify && cd /tmp/thread-pool-verify && git tag -l --format='%(refname:short) %(objecttype)'` shows tags of type `tag` (annotated/signed), not `commit` (lightweight).
  - Verify: `cd /tmp/thread-pool-verify && git tag -v <latest-tag>` exits 0 after importing the upstream maintainer's public key (see Prereq 2). Output must contain `gpg: Good signature from "<maintainer>"`.
  - If output contains `error: <tag>: cannot verify a non-tag object` or `gpg: Can't check signature: No public key`, the prerequisite is NOT met.
  - Track as a cross-repo issue in the devnw GitLab group titled `thread-pool: publish signed tags (supply-chain S-10)`.

- [ ] **Prereq 2: devnw team agrees on two-reviewer policy for `build.zig.zon` bumps**
  - This is a process change, not code. Requires written agreement (recorded in a GitLab issue or RFC) from the maintainer group that any MR touching `build.zig.zon` requires:
    1. One approval from `@security-team`
    2. One approval from a separate `@maintainers` member (cannot be the author)
  - Verify: GitLab issue link committed in `SECURITY.md` references the policy decision.

- [ ] **Prereq 3: GitLab MR approval rules require two approvers for `build.zig.zon` changes**
  - Configure via GitLab UI: Settings → Merge Requests → Merge Request Approvals → Add Rule.
  - Rule name: `build.zig.zon supply-chain review`
  - Target branch: `main`
  - Approvers required: `2`
  - Eligible approvers: group `@security-team` + group `@maintainers`
  - File path condition: `build.zig.zon`
  - Verify by submitting a dummy MR that touches `build.zig.zon`; GitLab must block merge until two approvals are collected.
  - API verification: run `glab api projects/:id/approval_rules` and confirm a rule exists with `approvals_required >= 2`, `protected_branches` including `main`, and a file-path pattern matching `build.zig.zon`.

**Once all three prerequisites are checked off, continue with Tasks 4–6. Record the date each prereq was satisfied in this document before proceeding.**

---

## File Structure

Files created or modified by this plan:

- **Modify:** `/home/benji/src/devnw/zig/toml/CODEOWNERS` — add `@security-team` to `build.zig.zon`; add new entry for `/trusted_keys/`.
- **Modify:** `/home/benji/src/devnw/zig/toml/SECURITY.md` — new section "Dependency Update Policy" documenting the two-reviewer rule and signed-tag verification process.
- **Create:** `/home/benji/src/devnw/zig/toml/trusted_keys/README.md` — one-paragraph directory purpose.
- **Create:** `/home/benji/src/devnw/zig/toml/trusted_keys/.gitkeep` — ensures directory is tracked while empty.
- **Create:** `/home/benji/src/devnw/zig/toml/trusted_keys/thread-pool-maintainers.asc` (Task 4, blocked) — ASCII-armored public key from upstream maintainer.
- **Create:** `/home/benji/src/devnw/zig/toml/scripts/verify-thread-pool-tag.sh` (Task 4, blocked) — portable shell helper: clone upstream, import trusted keys, run `git tag -v`.
- **Modify:** `/home/benji/src/devnw/zig/toml/.gitlab-ci.yml` (Tasks 4 & 5, blocked) — add `verify-supply-chain` and `lint-zon-pin-format` jobs in the `lint` stage.
- **Modify:** `/home/benji/src/devnw/zig/toml/build.zig.zon` (Task 4, blocked) — migrate pin from commit SHA to `refs/tags/<tag>`.
- **Modify:** `/home/benji/src/devnw/zig/toml/CHANGELOG.md` — record the policy (unblocked) and the CI verification (blocked, later commit).
- **Modify:** `/home/benji/src/devnw/zig/toml/docs/ARCHITECTURE.md` — add "Supply-Chain Integrity" section.
- **Modify:** `/home/benji/src/devnw/zig/toml/docs/SECURITY_GAP_ANALYSIS.md` — mark S-10 CLOSED only after Task 5 ships. Do NOT close after Task 3 alone — policy without CI enforcement is partial mitigation.

---

## Task 1: Extend CODEOWNERS to require `@security-team` on `build.zig.zon`

**Workstream:** B (unblocked)

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/CODEOWNERS:15`

- [ ] **Step 1: Read the current CODEOWNERS entry for `build.zig.zon`**

Run: `grep -n '^build.zig.zon' /home/benji/src/devnw/zig/toml/CODEOWNERS`
Expected output: `15:build.zig.zon       @maintainers`

- [ ] **Step 2: Replace the `build.zig.zon` line**

Edit `/home/benji/src/devnw/zig/toml/CODEOWNERS`. Replace the exact line:

```text
build.zig.zon       @maintainers
```

with:

```text
# S-10: supply-chain dependency pins require security review (CWE-1357 / CWE-829)
build.zig.zon       @security-team @maintainers
```

- [ ] **Step 3: Verify the change**

Run: `grep '^build.zig.zon' /home/benji/src/devnw/zig/toml/CODEOWNERS`
Expected output: `build.zig.zon       @security-team @maintainers`

Run: `grep -c '^[^#[:space:]]' /home/benji/src/devnw/zig/toml/CODEOWNERS`
Expected: at least `6` (default `*`, `SECURITY.md`, `.gitlab-ci.yml`, `.gitleaks.toml`, `build.zig`, `build.zig.zon`).

- [ ] **Step 4: Commit**

```bash
cd /home/benji/src/devnw/zig/toml
git add CODEOWNERS
git commit -m "chore(security): require @security-team on build.zig.zon (S-10)"
```

---

## Task 2: Add "Dependency Update Policy" section to SECURITY.md

**Workstream:** B (unblocked)

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/SECURITY.md` — insert new section above `## Security Updates`.

- [ ] **Step 1: Locate the `## Security Updates` heading**

Run: `grep -n '^## ' /home/benji/src/devnw/zig/toml/SECURITY.md`
Expected: a line `44:## Security Updates` (line number may differ; confirm exact line before editing).

- [ ] **Step 2: Insert the new section directly above `## Security Updates`**

Edit `/home/benji/src/devnw/zig/toml/SECURITY.md`. Find the exact text:

```markdown
## Security Updates
```

Replace it with:

```markdown
## Dependency Update Policy

Supply-chain integrity for this project relies on more than pinning commit
hashes. A compromised upstream maintainer account can push a malicious
commit, and a reviewer who only diff-checks the hash bump would silently
adopt it. See S-10 (CWE-1357 / CWE-829).

### Two-reviewer rule

Any merge request that modifies `build.zig.zon` requires **two** approvals:

1. One approval from the `@security-team` group.
2. One approval from a separate `@maintainers` member (cannot be the MR
   author).

Enforcement:

- `CODEOWNERS` lists `@security-team @maintainers` as owners of
  `build.zig.zon`.
- GitLab MR approval rules require 2 distinct approvers before merge into
  `main`.

### Signed-tag verification

When a dependency upstream publishes signed tags, our CI verifies the
signature against a committed allowlist of public keys
(`trusted_keys/*.asc`) before the pipeline consumes the pinned revision.

- The verification job runs in the `lint` stage and must pass before any
  `build`, `test`, or `release` job executes.
- The verification helper: `scripts/verify-thread-pool-tag.sh`.
- Trusted keys live under `trusted_keys/` and are themselves
  `CODEOWNERS`-gated to `@security-team` — keys cannot be added without
  security-team review.

### Rationale

Hash pinning protects against unauthorized modification of a *specific*
commit but does not prevent a maintainer compromise from minting a new
malicious commit. Signed tags plus a two-reviewer policy raise the
attacker's bar to compromising both a maintainer GPG key and a reviewer.

## Security Updates
```

- [ ] **Step 3: Verify the new section is well-formed**

Run: `grep -n '^## Dependency Update Policy' /home/benji/src/devnw/zig/toml/SECURITY.md`
Expected: exactly one match.

Run: `grep -c '^### ' /home/benji/src/devnw/zig/toml/SECURITY.md`
Expected: at least `3` (Two-reviewer rule, Signed-tag verification, Rationale).

- [ ] **Step 4: Commit**

```bash
cd /home/benji/src/devnw/zig/toml
git add SECURITY.md
git commit -m "docs(security): document two-reviewer + signed-tag policy (S-10)"
```

---

## Task 3: Scaffold `trusted_keys/` directory with README and CODEOWNERS gate

**Workstream:** B (unblocked; directory remains empty until Prereq 1 is met).

**Files:**

- Create: `/home/benji/src/devnw/zig/toml/trusted_keys/README.md`
- Create: `/home/benji/src/devnw/zig/toml/trusted_keys/.gitkeep`
- Modify: `/home/benji/src/devnw/zig/toml/CODEOWNERS` — gate the directory to `@security-team`.

- [ ] **Step 1: Create the directory and placeholder**

Run:

```bash
mkdir -p /home/benji/src/devnw/zig/toml/trusted_keys
touch /home/benji/src/devnw/zig/toml/trusted_keys/.gitkeep
```

- [ ] **Step 2: Write `trusted_keys/README.md`**

Create `/home/benji/src/devnw/zig/toml/trusted_keys/README.md` with:

```markdown
# Trusted Upstream Keys

This directory holds ASCII-armored GPG public keys (`*.asc`) used by CI to
verify signed tags on upstream dependencies. See `SECURITY.md` section
"Signed-tag verification" and S-10 in `docs/SECURITY_GAP_ANALYSIS.md`.

## Adding a key

1. Obtain the maintainer's public key out-of-band (not from the same source
   hosting the dependency). Confirm the fingerprint via a second channel.
2. Save as `trusted_keys/<upstream-name>-maintainers.asc`.
3. Open an MR. `CODEOWNERS` routes it to `@security-team` for approval.
4. Record the key's fingerprint and the provenance check in the MR
   description.

## Removing a key

Removing a key invalidates future tag verifications signed only by that
key. Remove via an MR reviewed by `@security-team`, and bump any pinned
dependency that relied on the key in the same MR.
```

- [ ] **Step 3: Gate `trusted_keys/` in CODEOWNERS**

Edit `/home/benji/src/devnw/zig/toml/CODEOWNERS`. Find the exact block added in Task 1:

```text
# S-10: supply-chain dependency pins require security review (CWE-1357 / CWE-829)
build.zig.zon       @security-team @maintainers
```

Replace with:

```text
# S-10: supply-chain dependency pins require security review (CWE-1357 / CWE-829)
build.zig.zon       @security-team @maintainers

# S-10: trusted upstream keys — security-team gates additions/removals
/trusted_keys/      @security-team
```

- [ ] **Step 4: Verify**

Run: `ls -la /home/benji/src/devnw/zig/toml/trusted_keys/`
Expected: both `README.md` and `.gitkeep` listed.

Run: `grep -n '/trusted_keys/' /home/benji/src/devnw/zig/toml/CODEOWNERS`
Expected: one match containing `@security-team`.

- [ ] **Step 5: Commit**

```bash
cd /home/benji/src/devnw/zig/toml
git add trusted_keys/README.md trusted_keys/.gitkeep CODEOWNERS
git commit -m "chore(security): scaffold trusted_keys/ with security-team ownership (S-10)"
```

---

## Task 4: Add signed-tag verification script and CI job

**Workstream:** A — **BLOCKED on Unblock Prerequisites 1, 2, 3.**

Do NOT start this task until all three prereqs are checked off at the top of this plan.

**Files:**

- Create: `/home/benji/src/devnw/zig/toml/trusted_keys/thread-pool-maintainers.asc`
- Create: `/home/benji/src/devnw/zig/toml/scripts/verify-thread-pool-tag.sh`
- Modify: `/home/benji/src/devnw/zig/toml/.gitlab-ci.yml` — add `verify-supply-chain` job in the `lint` stage.
- Modify: `/home/benji/src/devnw/zig/toml/build.zig.zon` — migrate pin from commit SHA to signed tag.

- [ ] **Step 1: Write the verification helper script**

Create `/home/benji/src/devnw/zig/toml/scripts/verify-thread-pool-tag.sh`:

```bash
#!/usr/bin/env sh
# verify-thread-pool-tag.sh
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2026 CodePros
#
# Verifies that the thread_pool tag pinned in build.zig.zon has a valid
# signature from a key in trusted_keys/. See S-10 / SECURITY.md.
#
# Exit codes:
#   0  signature verified
#   1  verification failed (bad or missing signature, unknown key, bad tag)
#   2  input parse error (no tag could be extracted from build.zig.zon)

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZON="${REPO_ROOT}/build.zig.zon"
TRUSTED_DIR="${REPO_ROOT}/trusted_keys"
UPSTREAM_URL="https://gitlab.com/devnw/zig/thread-pool.git"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

# Extract the tag reference from build.zig.zon. Pre-migration SHAs are
# rejected with exit 2.
TAG="$(awk '
  /thread_pool/,/}/ {
    if (match($0, /#refs\/tags\/[^"]+/)) {
      s = substr($0, RSTART + 11, RLENGTH - 11)
      print s
      exit
    }
  }
' "${ZON}")"

if [ -z "${TAG}" ]; then
  echo "ERROR: no refs/tags/ reference found in build.zig.zon for thread_pool." >&2
  echo "       Migrate the pin from a commit SHA to a signed tag per S-10." >&2
  exit 2
fi

echo "verifying thread_pool tag: ${TAG}"

# Ephemeral GPG home so CI runners don't leak state.
export GNUPGHOME="${WORKDIR}/gnupg"
mkdir -p "${GNUPGHOME}"
chmod 700 "${GNUPGHOME}"

KEYS_FOUND=0
for key in "${TRUSTED_DIR}"/*.asc; do
  [ -f "${key}" ] || continue
  gpg --batch --import "${key}"
  KEYS_FOUND=1
done

if [ "${KEYS_FOUND}" -eq 0 ]; then
  echo "ERROR: no trusted keys in ${TRUSTED_DIR}/*.asc" >&2
  exit 1
fi

git clone --depth=1 --branch "${TAG}" "${UPSTREAM_URL}" "${WORKDIR}/tp"
cd "${WORKDIR}/tp"

if ! git tag -v "${TAG}" 2>&1 | tee "${WORKDIR}/verify.log"; then
  echo "ERROR: tag verification failed for ${TAG}" >&2
  exit 1
fi

if ! grep -q 'Good signature' "${WORKDIR}/verify.log"; then
  echo "ERROR: no 'Good signature' line in git tag -v output" >&2
  exit 1
fi

echo "OK: thread_pool ${TAG} verified against trusted_keys/"
```

Make it executable:

```bash
chmod +x /home/benji/src/devnw/zig/toml/scripts/verify-thread-pool-tag.sh
```

- [ ] **Step 2: Add the upstream public key**

Obtain the thread-pool maintainer public key via a channel independent of `gitlab.com` (e.g. keyserver lookup cross-checked with the maintainer's personal site or a signed announcement). Save the ASCII-armored key to `/home/benji/src/devnw/zig/toml/trusted_keys/thread-pool-maintainers.asc`.

Verify the fingerprint and record it in the MR description:

```bash
gpg --show-keys /home/benji/src/devnw/zig/toml/trusted_keys/thread-pool-maintainers.asc
```

Expected: a `pub` line showing the fingerprint. Cross-check against the out-of-band source before committing.

- [ ] **Step 3: Test the script locally — positive case**

Run: `/home/benji/src/devnw/zig/toml/scripts/verify-thread-pool-tag.sh`
Expected final stdout line: `OK: thread_pool <tag> verified against trusted_keys/`
Expected exit code: `0`.

Note: the pin in `build.zig.zon` must already be migrated to `#refs/tags/<tag>` (see Step 6) before this test passes. Run Step 6 first if verification fails with exit `2`.

- [ ] **Step 4: Test the script locally — negative case (missing key)**

Run:

```bash
mv /home/benji/src/devnw/zig/toml/trusted_keys/thread-pool-maintainers.asc /tmp/key.bak
/home/benji/src/devnw/zig/toml/scripts/verify-thread-pool-tag.sh
echo "exit=$?"
mv /tmp/key.bak /home/benji/src/devnw/zig/toml/trusted_keys/thread-pool-maintainers.asc
```

Expected: `exit=1` and stderr contains `ERROR: no trusted keys`.

- [ ] **Step 5: Add the `verify-supply-chain` CI job**

Edit `/home/benji/src/devnw/zig/toml/.gitlab-ci.yml`. Append at the end of the file (or co-located with other lint-stage jobs per project convention):

```yaml
verify-supply-chain:
  stage: lint
  image: debian:stable-slim
  tags:
    - company
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == "main"
  before_script:
    - apt-get update && apt-get install -y --no-install-recommends git gnupg ca-certificates
  script:
    - ./scripts/verify-thread-pool-tag.sh
  artifacts:
    when: always
    paths:
      - /tmp/verify.log
    expire_in: 1 week
```

- [ ] **Step 6: Migrate `build.zig.zon` from commit SHA to signed-tag URL**

Edit `/home/benji/src/devnw/zig/toml/build.zig.zon`. Replace the exact line:

```zig
            .url = "git+https://gitlab.com/devnw/zig/thread-pool.git#ee8440f69012cad49fa1d5f22fe18c68f944d9ab",
```

with the signed-tag form (substitute the actual tag published by upstream; the example uses `v0.2.0`):

```zig
            .url = "git+https://gitlab.com/devnw/zig/thread-pool.git#refs/tags/v0.2.0",
```

Regenerate the Zig package hash:

Run:

```bash
cd /home/benji/src/devnw/zig/toml
zig build --fetch
```

Expected: Zig reports the new `.hash` value. Update the `.hash` field in `build.zig.zon` with the emitted value (copy verbatim).

Verify: `zig build` completes without `error.PackageHashMismatch`.

- [ ] **Step 7: Run the verification script end-to-end**

Run: `/home/benji/src/devnw/zig/toml/scripts/verify-thread-pool-tag.sh`
Expected: exit `0` and final line `OK: thread_pool refs/tags/v0.2.0 verified against trusted_keys/` (tag name will differ if upstream used a different name).

- [ ] **Step 8: Dry-run the CI job**

Push to a scratch branch and open a draft MR. Expected: the `verify-supply-chain` job runs in the `lint` stage and passes green. If it fails, investigate — do NOT disable or skip the job.

- [ ] **Step 9: Commit**

```bash
cd /home/benji/src/devnw/zig/toml
git add scripts/verify-thread-pool-tag.sh \
        trusted_keys/thread-pool-maintainers.asc \
        .gitlab-ci.yml \
        build.zig.zon
git commit -m "ci: close S-10 — verify thread_pool signed tags"
```

---

## Task 5: Add CI fast-fail for lightweight-tag regression

**Workstream:** A — **BLOCKED (same prereqs as Task 4).**

Future regressions could revert `build.zig.zon` to a commit SHA (unsigned). This task adds a cheap lint job that fails fast if the pin does not reference `refs/tags/`.

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/.gitlab-ci.yml` — add `lint-zon-pin-format` job.

- [ ] **Step 1: Confirm the script's parse-error branch works**

Run:

```bash
cp /home/benji/src/devnw/zig/toml/build.zig.zon /tmp/zon.bak
sed -i 's|#refs/tags/[^"]*|#deadbeefdeadbeefdeadbeefdeadbeefdeadbeef|' /home/benji/src/devnw/zig/toml/build.zig.zon
/home/benji/src/devnw/zig/toml/scripts/verify-thread-pool-tag.sh
echo "exit=$?"
cp /tmp/zon.bak /home/benji/src/devnw/zig/toml/build.zig.zon
```

Expected: `exit=2` and stderr contains `ERROR: no refs/tags/ reference found`. If exit is not `2`, the script's extractor is broken — fix before continuing.

- [ ] **Step 2: Add the fast-fail CI job**

Edit `/home/benji/src/devnw/zig/toml/.gitlab-ci.yml`. Append:

```yaml
lint-zon-pin-format:
  stage: lint
  image: debian:stable-slim
  tags:
    - company
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == "main"
  script:
    - |
      if ! grep -E 'thread_pool' -A2 build.zig.zon | grep -qE '#refs/tags/[A-Za-z0-9._/-]+'; then
        echo "ERROR: build.zig.zon thread_pool pin must use #refs/tags/<tag>, not a commit SHA." >&2
        echo "       See SECURITY.md 'Dependency Update Policy' and S-10." >&2
        exit 1
      fi
      echo "OK: thread_pool pin references a tag."
```

- [ ] **Step 3: Lint locally**

Run: `grep -E 'thread_pool' -A2 /home/benji/src/devnw/zig/toml/build.zig.zon | grep -qE '#refs/tags/[A-Za-z0-9._/-]+' && echo OK || echo FAIL`
Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
cd /home/benji/src/devnw/zig/toml
git add .gitlab-ci.yml
git commit -m "ci(security): fast-fail when build.zig.zon pin is not a tag (S-10)"
```

---

## Task 6: Update CHANGELOG, ARCHITECTURE, and SECURITY_GAP_ANALYSIS

**Workstream:** Split. Step 1 ships after Task 3 (unblocked). Steps 2–5 ship after Task 5 (blocked).

**Files:**

- Modify: `/home/benji/src/devnw/zig/toml/CHANGELOG.md`
- Modify: `/home/benji/src/devnw/zig/toml/docs/SECURITY_GAP_ANALYSIS.md`
- Modify: `/home/benji/src/devnw/zig/toml/docs/ARCHITECTURE.md`

- [ ] **Step 1 (unblocked, after Task 3): Add CHANGELOG entry for the policy**

Edit `/home/benji/src/devnw/zig/toml/CHANGELOG.md`. Under `## [Unreleased]` (create this section below the file header if absent), add:

```markdown
### Security
- Supply-chain: `build.zig.zon` changes now require two approvers
  (`@security-team` + `@maintainers`). Scaffolded `trusted_keys/`
  directory for future signed-tag verification. Partial mitigation for
  S-10 (CWE-1357 / CWE-829) — CI verification pending upstream signed
  tags.
```

Commit:

```bash
cd /home/benji/src/devnw/zig/toml
git add CHANGELOG.md
git commit -m "docs(changelog): record two-reviewer policy (S-10 partial)"
```

- [ ] **Step 2 (BLOCKED, after Task 5): Extend CHANGELOG for CI verification**

Edit `/home/benji/src/devnw/zig/toml/CHANGELOG.md`. Under `## [Unreleased]` → `### Security`, append:

```markdown
- Supply-chain: CI now verifies `thread_pool` signed tags against
  `trusted_keys/*.asc` before build/test/release. `build.zig.zon` pin
  migrated from commit SHA to `refs/tags/<tag>`. Closes S-10
  (CWE-1357 / CWE-829).
```

- [ ] **Step 3 (BLOCKED, after Task 5): Mark S-10 closed in SECURITY_GAP_ANALYSIS.md**

Edit `/home/benji/src/devnw/zig/toml/docs/SECURITY_GAP_ANALYSIS.md`. Locate the S-10 entry. Change its status from `OPEN` (or current value) to `CLOSED`, and append a resolution note in the format already used by other closed entries in that file. If the file has no existing closed-entry template, use:

```markdown
**Resolution (YYYY-MM-DD):** Two-reviewer policy enforced via CODEOWNERS
+ GitLab MR approval rules. CI job `verify-supply-chain` verifies the
`thread_pool` signed tag against `trusted_keys/thread-pool-maintainers.asc`
on every MR and main-branch pipeline. Script:
`scripts/verify-thread-pool-tag.sh`. See SECURITY.md "Dependency Update
Policy".
```

Substitute the actual closure date in `YYYY-MM-DD` form.

- [ ] **Step 4 (BLOCKED, after Task 5): Add "Supply-Chain Integrity" to ARCHITECTURE.md**

Edit `/home/benji/src/devnw/zig/toml/docs/ARCHITECTURE.md`. Append a new top-level section:

```markdown
## Supply-Chain Integrity

### Dependency pinning

`build.zig.zon` pins `thread_pool` by **signed tag** (`#refs/tags/<tag>`),
not by raw commit SHA. Zig's package manager records a content hash; our
CI additionally verifies the upstream GPG signature.

### CI verification

The `verify-supply-chain` job (stage: `lint`) runs
`scripts/verify-thread-pool-tag.sh` on every MR and main-branch pipeline.
The script:

1. Extracts the tag name from `build.zig.zon`.
2. Imports every `trusted_keys/*.asc` into an ephemeral GPG home.
3. Clones the upstream repo at the pinned tag.
4. Runs `git tag -v <tag>` and fails if the signature is missing,
   unknown, or bad.

A second job, `lint-zon-pin-format`, fast-fails if the pin ever reverts
to a raw commit SHA.

### Human review gate

`CODEOWNERS` routes any MR touching `build.zig.zon` or `trusted_keys/` to
`@security-team`. GitLab MR approval rules require two distinct
approvers before merge. See `SECURITY.md` → "Dependency Update Policy".

### Threat model

- **Attacker goal:** inject malicious code into this project's build.
- **Mitigation layer 1 (hash pinning):** Zig package hash prevents
  unauthorized modification of the pinned revision.
- **Mitigation layer 2 (signed tags):** a maintainer-account compromise
  on gitlab.com cannot mint a new tag that CI accepts without also
  compromising a GPG key listed in `trusted_keys/`.
- **Mitigation layer 3 (two-reviewer policy):** a compromised maintainer
  still cannot unilaterally merge a dependency bump without a second
  reviewer.
```

- [ ] **Step 5 (BLOCKED, after Task 5): Commit the closure**

```bash
cd /home/benji/src/devnw/zig/toml
git add CHANGELOG.md docs/SECURITY_GAP_ANALYSIS.md docs/ARCHITECTURE.md
git commit -m "docs: close S-10 — supply-chain signed tags + policy"
```

---

## Task 7: Self-verification checklist

**Workstream:** Both. Run Steps 1–3 after Task 3 for workstream B closure; run Steps 4–7 after Task 6 for full S-10 closure.

- [ ] **Step 1: CODEOWNERS routes `build.zig.zon` to @security-team**

Run: `grep -E '^build\.zig\.zon' /home/benji/src/devnw/zig/toml/CODEOWNERS`
Expected: line contains both `@security-team` and `@maintainers`.

- [ ] **Step 2: SECURITY.md documents the policy**

Run: `grep -c 'Two-reviewer rule\|Signed-tag verification' /home/benji/src/devnw/zig/toml/SECURITY.md`
Expected: `>= 2`.

- [ ] **Step 3: `trusted_keys/` is security-team gated**

Run: `grep -E '^/trusted_keys/' /home/benji/src/devnw/zig/toml/CODEOWNERS`
Expected: line contains `@security-team`.

- [ ] **Step 4 (BLOCKED, after Task 4): CI job runs on MRs**

Inspect a recent MR pipeline on gitlab.com. Expected: `verify-supply-chain` and `lint-zon-pin-format` jobs both present, both green. If either is missing or red, S-10 is NOT closed.

- [ ] **Step 5 (BLOCKED, after Task 4): build.zig.zon uses a tag**

Run: `grep -E '#refs/tags/' /home/benji/src/devnw/zig/toml/build.zig.zon`
Expected: one match referencing the thread-pool URL.

- [ ] **Step 6 (BLOCKED, after Prereq 3): GitLab approval rule exists**

Run (requires `glab` CLI authenticated to the project):

```bash
glab api "projects/:id/approval_rules" | jq '.[] | select(.name | test("supply-chain"))'
```

Expected: an approval rule with `approvals_required >= 2` and a `protected_branches` entry for `main`.

- [ ] **Step 7 (BLOCKED, after Task 5): Negative test — bad dependency bump**

Open a scratch MR that:

1. Replaces `build.zig.zon`'s thread_pool URL with a commit SHA.
2. Removes `trusted_keys/thread-pool-maintainers.asc`.

Expected outcomes (ALL must hold):

- `lint-zon-pin-format` fails with exit `1`.
- `verify-supply-chain` fails with exit `1` or `2`.
- GitLab blocks merge because `@security-team` has not approved.

Close the scratch MR without merging.

---

## Self-Review

Checklist run against the spec:

**1. Spec coverage:**

- "S-10 — supply-chain dependency pin lacks two-reviewer / signed-tag policy" → Tasks 1–3 establish the policy; Tasks 4–5 enforce signed tags in CI; Task 6 closes the finding in docs; Task 7 verifies.
- "Unblock Prerequisites section up front" → present with three items, each with concrete verification commands.
- "Document the policy and the local verification steps so the plan can be executed once upstream cooperates" → Task 4 Steps 3, 4, 7 give local verification; Task 5 Step 1 covers the regression test; Task 7 gives the closure checklist.
- "Workstream A (CI verification)" → Tasks 4 and 5 cover script, CI jobs, and `.zon` migration.
- "Workstream B (approval policy)" → Tasks 1, 2, 3 cover CODEOWNERS, SECURITY.md, trusted_keys scaffold.
- "Task 3 (B): Commit: `chore(security): policy for build.zig.zon approvals`" → Plan uses one commit per file change (Tasks 1, 2, 3 each commit with a specific scope). A single umbrella commit would be harder to revert. If the maintainer prefers a single commit, squash on merge.
- "Task 5 (A): Commit: `ci: close S-10 — verify thread_pool signed tags`" → Task 4 Step 9 uses this exact commit message.
- "CHANGELOG + docs/ARCHITECTURE.md" → Task 6 Steps 1–4.

**2. Placeholder scan:** No instances of "TBD", "implement later", "fill in details", or "handle edge cases". All shell scripts, YAML, and Markdown blocks are concrete. The tag name `v0.2.0` is a stated example; Task 4 Step 6 explicitly instructs substituting the actual tag and regenerating the hash.

**3. Type / name consistency:**

- Script name: `scripts/verify-thread-pool-tag.sh` — identical in Tasks 4, 5, 6, 7.
- Key file: `trusted_keys/thread-pool-maintainers.asc` — identical in Tasks 3, 4, 7.
- CI job names: `verify-supply-chain` and `lint-zon-pin-format` — identical across Tasks 4, 5, 7.
- `CODEOWNERS` line for `build.zig.zon`: `build.zig.zon       @security-team @maintainers` — identical in Tasks 1, 3, 7.
- Stage: `lint` — identical in Tasks 4, 5.
- Exit codes: `0` success, `1` verification failure, `2` parse failure — identical in Task 4 Step 1 script header, Task 4 Step 4 assertion, and Task 5 Step 1 assertion.

No inconsistencies found.
