#!/usr/bin/env bash
# Runs once, inside the started (and therefore egress-restricted) container.
set -euo pipefail

PROXY="${HTTPS_PROXY:-}"
if [ -z "${PROXY}" ]; then
    echo "(!) HTTPS_PROXY is unset — the egress proxy should have been set in docker-compose.yml." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Unlike the Docker CLI/BuildKit, rootless Podman does not need a config.json
# trick to get the proxy into RUN steps: containers.conf's [engine] section
# defaults http_proxy to true, which passes HTTP_PROXY/HTTPS_PROXY/NO_PROXY
# (already set on this container's environment by docker-compose.yml) through
# to both `podman run` and `podman build` automatically.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# The tool this repository is developed with. Pulled through the proxy, so
# registry.npmjs.org has to be on the allowlist.
# ---------------------------------------------------------------------------
npm install -g @devcontainers/cli

# The workspace is a bind mount from Windows and does not come out owned by
# `vscode`, which git refuses to operate on ("detected dubious ownership").
git config --global --add safe.directory "${PWD}"

echo
echo "Ready. Check the firewall with:"
echo "  bash .devcontainer/egress/verify-egress.sh"
echo
echo "Feature tests run in here, against a proxied build:"
echo "  devcontainer features test --skip-scenarios -f claude-code -i mcr.microsoft.com/devcontainers/base:ubuntu ."
