# ARC Runner SHA Validation — Platform Repo

This is the **platform repo**. It provides:

1. A custom ARC runner OCI image with a pre-job validation hook baked in
2. A reusable `approve-workflow-sha.yml` workflow that consumer repos call
3. This repo's own `approved-shas.txt` / `approved-file-shas.txt` (for workflows running here)

Every job on any runner built from this image is blocked unless the workflow's
blob SHA — and all tracked file blob SHAs — are present in the repo's approved
lists, fetched live from `main` via the GitHub API. No ConfigMap, no kubectl,
no cluster state involved in validation.

---

## How it works

```
Developer opens PR on consumer repo
  touching .github/workflows/ or scripts/ or .github/actions/
  |
  +-- require-workflow-review.yml: status check blocks merge
  +-- CODEOWNERS: routes review to platform team
  |
Platform team reviews and approves
  |
PR merges to main
  |
  +-- approve-workflow-sha.yml triggers (push to main, paths match)
      runs on: ubuntu-latest (standard GitHub-hosted runner)
      |
      +-- git hash-object each workflow file  -->  approved-shas.txt
      +-- git hash-object each tracked file   -->  approved-file-shas.txt
      +-- git commit + push both files to main
  |
Next job runs on ARC runner
  |
  ACTIONS_RUNNER_HOOK_JOB_STARTED fires validate-workflow.sh
  |
  +-- fetch OIDC token, verify signature against GitHub JWKS
  +-- extract workflow_sha claim
  +-- GET /repos/{repo}/contents/approved-shas.txt?ref=main
  +-- check workflow_sha in list  -->  fail: job blocked
  +-- GET /repos/{repo}/contents/approved-file-shas.txt?ref=main
  +-- GET /repos/{repo}/git/trees/{commit}?recursive=1
  +-- check each tracked file blob SHA  -->  fail: job blocked
  +-- exit 0: job proceeds
```

---

## Trust chain

```
TRUST ROOTS
  |
  +-- GitHub OIDC service         cryptographic; JWT signed by GitHub,
  |                               verified against public JWKS endpoint
  |
  +-- Platform repo access        admin-only write access; branch protection
                                  with admin enforcement; no developer access

PLATFORM REPO  (this repo)
  |
  +-- runner-image/
  |     Dockerfile + validate-workflow.sh  -->  OCI image  -->  GHCR
  |                                              pinned by digest in helm values
  +-- .github/workflows/
        approve-workflow-sha.yml   reusable; called by consumer repos at pinned SHA
        build-images.yml           GitHub-hosted runners; no SHA gate needed here

CONSUMER REPO
  |
  +-- CODEOWNERS                  protects workflows/, scripts/, tracked-paths.txt,
  |                               approved-shas.txt, approved-file-shas.txt
  +-- tracked-paths.txt           declares security-sensitive paths
  +-- approved-shas.txt           written only by approve-workflow-sha.yml
  +-- approved-file-shas.txt      written only by approve-workflow-sha.yml
  +-- .github/workflows/
        approve.yml               calls platform-repo/approve-workflow-sha.yml@<sha>

AKS CLUSTER  (arc-runners namespace)
  |
  +-- arc-runner-sa  ServiceAccount + Role  (pod management only; no ConfigMap RBAC)
  +-- Runner Pods    image: arc-runner@sha256:<digest>
                     /etc/arc/hooks/validate-workflow.sh

EVERY JOB
  |
  validate-workflow.sh
  |
  +-- OIDC token  -->  GitHub JWKS verify  -->  extract workflow_sha
  +-- GitHub API: approved-shas.txt@main   -->  check workflow_sha
  +-- GitHub API: approved-file-shas.txt@main + git tree  -->  check tracked files
  +-- pass / fail
```

---

## Infrastructure components

