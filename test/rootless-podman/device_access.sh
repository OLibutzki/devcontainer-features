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

reportResults
