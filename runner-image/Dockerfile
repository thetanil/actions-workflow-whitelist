# ─────────────────────────────────────────────────────────────────────────────
# Custom ARC Runner Image
# Base: ghcr.io/actions/actions-runner (official GitHub image)
#
# This image ONLY adds:
#   - step CLI for OIDC JWT verification
#   - validate-workflow.sh hook
#   - entrypoint wrapper
#
# The runner binary, k8s container hooks, and externals are all
# inherited from the official base image unchanged.
# ─────────────────────────────────────────────────────────────────────────────
FROM ghcr.io/actions/actions-runner:latest

ARG TARGETARCH=amd64

USER root

# ── step CLI for OIDC JWT verification ────────────────────────────────────────
# Used in validate-workflow.sh to verify GitHub's JWKS signature.
# No Azure, no Key Vault — GitHub's public JWKS endpoint is the only dependency.
RUN STEP_VERSION=0.26.1 && \
    curl -fsSL "https://github.com/smallstep/cli/releases/download/v${STEP_VERSION}/step_linux_${STEP_VERSION}_${TARGETARCH}.tar.gz" \
    | tar -xz --strip-components=1 -C /usr/local/bin "step_${STEP_VERSION}/bin/step" && \
    step version

# ── Hook and entrypoint ───────────────────────────────────────────────────────
RUN mkdir -p /etc/arc/hooks

COPY hooks/validate-workflow.sh /etc/arc/hooks/validate-workflow.sh
COPY entrypoint.sh               /home/runner/entrypoint.sh

RUN chmod +x /etc/arc/hooks/validate-workflow.sh \
             /home/runner/entrypoint.sh \
    && chown -R runner:runner /etc/arc /home/runner/entrypoint.sh

USER runner

# Point runner at the pre-job validation hook.
# ACTIONS_RUNNER_CONTAINER_HOOKS is already set in the official base image
# to /home/runner/k8s/index.js — we don't override it.
ENV ACTIONS_RUNNER_HOOK_JOB_STARTED=/etc/arc/hooks/validate-workflow.sh

ENTRYPOINT ["/home/runner/entrypoint.sh"]
