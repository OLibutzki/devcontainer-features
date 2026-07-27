#!/bin/bash
# Verifies the whole point of the feature end to end: with the runArgs this feature's NOTES.md tells
# consumers to add (--device=/dev/fuse, --device=/dev/net/tun -- see scenarios.json for this scenario),
# rootless Podman can actually start a container, not just install successfully.
set -e

source dev-container-features-test-lib

check "device nodes are present" bash -c 'test -e /dev/fuse && test -e /dev/net/tun'

check "rootless podman can actually start a container" bash -lc '
    /usr/local/bin/rootless-podman-start.sh
    podman run --rm hello-world
'

# Same check via the `docker` binary: proves podman-docker's wrapper -- and by extension any tool that only
# knows how to shell out to `docker`, e.g. @devcontainers/cli -- actually works end to end, not just that
# the binary is present (see test.sh for the install-only check).
check "docker (podman-docker wrapper) can actually start a container" bash -lc '
    /usr/local/bin/rootless-podman-start.sh
    docker run --rm hello-world
'

reportResults
