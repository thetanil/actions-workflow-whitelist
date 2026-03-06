# Testing and Validation Plan

---

## 1. Static checks (no cluster required)

Run these in CI on every push. They catch structural problems before deployment.

### 1.1 CODEOWNERS completeness

```bash
for path in CODEOWNERS tracked-paths.txt approved-shas.txt approved-file-shas.txt \
            ".github/workflows/" runner-image/ k8s/; do
  if ! grep -q "^${path}" CODEOWNERS; then
    echo "FAIL: CODEOWNERS missing: ${path}"; exit 1
  fi
done
echo "PASS"
```

### 1.2 tracked-paths.txt is self-referential

```bash
for entry in CODEOWNERS tracked-paths.txt; do
  if ! grep -q "^${entry}" tracked-paths.txt; then
    echo "FAIL: tracked-paths.txt missing self-reference: ${entry}"; exit 1
  fi
done
echo "PASS"
```

### 1.3 Image pinned by digest in Helm values

```bash
if grep -E "image:.*:(latest|v[0-9])" k8s/arc-runner-values.yaml; then
  echo "FAIL: image referenced by tag, not digest"; exit 1
fi
echo "PASS"
```

### 1.4 Consumer approve.yml references reusable workflow at full SHA (not branch/tag)

```bash
if grep -E "uses:.*approve-workflow-sha\.yml@(main|master|v[0-9])" \
     .github/workflows/approve.yml 2>/dev/null; then
  echo "FAIL: reusable workflow pinned by branch/tag, not full SHA"; exit 1
fi
echo "PASS"
```

### 1.5 No remote actions pinned by tag

```bash
BAD=$(grep -rE "uses:\s+[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+@(v[0-9]|main|master|latest)" \
        .github/workflows/ 2>/dev/null || true)
[[ -n "$BAD" ]] && echo "WARN: non-digest action pins found:" && echo "$BAD"
```

---

## 2. Unit tests: validate-workflow.sh

Each test creates a minimal environment and asserts the exit code.
Extract into `test-validate-workflow.sh` and run on every change to `runner-image/`.

### Test harness

```bash
#!/usr/bin/env bash
set -euo pipefail
PASS=0; FAIL=0
SCRIPT="runner-image/hooks/validate-workflow.sh"

run_test() {
  local name="$1" expected="$2" setup_fn="$3"
  local tmpdir; tmpdir=$(mktemp -d)
  $setup_fn "$tmpdir"
  actual=0
  bash "$SCRIPT" >"$tmpdir/out.txt" 2>&1 || actual=$?
  rm -rf "$tmpdir"
  if [[ "$actual" -eq "$expected" ]]; then
    echo "PASS: $name"; ((PASS++))
  else
    echo "FAIL: $name (expected $expected, got $actual)"; ((FAIL++))
  fi
}
```

### T-01: Missing OIDC token blocks job

```bash
setup() {
  unset ACTIONS_ID_TOKEN_REQUEST_TOKEN
  unset ACTIONS_ID_TOKEN_REQUEST_URL
}
run_test "T-01 missing OIDC exits 1" 1 setup
```

### T-02: OIDC endpoint unreachable blocks job

```bash
setup() {
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="token"
  export ACTIONS_ID_TOKEN_REQUEST_URL="http://127.0.0.1:19999/token"  # nothing listening
}
run_test "T-02 OIDC unreachable exits 1" 1 setup
```

### T-03: Forged token (wrong key) is rejected

Generate a token signed with a key not in GitHub's JWKS. The `step crypto jwt verify`
call in the hook must fail.

```bash
# One-time: generate test key pair and commit public key as fixture
# step crypto jwk create test-fixtures/pub.json test-fixtures/priv.json --kty EC --crv P-256

setup() {
  # Sign a JWT with the attacker key (not in GitHub JWKS)
  FAKE_TOKEN=$(step crypto jwt sign \
    --key test-fixtures/priv.json \
    --aud arc-sha-gate \
    --payload '{"workflow_sha":"abc","repository":"org/repo","sha":"def"}')
  # Serve it from a mock OIDC endpoint
  export ACTIONS_ID_TOKEN_REQUEST_TOKEN="x"
  export ACTIONS_ID_TOKEN_REQUEST_URL="http://localhost:18080/token"  # returns FAKE_TOKEN
}
run_test "T-03 forged token exits 1" 1 setup
```

### T-04: approved-shas.txt unreachable blocks job (GitHub API down)

```bash
setup() {
  # Mock OIDC returns valid token but GitHub API returns 404
  export GITHUB_TOKEN="test"
  export GITHUB_REPOSITORY="org/repo"
  # Point hook at a mock that returns 404 for /contents/approved-shas.txt
}
run_test "T-04 approved-shas.txt unreachable exits 1" 1 setup
```

### T-05: Unapproved workflow SHA blocks job