| Component | Kind | Purpose |
|---|---|---|
| `arc-runner` OCI image | GHCR package | Bakes in `validate-workflow.sh`; pinned by digest in helm values |
| `arc-runner-sa` | ServiceAccount | Runner pod identity; RBAC for pod management only |
| `arc-runner-role` | Role (namespaced) | Permits pod/secret/PVC management; no ConfigMap access needed |
| Runner pods | ARC scale set | Execute jobs; hook fires before every job |
| ARC controller | Helm release (`arc-systems`) | Manages runner scale sets |
| ARC runner scale set | Helm release (`arc-runners`) | Registers runners, scales pods |
| `arc-github-secret` | Secret | Runner registration token |
| `ghcr-pull-secret` | Secret | Pulls `arc-runner` image from GHCR |
| `approved-shas.txt` | File in repo | Approved workflow blob SHAs; committed by approval workflow |
| `approved-file-shas.txt` | File in repo | Approved tracked file blob SHAs; committed by approval workflow |
| `tracked-paths.txt` | File in repo | Declares which non-workflow paths are SHA-tracked |
| Branch protection rule | GitHub setting | Requires `Verify CODEOWNER approval` status + CODEOWNERS review |
| CODEOWNERS | File in repo | Enforces platform team review; includes itself |

---

## Full flow: authorized workflow addition

```
1.  Developer opens PR touching .github/workflows/deploy.yml
    (or scripts/deploy.sh, .github/actions/*, tracked-paths.txt, CODEOWNERS)

2.  require-workflow-review.yml fires on pull_request
    Status check "Verify CODEOWNER approval" = pending

3.  CODEOWNERS routes review request to @platform-team

4.  Platform team reviews the diff

5.  Platform team approves the PR

6.  Status check passes; branch protection allows merge

7.  Developer merges PR to main

8.  approve-workflow-sha.yml triggers (push, paths match)
    runs on ubuntu-latest

    a. checkout at HEAD
    b. git hash-object each .github/workflows/*.yml  ->  approved-shas.txt
    c. read tracked-paths.txt; git hash-object each file  ->  approved-file-shas.txt
    d. git commit "ci: update approved SHAs for <sha>"
    e. git push (github-actions[bot] bypasses branch protection)

9.  approved-shas.txt and approved-file-shas.txt are live on main

10. Next job on an ARC runner (new or existing):
    ACTIONS_RUNNER_HOOK_JOB_STARTED fires validate-workflow.sh

    a. fetch OIDC token (audience: arc-sha-gate)
    b. verify JWT signature against GitHub JWKS (no secrets needed)
    c. extract: workflow_sha, sha (commit), repository, run_id
    d. GET /repos/{repo}/contents/approved-shas.txt?ref=main
    e. grep workflow_sha  ->  found: continue  /  not found: exit 1
    f. GET /repos/{repo}/contents/approved-file-shas.txt?ref=main
    g. GET /repos/{repo}/git/trees/{sha}?recursive=1
    h. for each line in approved-file-shas.txt:
         look up path in tree, compare blob SHA
         mismatch -> exit 1
    i. exit 0 -> job steps execute
```

---

## Consumer repo setup

Consumer repos call the approval workflow as a reusable workflow at a pinned SHA.
They do not import this entire repo — only the reusable workflow reference.

### .github/workflows/approve.yml (in consumer repo)

```yaml
name: Approve Workflow SHAs

on:
  push:
    branches: [main]
    paths:
      - ".github/workflows/**"
      - "tracked-paths.txt"
      - "CODEOWNERS"
      - "scripts/**"
      - ".github/actions/**"

permissions:
  contents: write
  id-token: write

jobs:
  approve:
    uses: your-org/platform-repo/.github/workflows/approve-workflow-sha.yml@<full-sha>
    secrets: inherit
```

Replace `<full-sha>` with the commit SHA of the platform repo revision you want.
Updating this SHA is itself a tracked change requiring platform team review.

### tracked-paths.txt (in consumer repo)

```
# Paths tracked beyond workflow files
CODEOWNERS
tracked-paths.txt
approved-shas.txt
approved-file-shas.txt
scripts/
.github/actions/
```

### CODEOWNERS (in consumer repo)

```
CODEOWNERS               @your-org/platform-team
tracked-paths.txt        @your-org/platform-team
approved-shas.txt        @your-org/platform-team
approved-file-shas.txt   @your-org/platform-team
.github/workflows/       @your-org/platform-team
scripts/                 @your-org/platform-team
.github/actions/         @your-org/platform-team
```

