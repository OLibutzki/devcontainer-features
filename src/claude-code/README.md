
# Claude Code (claude-code)

Installs Anthropic's Claude Code CLI using the recommended native installer.

## Example Usage

```json
"features": {
    "ghcr.io/olibutzki/devcontainer-features/claude-code:0": {}
}
```

## Options

| Options Id | Description | Type | Default Value |
|-----|-----|-----|-----|
| version | Release channel ('latest' or 'stable') or an exact version such as '2.1.89'. The value chosen here also becomes the default auto-update channel. | string | latest |
| disableAutoUpdater | Set DISABLE_AUTOUPDATER=1 in the user's ~/.claude/settings.json so Claude Code does not update itself in the background. Use this for reproducible images and whenever downloads.claude.ai is not on your egress allowlist. | boolean | false |
| autoOnboarding | Set hasCompletedOnboarding=true in the user's ~/.claude.json so a CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY login starts a session instead of the interactive theme/login screen (anthropics/claude-code#8938). Set to false to keep the first-run onboarding flow. | boolean | true |

## Customizations

### VS Code Extensions

- `anthropic.claude-code`

> **Experimental (`0.x`).** Breaking changes are likely: options may be renamed, removed or have their
> defaults reversed in any release before `1.0.0`. Pin the exact patch version, never the rolling `:0` tag.

## What this feature does

