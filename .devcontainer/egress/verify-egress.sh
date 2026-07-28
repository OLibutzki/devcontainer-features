#!/usr/bin/env bash
# Verify from inside the dev container that the egress firewall is actually
# enforcing, rather than merely configured. Exits non-zero if any check fails.

set -u

# Allowlisted by default, and a stable endpoint that returns 200.
ALLOWED_URL="https://update.code.visualstudio.com/api/releases/stable"
# Not on the allowlist.
BLOCKED_URL="https://example.com/"
# A literal IP, so no DNS is involved: this tests reachability, not resolution.
DIRECT_URL="https://1.1.1.1/"

failures=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; failures=$((failures + 1)); }

echo
echo "Egress firewall check"
echo "  proxy: ${HTTPS_PROXY:-<unset>}"
echo

if [ -n "${HTTPS_PROXY:-}" ] && [ -n "${https_proxy:-}" ]; then
    pass "proxy environment is set"
else
    fail "proxy environment is not set (HTTPS_PROXY / https_proxy)"
fi

if curl -sSf -o /dev/null --max-time 30 "${ALLOWED_URL}" 2>/dev/null; then
    pass "allowlisted host is reachable through the proxy"
else
    fail "allowlisted host is NOT reachable — check the proxy is up: docker compose -f .devcontainer/docker-compose.yml logs egress"
fi

if curl -sS -o /dev/null --max-time 30 "${BLOCKED_URL}" 2>/dev/null; then
    fail "a non-allowlisted host was reachable — the allowlist is not being applied"
else
    pass "non-allowlisted host is refused by the proxy"
fi

# The one that matters. If this fails, the container has a route to the internet
# that does not pass through the proxy, and the allowlist is advisory only.
if curl -sS --noproxy '*' -o /dev/null --max-time 10 "${DIRECT_URL}" 2>/dev/null; then
    fail "the container reached the internet WITHOUT the proxy — the 'internal: true' network has been lost"
else
    pass "no route to the internet outside the proxy"
fi

echo
if [ "${failures}" -ne 0 ]; then
    echo "${failures} check(s) failed. Do not treat this container as network-restricted."
    exit 1
fi
echo "Egress is restricted to .devcontainer/egress/allowed-domains.txt"