### Branch protection (in consumer repo)

- Required status check: `Verify CODEOWNER approval`
- Require review from Code Owners: enabled
- Allow `github-actions[bot]` to bypass required pull request reviews
  (so the approval workflow can push `approved-shas.txt` directly to main)

---

## Platform repo setup

### 1. Namespaces

```bash
kubectl create namespace arc-systems
kubectl create namespace arc-runners
```

### 2. RBAC

```bash
kubectl apply -f k8s/arc-rbac.yaml
```

### 3. Secrets

```bash
kubectl create secret generic arc-github-secret \
  --namespace arc-runners \
  --from-literal=github_token=ghp_YOUR_TOKEN

kubectl create secret docker-registry ghcr-pull-secret \
  --namespace arc-runners \
  --docker-server=ghcr.io \
  --docker-username=YOUR_GITHUB_USERNAME \
  --docker-password=ghp_YOUR_PAT
```

### 4. Install ARC controller

```bash
helm install arc \
  --namespace arc-systems \
  --create-namespace \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller
```

### 5. Build the runner image

```bash
gh workflow run build-images.yml --ref main
```

Copy the image digest from the job summary. Update `k8s/arc-runner-values.yaml`:

```yaml
image: ghcr.io/YOUR_ORG/arc-runner@sha256:<digest>
```

### 6. Install runner scale set

```bash
helm install arc-runner-set \
  --namespace arc-runners \
  --create-namespace \
  --values k8s/arc-runner-values.yaml \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
```

### 7. Bootstrap approved SHA lists

Trigger the approval workflow once manually to write the initial SHA lists:

```bash
gh workflow run approve-workflow-sha.yml --ref main \
  --field reason="bootstrap"
```

---

## File structure

```
.
|-- CODEOWNERS                    self-referential; requires platform-team review
|-- tracked-paths.txt             security-sensitive paths beyond workflows
|-- approved-shas.txt             workflow blob SHAs; committed by approval workflow
|-- approved-file-shas.txt        tracked file blob SHAs; committed by approval workflow
|-- .github/
|   `-- workflows/
|       |-- approve-workflow-sha.yml   reusable; commits SHA lists on merge
|       |-- build-images.yml           builds runner OCI image
|       `-- require-workflow-review.yml  PR gate
|-- runner-image/
|   |-- Dockerfile                extends ghcr.io/actions/actions-runner
|   |-- entrypoint.sh             delegates to runner start script
|   `-- hooks/
|       `-- validate-workflow.sh  OIDC verification + GitHub API SHA checks
`-- k8s/
    |-- arc-rbac.yaml             ServiceAccount + Role (pod management only)
    `-- arc-runner-values.yaml    Helm values; image pinned by digest
```

---

## Design notes

**No cluster state for SHA validation.** `approved-shas.txt` and
`approved-file-shas.txt` live in the repo. The hook fetches them from the GitHub
API at job start. Adding a SHA is a `git push` — no kubectl, no ConfigMap, no
pod restarts needed.

**Blob SHA is content-addressed.** `git hash-object` produces the same SHA for
identical content regardless of filename. Identical files share one approved SHA
entry. Changing any byte changes the SHA and triggers a block.

**No retrier.** Blocked jobs must be re-run manually (GitHub UI or `gh run rerun`)
after the approval workflow commits new SHAs. This is intentional: it keeps the
system simple and explicit.

**GitHub API rate limits.** The hook makes up to 3 GitHub API calls per job
(approved-shas, approved-file-shas, git tree). At default runner concurrency
this is well within GitHub's 5,000 requests/hour authenticated limit. Monitor
if you scale to very high job concurrency.

**Safe failure modes.** If the GitHub API is unreachable, `curl -sf` fails and
the hook exits 1 — jobs are blocked, not allowed through. If `approved-shas.txt`
is missing from main (e.g. before bootstrap), jobs are blocked.

**Image digest pinning.** The runner image is referenced by `@sha256:<digest>`
in `arc-runner-values.yaml`. Tag mutations cannot silently swap the image.
Updating the image requires a PR to this platform repo, which requires platform
team review.
