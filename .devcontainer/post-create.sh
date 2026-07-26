#!/usr/bin/env bash
# Runs once, inside the started (and therefore egress-restricted) container.
set -euo pipefail

PROXY="${HTTPS_PROXY:-}"
if [ -z "${PROXY}" ]; then
    echo "(!) HTTPS_PROXY is unset — the egress proxy should have been set in docker-compose.yml." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Teach the Docker CLI about the proxy.
#
# The inner daemon inherits HTTP_PROXY from this container's environment, so
# image *pulls* already go through Squid. Image *builds* do not: RUN steps get a
# clean environment, so `apt-get install bubblewrap` and the native installer's
# curl to claude.ai would hang inside a feature test build. The `proxies` block
# makes the Docker CLI pass the proxy to every build as an implicit build arg,
# which BuildKit exposes to RUN as environment variables.
# ---------------------------------------------------------------------------
mkdir -p "${HOME}/.docker"
CONFIG="${HOME}/.docker/config.json"
[ -s "${CONFIG}" ] || echo '{}' > "${CONFIG}"

tmp="$(mktemp)"
jq --arg proxy "${PROXY}" --arg noproxy "${NO_PROXY:-}" \
    '.proxies.default = {httpProxy: $proxy, httpsProxy: $proxy, noProxy: $noproxy}' \
    "${CONFIG}" > "${tmp}"
mv "${tmp}" "${CONFIG}"

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
