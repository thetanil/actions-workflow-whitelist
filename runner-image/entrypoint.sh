#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Runner entrypoint
#
# Delegates to the official runner start script. SHA validation happens at
# job start via ACTIONS_RUNNER_HOOK_JOB_STARTED (validate-workflow.sh).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

exec /home/runner/run.sh
