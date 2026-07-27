#!/bin/bash
# Default options, run against whichever base image the CI matrix picked.
set -e

source dev-container-features-test-lib

check "claude is on PATH in a login shell" bash -lc "command -v claude"
check "claude reports a version" bash -lc "claude --version | grep -Eq '[0-9]+\.[0-9]+\.[0-9]+'"
check "launcher installed below ~/.local/bin" bash -lc 'test -x "${HOME}/.local/bin/claude"'
check "PATH snippet installed" test -f /etc/profile.d/claude-code.sh
# The native installer owns ~/.local/bin/claude; shadowing it breaks the auto-updater.
check "no /usr/local/bin/claude shadowing the launcher" bash -c '! test -e /usr/local/bin/claude'
check "claude resolves to the installer's launcher" bash -lc '[ "$(command -v claude)" = "${HOME}/.local/bin/claude" ]'
check "no node installed by this feature" bash -c '! test -f /etc/apt/sources.list.d/nodesource.list'

# Sandbox dependencies: the CLI's own sandboxed Bash tool (not this feature) can require these at runtime;
# without them it hard-fails with "Sandbox is required but failed to initialize".
check "bubblewrap installed (bwrap)" bash -c "command -v bwrap"
check "socat installed" bash -c "command -v socat"

# Onboarding: a CLAUDE_CODE_OAUTH_TOKEN login otherwise stops at the interactive theme/login screen.
# See https://github.com/anthropics/claude-code/issues/8938
check "onboarding script installed" test -x /usr/local/bin/claude-code-onboarding.sh
check "onboarding enabled by default" \
    bash -lc '[ "$(cat /usr/local/etc/claude-code/auto-onboarding)" = "true" ]'
check "hasCompletedOnboarding is true in ~/.claude.json" \
    bash -lc 'jq -e ".hasCompletedOnboarding == true" "${HOME}/.claude.json"'
check "~/.claude.json is owned by the remote user" \
    bash -lc '[ "$(stat -c %U "${HOME}/.claude.json")" = "$(id -un)" ]'
check "onboarding script is idempotent" \
    bash -lc '/usr/local/bin/claude-code-onboarding.sh && jq -e ".hasCompletedOnboarding == true" "${HOME}/.claude.json"'
check "onboarding script preserves unrelated keys" bash -lc '
    f="${HOME}/.claude.json"
    tmp=$(mktemp); jq ".someUserKey = \"keep-me\"" "$f" > "$tmp" && mv "$tmp" "$f"
    /usr/local/bin/claude-code-onboarding.sh
    jq -e ".someUserKey == \"keep-me\" and .hasCompletedOnboarding == true" "$f"'

reportResults
