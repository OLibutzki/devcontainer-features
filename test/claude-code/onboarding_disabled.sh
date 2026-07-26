#!/bin/bash
# "autoOnboarding": false -- the feature must leave the first-run onboarding flow alone.
set -e

source dev-container-features-test-lib

check "claude reports a version" bash -lc "claude --version | grep -Eq '[0-9]+\.[0-9]+\.[0-9]+'"
check "the opt-out was recorded" \
    bash -lc '[ "$(cat /usr/local/etc/claude-code/auto-onboarding)" = "false" ]'
check "hasCompletedOnboarding was NOT set" bash -lc '
    f="${HOME}/.claude.json"
    if [ -f "$f" ]; then ! grep -q "\"hasCompletedOnboarding\":[[:space:]]*true" "$f"; fi'
# The script ships regardless, but must no-op when the option is off.
check "onboarding script is a no-op when opted out" bash -lc '
    /usr/local/bin/claude-code-onboarding.sh
    f="${HOME}/.claude.json"
    if [ -f "$f" ]; then ! grep -q "\"hasCompletedOnboarding\":[[:space:]]*true" "$f"; fi'

reportResults