```bash
setup() {
  # approved-shas.txt contains 000... ; OIDC token has the real workflow SHA
}
run_test "T-05 unapproved SHA exits 1" 1 setup
```

### T-06: Approved workflow SHA, no tracked files — job proceeds

```bash
setup() {
  # approved-shas.txt contains the real workflow SHA
  # approved-file-shas.txt is empty / absent
}
run_test "T-06 approved SHA, no files exits 0" 0 setup
```

### T-07: Tracked file SHA mismatch blocks job

```bash
setup() {
  # approved-shas.txt has real workflow SHA
  # approved-file-shas.txt has 000... for scripts/deploy.sh
  # git tree returns real SHA for scripts/deploy.sh
}
run_test "T-07 stale tracked file exits 1" 1 setup
```

### T-08: All SHAs match — job proceeds

```bash
setup() {
  # approved-shas.txt has real workflow SHA
  # approved-file-shas.txt has real SHAs for all tracked files
}
run_test "T-08 all match exits 0" 0 setup
```

---

## 3. Integration tests: end-to-end on cluster

Requires a running AKS cluster with ARC installed and the runner image deployed.
Use a dedicated test repo (not production) with the runner scale set pointed at it.

### IT-01: Happy path — PR merge unblocks a queued job

1. Push a workflow change to a branch; open PR against test repo.
2. Trigger a job run from the branch — observe it blocked (`SHA is NOT approved`).
3. Get PR approved by a CODEOWNER.
4. Merge PR to main.
5. Observe `approve-workflow-sha.yml` runs and commits `approved-shas.txt`.
6. Manually re-run the blocked job.
7. Assert: job passes the hook and completes.

### IT-02: approved-shas.txt missing from main blocks all jobs

1. Rename `approved-shas.txt` (simulate missing file) and push to a test branch.
2. Do not merge to main.
3. Trigger a job — it must be blocked because the hook cannot fetch the file.
4. Restore the file.

### IT-03: Tracked file change blocks job even with approved workflow SHA

1. Approve current state (merge a PR, let approval workflow run).
2. Change `scripts/deploy.sh` on a branch without going through approval.
3. Trigger a job from that branch.
4. Assert: hook exits 1 citing `SHA mismatch: scripts/deploy.sh`.

### IT-04: GitHub API rate limit behaviour

At high concurrency, verify the hook does not silently pass on API errors.
Simulate a 403/429 response by temporarily replacing `GITHUB_TOKEN` with an
invalid token and asserting exit 1 (not exit 0).

---

## 4. Adversarial tests

### AT-01: Modify approved-shas.txt directly via PR — blocked by CODEOWNERS

Open a PR that edits `approved-shas.txt` to add an arbitrary SHA.
Assert: CODEOWNERS routes the review to platform team; a non-platform-team
approval does not satisfy the branch protection check.

### AT-02: Modify CODEOWNERS to remove protection — blocked

Open a PR that removes `approved-shas.txt` from CODEOWNERS.
Assert: the PR itself requires platform team review (CODEOWNERS is self-referential)
and cannot merge without it.

### AT-03: Change tracked-paths.txt to remove scripts/ — blocked

Open a PR removing `scripts/` from `tracked-paths.txt`.
Assert: requires platform team review; merging alone does not help because the
approval workflow re-runs and captures the new `tracked-paths.txt` state — the
old script SHAs are no longer in `approved-file-shas.txt`, so any job using
those scripts with a mismatched SHA is still blocked until the script is re-reviewed.

### AT-04: Replay — reuse of an old approved SHA

The SHA in the OIDC token is a git blob SHA (content-addressed). If a workflow
file is reverted to a previously-approved version, the blob SHA matches and the
job is allowed. This is correct and intentional: the content is what was reviewed,
not the commit.

To verify: revert a workflow file to a prior version and confirm the job passes.

### AT-05: RBAC — no workload in cluster can push to the repo

The approval workflow uses the `GITHUB_TOKEN` of the calling workflow (pushed by
`github-actions[bot]`). Verify no Kubernetes service account has credentials
that could push to the repo:

```bash
# No runner pod should have a GitHub token mounted as a secret
kubectl get pods -n arc-runners -o yaml | grep -i "github_token" || echo "PASS: no token in pod spec"
```

---

## 5. Gap closure checklist

- [ ] Pin `arc-runner` image by digest in `k8s/arc-runner-values.yaml` (post first build)
- [ ] Run `approve-workflow-sha.yml` bootstrap after initial setup
- [ ] Add `github-actions[bot]` as branch protection bypass actor in each consumer repo
- [ ] Add static checks (section 1) as a required CI workflow
- [ ] Run unit tests (section 2) in CI on every push to `runner-image/`
- [ ] Build test fixture JWTs for T-03 and commit to `test-fixtures/`
- [ ] Wire up a mock GitHub API server for T-04 and T-05 unit tests
