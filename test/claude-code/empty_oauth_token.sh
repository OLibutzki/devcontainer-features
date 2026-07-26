#!/bin/bash
# Reproduces what "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}" in devcontainer.json produces when the host has no
# such variable: the credential is DEFINED but EMPTY. The feature must drop it so Claude Code falls back to
# browser login instead of presenting a blank credential.
set -e

source dev-container-features-test-lib

# Sanity: the scenario really did define them as empty at the container level.
check "container defines an empty CLAUDE_CODE_OAUTH_TOKEN" \
    bash -c 'printenv CLAUDE_CODE_OAUTH_TOKEN >/dev/null && [ -z "$(printenv CLAUDE_CODE_OAUTH_TOKEN)" ]'

check "empty CLAUDE_CODE_OAUTH_TOKEN is unset in a login shell" \
    bash -lc '! printenv CLAUDE_CODE_OAUTH_TOKEN >/dev/null'
check "empty ANTHROPIC_API_KEY is unset in a login shell" \
    bash -lc '! printenv ANTHROPIC_API_KEY >/dev/null'
check "empty CLAUDE_CODE_OAUTH_TOKEN is unset in an interactive shell" \
    bash -ic '! printenv CLAUDE_CODE_OAUTH_TOKEN >/dev/null'

# A non-empty credential must survive untouched -- the cleanup must not eat real tokens.
check "a non-empty token is preserved" \
    bash -lc 'CLAUDE_CODE_OAUTH_TOKEN=real-token bash -lc "[ \"\$CLAUDE_CODE_OAUTH_TOKEN\" = real-token ]"'

check "claude still runs" bash -lc "claude --version | grep -Eq '[0-9]+\.[0-9]+\.[0-9]+'"

reportResults
