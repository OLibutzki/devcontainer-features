#!/bin/bash
# "version": "stable" -- the installer takes the channel as its positional argument.
set -e

source dev-container-features-test-lib

check "claude is on PATH in a login shell" bash -lc "command -v claude"
check "claude reports a version" bash -lc "claude --version | grep -Eq '[0-9]+\.[0-9]+\.[0-9]+'"
check "installed for the remote user" bash -lc 'test -x "${HOME}/.local/bin/claude"'
check "a version landed in ~/.local/share/claude/versions" \
    bash -lc 'test -d "${HOME}/.local/share/claude/versions" && test -n "$(ls -A "${HOME}/.local/share/claude/versions")"'
# The installer records the channel it was invoked with; tolerate its absence on builds that predate the
# setting, but if the file exists it must still be readable JSON-ish rather than a truncated write.
check "settings.json (if written) is non-empty and balanced" bash -lc '
    f="${HOME}/.claude/settings.json"
    if [ -f "$f" ]; then
        test -s "$f" && head -c1 "$f" | grep -q "{" && tail -c2 "$f" | grep -q "}"
    fi'

reportResults
