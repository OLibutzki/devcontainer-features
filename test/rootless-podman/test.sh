#!/bin/bash
# Default options, run against whichever base image the CI matrix picked.
#
# Deliberately does NOT run `podman run`/`podman info` here: this scenario's test container has no
# --device=/dev/fuse or --device=/dev/net/tun, so a real rootless container start would fail regardless of
# whether the feature installed correctly. See the "device_access" scenario (scenarios.json) for the actual
# end-to-end `podman run` check, which supplies those two runArgs.
set -e

source dev-container-features-test-lib

check "podman is installed" bash -c "command -v podman"
check "podman reports a version" bash -c "podman --version | grep -Eq '[0-9]+\.[0-9]+\.[0-9]+'"
check "newuidmap installed (uidmap package)" bash -c "command -v newuidmap"
check "slirp4netns installed" bash -c "command -v slirp4netns"
check "pasta installed (passt package)" bash -c "command -v pasta"
check "fuse-overlayfs installed" bash -c "command -v fuse-overlayfs"
check "catatonit package installed" bash -c "dpkg -s catatonit"
check "podman-docker package installed" bash -c "dpkg -s podman-docker"

check "docker command resolves (via podman-docker)" bash -c "command -v docker"
check "docker is podman-docker's wrapper, not a real Docker CLI" bash -c "docker --version | grep -q '^podman version'"

check "subuid range reserved for the remote user" bash -c 'grep -q "^$(id -un):" /etc/subuid'
check "subgid range reserved for the remote user" bash -c 'grep -q "^$(id -un):" /etc/subgid'

check "storage.conf configures fuse-overlayfs" bash -c 'grep -q "fuse-overlayfs" /etc/containers/storage.conf'

check "runtime dir exists and is 0700" bash -c 'test -d /var/lib/rootless-podman/run && [ "$(stat -c %a /var/lib/rootless-podman/run)" = "700" ]'
check "runtime dir owned by the remote user" bash -c '[ "$(stat -c %U /var/lib/rootless-podman/run)" = "$(id -un)" ]'

check "start script installed" test -x /usr/local/bin/rootless-podman-start.sh

check "DOCKER_HOST points at the rootless socket path" bash -lc '[ "${DOCKER_HOST}" = "unix:///var/lib/rootless-podman/run/podman/podman.sock" ]'
check "TESTCONTAINERS_RYUK_DISABLED is set" bash -lc '[ "${TESTCONTAINERS_RYUK_DISABLED}" = "true" ]'

reportResults
