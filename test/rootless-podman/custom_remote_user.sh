#!/bin/bash
# Verifies the feature does not hardcode "vscode": run against an image/remoteUser combination where the
# target user is "node" instead, and repeat the user-specific checks from test.sh for that user.
set -e

source dev-container-features-test-lib

check "podman is installed" bash -c "command -v podman"

check "subuid range reserved for 'node'" bash -c 'grep -q "^node:" /etc/subuid'
check "subgid range reserved for 'node'" bash -c 'grep -q "^node:" /etc/subgid'

check "runtime dir owned by 'node'" bash -c '[ "$(stat -c %U /var/lib/rootless-podman/run)" = "node" ]'

check "no subuid/subgid entry for 'vscode' was created" bash -c '! grep -q "^vscode:" /etc/subuid && ! grep -q "^vscode:" /etc/subgid'

reportResults