Installs [Claude Code](https://code.claude.com/docs/en/setup) with the recommended native installer:

```bash
curl -fsSL https://claude.ai/install.sh | bash -s <channel|version>
```

No Node.js is installed or required. The installer is per-user, so the feature runs it as the container's
remote user: the launcher lands in `~/.local/bin/claude` and the versions in
`~/.local/share/claude/versions`. `~/.local/bin` is put on `PATH` via `/etc/profile.d/claude-code.sh` (plus
`/etc/bash.bashrc` and `/etc/zsh/zshenv` where they exist).

There is deliberately **no `/usr/local/bin/claude` symlink**: the installer owns `~/.local/bin/claude` and
manages it as a symlink into `versions/`, and the
[setup docs](https://code.claude.com/docs/en/setup#auto-updates) warn that replacing that launcher breaks
the auto-updater and makes `claude doctor` report an unmanaged launcher.

The feature also brings in Anthropic's
[VS Code extension](https://marketplace.visualstudio.com/items?itemName=anthropic.claude-code)
(`anthropic.claude-code`) and [JetBrains plugin](https://plugins.jetbrains.com/plugin/27310)
(`com.anthropic.code.plugin`) where the editor supports them.

Anthropic publishes [its own feature](https://github.com/anthropics/devcontainer-features), which installs
via `npm` on a bootstrapped Node 18 and exposes no options. This one exists for the native installer and a
pinnable version — check upstream before choosing, and prefer it if maintenance resumes there.

## Example

```jsonc
{
    "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
    "remoteUser": "vscode",
    "features": {
        "ghcr.io/olibutzki/devcontainer-features/claude-code:0.0.3": {
            "version": "stable"
        }
    }
}
```

## Signing in

Run `claude` and follow the browser prompt. If the sign-in completes but the callback never reaches the
container, copy the code from the browser and paste it at the `Paste code here if prompted` prompt.

To sign in without a browser, generate a token on the host with
[`claude setup-token`](https://code.claude.com/docs/en/authentication#generate-a-long-lived-token) and
forward it with **one line in your `devcontainer.json`**:

```jsonc
"remoteEnv": {
    "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}"
}
```

Use `ANTHROPIC_API_KEY` for a Console account, or your cloud credentials on Bedrock / Vertex / Foundry.
That line has to live in `devcontainer.json` because a feature cannot substitute a *host* value. The two
things that otherwise make it not work are handled here:

* **Onboarding is marked complete.** A token alone still stops at the interactive theme/login screen
  ([anthropics/claude-code#8938](https://github.com/anthropics/claude-code/issues/8938)). The feature sets
  `hasCompletedOnboarding` in `~/.claude.json` — at build time and again on every container start, because
  that file may live on a volume that does not exist yet at build time. Merged with `jq`, so your other
  keys survive. Opt out with `"autoOnboarding": false`.
* **An empty value is dropped.** `${localEnv:...}` expands to an *empty string* on a host without that
  variable, and Claude Code would see a blank credential instead of falling back to browser login. So the
  same committed config works for teammates with and without a token.

> A forwarded token is readable by every process in the container, including the commands the agent runs.
> So is the credential store under `~/.claude`. If that matters, restrict egress (below), run the agent as
> a separate unprivileged user, or use short-lived tokens for untrusted repositories.

## Persist authentication across rebuilds

The container's home directory is discarded on rebuild, so without a volume you sign in again every time.
Claude Code keeps its token, settings and history in `~/.claude`:

```jsonc
"mounts": [
    "source=claude-code-config-${devcontainerId},target=/home/vscode/.claude,type=volume"
]
```

**The target must match your `remoteUser`'s home** — `/home/vscode` is right for
`mcr.microsoft.com/devcontainers/base:ubuntu` and wrong for `node` or `root`, and a wrong path fails
*silently*. Mounting elsewhere means setting
[`CLAUDE_CONFIG_DIR`](https://code.claude.com/docs/en/env-vars) to match. `${devcontainerId}` keeps the
state per project, which matters because `~/.claude` holds live credentials. The feature cannot declare
this mount itself: it cannot know your `remoteUser`'s home at authoring time.

## Restricting network egress

**This feature does not restrict network access**, and Anthropic
[warns](https://code.claude.com/docs/en/devcontainer) that with `--dangerously-skip-permissions` a dev
container will not stop a malicious project from exfiltrating anything reachable inside it — including the
credentials in `~/.claude`. A feature cannot fix that: an egress boundary needs a second container on a
private network, which is a topology a feature cannot create from inside an already-composed container.

Use the template instead:

```bash
devcontainer templates apply -t ghcr.io/olibutzki/devcontainer-templates/egress-firewall:0.0.1 -w .
```

Then add these to its `allowed-domains.txt`, per
[network access requirements](https://code.claude.com/docs/en/network-config#network-access-requirements):

| Host | Needed for |
| --- | --- |
| `api.anthropic.com` | API requests, WebFetch domain safety check, feature flags |
| `claude.ai` | claude.ai sign-in (and serves `install.sh`) |
| `claude.com` | sign-in redirect; pre-approved WebFetch documentation lookups |
| `platform.claude.com` | OAuth token exchange, refresh and revocation — for **both** account types |
| `downloads.claude.ai` | native installer, auto-updater, plugin downloads |
| `storage.googleapis.com` | plugin metadata shown in `/plugin`; artifact uploads |
| `code.claude.com` | documentation lookups by the built-in claude-code-guide agent |
| `raw.githubusercontent.com` | changelog feed for `/release-notes` |
| `mcp-proxy.anthropic.com` | only if you use claude.ai MCP connectors |
| `bridge.claudeusercontent.com` | only if you use Claude in Chrome |

* Turn optional telemetry off rather than allowlisting its hosts:
  `"containerEnv": { "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1" }`.
* `registry.npmjs.org` and `formulae.brew.sh` are **not** needed — this feature uses neither installer.
* If you leave `downloads.claude.ai` off the list, set `"disableAutoUpdater": true` so the CLI stops
  retrying an update it cannot reach.
* The allowlist is a **runtime** boundary. This feature downloads at **image build** time, before it
  applies.

## Behind a build-time proxy

Set the proxy the way Docker expects — `--build-arg HTTPS_PROXY=...`, or a `proxies` block in
`~/.docker/config.json` — and the feature follows it. `HTTP_PROXY`, `HTTPS_PROXY`, `FTP_PROXY` and
`NO_PROXY` (either case) are re-exported across the `su -` boundary the per-user installer needs, and the
build log says `Forwarding the build-time proxy configuration to the installer.` when it happens.
`claude.ai` and `downloads.claude.ai` must be reachable through the proxy for the install to work, and
`api.anthropic.com` for the CLI to be usable afterwards.

## Sandboxed Bash tool dependencies

The feature installs `bubblewrap` and `socat` alongside Claude Code. Neither is something this feature turns
on: they back the CLI's own sandboxed Bash tool, which is gated by `sandbox.enabled` /
`sandbox.failIfUnavailable` in `settings.json` — settings that can end up true from a user's or org's own
config, or from Anthropic's own default rollout, entirely outside this feature's control. Without the two
packages, a session that needs the sandbox fails hard with `Sandbox is required but failed to initialize:
Sandbox dependencies not available: socat not installed.` instead of falling back quietly, so both are
installed unconditionally rather than guessed at from current settings. This is unrelated to the
`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` mechanism below, which also uses `bwrap` but for a different purpose.

## OS support

Debian/Ubuntu-based **Dev Container** images on x64 or arm64 — CI covers
`mcr.microsoft.com/devcontainers/base:ubuntu` and `:debian`, and images derived from them work the same
way. A non-apt base fails the build with a clear message. Bare `ubuntu:latest` / `debian:latest` are not
supported: they lack too much of what a dev container assumes.


---

_Note: This file was auto-generated from the [devcontainer-feature.json](https://github.com/olibutzki/devcontainer-features/blob/main/src/claude-code/devcontainer-feature.json).  Add additional notes to a `NOTES.md`._
