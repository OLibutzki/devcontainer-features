#!/bin/bash
# "disableAutoUpdater": true -- merged into the env block of the user's ~/.claude/settings.json.
set -e

source dev-container-features-test-lib

check "claude reports a version" bash -lc "claude --version | grep -Eq '[0-9]+\.[0-9]+\.[0-9]+'"
check "settings.json exists" bash -lc 'test -f "${HOME}/.claude/settings.json"'
check "DISABLE_AUTOUPDATER is set to 1 under the env block" \
    bash -lc 'jq -e ".env.DISABLE_AUTOUPDATER == \"1\"" "${HOME}/.claude/settings.json"'
check "settings.json is owned by the remote user" \
    bash -lc '[ "$(stat -c %U "${HOME}/.claude/settings.json")" = "$(id -un)" ]'
check "config directory is owned by the remote user" \
    bash -lc '[ "$(stat -c %U "${HOME}/.claude")" = "$(id -un)" ]'

reportResults
