#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ACTIONS_RUNNER_HOOK_JOB_STARTED — validate-workflow.sh
#
# Runs before every job step. Fails the job (exit 1) if:
#   - The workflow's blob SHA is not in approved-shas.txt
#   - Any tracked file's blob SHA is not in approved-file-shas.txt
#
# Both lists are fetched from the main branch of the repo running the workflow
# via the GitHub API. No ConfigMap, no kubectl, no cluster dependency.
#
# Required: id-token: write on the job (for OIDC)
#           GITHUB_TOKEN available in the hook environment (standard)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

AUDIENCE="arc-sha-gate"
GITHUB_JWKS_URL="https://token.actions.githubusercontent.com/.well-known/jwks"
GITHUB_API="https://api.github.com"

# ── Guard: OIDC must be available ─────────────────────────────────────────────
if [[ -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]] || \
   [[ -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ]]; then
  echo "[hook] OIDC not available (id-token: write not granted). Blocking job."
  exit 1
fi

# ── Fetch OIDC token ──────────────────────────────────────────────────────────
echo "[hook] Fetching OIDC token..."
TOKEN_JSON=$(curl -sf --max-time 10 \
  -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
  "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${AUDIENCE}") || {
  echo "[hook] Failed to contact OIDC endpoint."
  exit 1
}

OIDC_TOKEN=$(echo "$TOKEN_JSON" | jq -r '.value // empty')
[[ -z "$OIDC_TOKEN" ]] && { echo "[hook] OIDC token was empty."; exit 1; }

# ── Verify token signature ────────────────────────────────────────────────────
echo "[hook] Verifying token signature against GitHub JWKS..."
JWKS=$(curl -sf --max-time 10 "$GITHUB_JWKS_URL") || {
  echo "[hook] Failed to fetch GitHub JWKS."
  exit 1
}

PAYLOAD=$(echo "$OIDC_TOKEN" | \
  step crypto jwt verify \
    --jwks <(echo "$JWKS") \
    --aud  "$AUDIENCE" \
    --subtle 2>&1) || {
  echo "[hook] Token signature verification failed."
  exit 1
}

# ── Extract claims ────────────────────────────────────────────────────────────
WORKFLOW_SHA=$(echo "$PAYLOAD" | jq -r '.payload.workflow_sha    // empty')
WORKFLOW_REF=$(echo "$PAYLOAD" | jq -r '.payload.job_workflow_ref // empty')
REPOSITORY=$(echo  "$PAYLOAD" | jq -r '.payload.repository       // empty')
COMMIT_SHA=$(echo  "$PAYLOAD" | jq -r '.payload.sha              // empty')
RUN_ID=$(echo      "$PAYLOAD" | jq -r '.payload.run_id           // empty')

echo "[hook] Repository:   ${REPOSITORY}"
echo "[hook] Workflow ref: ${WORKFLOW_REF}"
echo "[hook] Commit:       ${COMMIT_SHA}"
echo "[hook] Run ID:       ${RUN_ID}"
echo "[hook] Workflow SHA: ${WORKFLOW_SHA}"

[[ -z "$WORKFLOW_SHA" ]] && { echo "[hook] workflow_sha claim missing from token."; exit 1; }
[[ -z "$COMMIT_SHA"   ]] && { echo "[hook] sha claim missing from token."; exit 1; }

# ── Fetch approved-shas.txt from the repo's main branch ──────────────────────
echo "[hook] Fetching approved-shas.txt from ${REPOSITORY}@main..."
APPROVED_SHAS=$(curl -sf --max-time 10 \
  -H "Authorization: bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github.raw+json" \
  "${GITHUB_API}/repos/${REPOSITORY}/contents/approved-shas.txt?ref=main") || {
  echo "[hook] Failed to fetch approved-shas.txt. Is the file present on main?"
  exit 1
}

# ── Check workflow SHA ────────────────────────────────────────────────────────
if echo "$APPROVED_SHAS" | grep -qE "^${WORKFLOW_SHA}([[:space:]]|$)"; then
  echo "[hook] Workflow SHA approved."
else
  echo "[hook] SHA ${WORKFLOW_SHA} is NOT approved."
  echo "[hook] Workflow: ${WORKFLOW_REF}"
  echo "[hook] Merge a PR touching this workflow to trigger the approval workflow."
  exit 1
fi

# ── Fetch and check approved-file-shas.txt (optional) ────────────────────────
APPROVED_FILE_SHAS=$(curl -sf --max-time 10 \
  -H "Authorization: bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github.raw+json" \
  "${GITHUB_API}/repos/${REPOSITORY}/contents/approved-file-shas.txt?ref=main" \
  2>/dev/null || true)

if [[ -z "$APPROVED_FILE_SHAS" ]] || ! echo "$APPROVED_FILE_SHAS" | grep -qE "^[0-9a-f]{40}"; then
  echo "[hook] No tracked file entries found. Skipping file SHA check."
  echo "[hook] All checks passed. Job proceeding."
  exit 0
fi

echo "[hook] Verifying tracked file SHAs at commit ${COMMIT_SHA}..."

# Fetch the full git tree for this commit
TREE_JSON=$(curl -sf --max-time 15 \
  -H "Authorization: bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "${GITHUB_API}/repos/${REPOSITORY}/git/trees/${COMMIT_SHA}?recursive=1") || {
  echo "[hook] Failed to fetch git tree from GitHub API."
  exit 1
}

BLOCKED=0

while IFS= read -r line; do
  [[ "$line" =~ ^#|^[[:space:]]*$ ]] && continue
  APPROVED_SHA=$(echo "$line" | awk '{print $1}')
  FILE_PATH=$(echo "$line"    | awk '{print $2}')

  CURRENT_SHA=$(echo "$TREE_JSON" | \
    jq -r --arg p "$FILE_PATH" \
      '.tree[] | select(.path == $p and .type == "blob") | .sha // empty')

  if [[ -z "$CURRENT_SHA" ]]; then
    echo "[hook] Tracked file missing from tree: ${FILE_PATH}"
    BLOCKED=1
    continue
  fi

  if [[ "$CURRENT_SHA" != "$APPROVED_SHA" ]]; then
    echo "[hook] SHA mismatch: ${FILE_PATH}"
    echo "[hook]   approved: ${APPROVED_SHA}"
    echo "[hook]   current:  ${CURRENT_SHA}"
    BLOCKED=1
  else
    echo "[hook] OK: ${FILE_PATH} (${CURRENT_SHA:0:12}...)"
  fi
done <<< "$APPROVED_FILE_SHAS"

if [[ "$BLOCKED" -eq 1 ]]; then
  echo "[hook] One or more tracked files have unapproved changes. Blocking job."
  exit 1
fi

echo "[hook] All checks passed. Job proceeding."
exit 0
