> **Experimental (`0.x`).** Breaking changes are likely: options may be renamed, removed or have their
> defaults reversed in any release before `1.0.0`. Pin the exact patch version, never the rolling `:0`
> tag, and read the release notes before moving up.

## What this feature does

Installs [Claude Code](https://code.claude.com/docs/en/setup) with the **recommended native installer**:

```bash
curl -fsSL https://claude.ai/install.sh | bash -s <channel|version>
```

In an editor that supports them, the feature also brings in Anthropic's
[VS Code extension](https://marketplace.visualstudio.com/items?itemName=anthropic.claude-code)
(`anthropic.claude-code`) and [JetBrains plugin](https://plugins.jetbrains.com/plugin/27310)
(`com.anthropic.code.plugin`, *Claude Code [Beta]*, for IntelliJ IDEA and the other IntelliJ-based IDEs).
Editors that do not understand a given `customizations` block simply ignore it.

The native installer is per-user, so the feature runs it as the container's remote user: the launcher
lands in `~/.local/bin/claude` and the versions in `~/.local/share/claude/versions`. `~/.local/bin` is put
on `PATH` via `/etc/profile.d/claude-code.sh` (plus `/etc/bash.bashrc` and `/etc/zsh/zshenv` where they
exist).

There is deliberately **no `/usr/local/bin/claude` symlink**. The installer owns `~/.local/bin/claude` and
manages it as a symlink into `versions/`; the [setup docs](https://code.claude.com/docs/en/setup#auto-updates)
warn that replacing that launcher makes the auto-updater keep every version on disk and makes
`claude doctor` report an unmanaged launcher.

No Node.js is installed or required.

## Relationship to the official Anthropic feature

Anthropic publishes [`ghcr.io/anthropics/devcontainer-features/claude-code`](https://github.com/anthropics/devcontainer-features/tree/main/src/claude-code),
which the [dev container docs](https://code.claude.com/docs/en/devcontainer) still point at. Use whichever
fits you — but as of this writing the differences are worth knowing:

| | Official feature | This feature |
| --- | --- | --- |
| Install method | `npm install -g @anthropic-ai/claude-code`, bootstrapping **Node 18** from NodeSource | The native installer, which the docs label **"(Recommended)"** |
| Node.js | Required | Not used |
| Options | none (`"options": {}`) | `version`, `disableAutoUpdater` |
| Pin a CLI version | Not supported — the docs tell you to [drop down to a Dockerfile](https://code.claude.com/docs/en/devcontainer#enforce-organization-policy) instead | `"version": "2.1.89"` |

The npm package now [requires Node.js 22 or later](https://code.claude.com/docs/en/setup#install-with-npm),
while that feature's last commit — 25 June 2025 — still installs Node 18; issue
[#26 "Deprecated?"](https://github.com/anthropics/devcontainer-features/issues/26), opened 4 August 2025,
is still open and unanswered. Check those links before choosing; if upstream picks maintenance back up,
prefer it.

## Example

```jsonc
{
    "image": "mcr.microsoft.com/devcontainers/base:ubuntu",
    "remoteUser": "vscode",
    "features": {
        "ghcr.io/olibutzki/devcontainer-features/claude-code:0.0.1": {
            "version": "stable"
        }
    }
}
```

## Authentication

The feature installs the CLI only; it does not log you in. Run `claude` and follow the browser prompt, or
hand it a token — see the next section.

If the browser sign-in completes but the callback never reaches the container — port forwarding does not
always route the localhost callback — copy the code shown in the browser and paste it at the
`Paste code here if prompted` prompt.

## Signing in with a token (`CLAUDE_CODE_OAUTH_TOKEN`)

Generate a long-lived token on the host with
[`claude setup-token`](https://code.claude.com/docs/en/authentication#generate-a-long-lived-token), then
forward it into the container by adding **one line to your `devcontainer.json`**:

```jsonc
"remoteEnv": {
    "CLAUDE_CODE_OAUTH_TOKEN": "${localEnv:CLAUDE_CODE_OAUTH_TOKEN}"
}
```

Use `ANTHROPIC_API_KEY` instead for a Console account. On Amazon Bedrock, Google Cloud's Agent Platform or
Microsoft Foundry, pass your cloud credentials the same way rather than mounting credential files from the
host.

**The feature handles the two things that otherwise make this not work.**

### 1. Onboarding is marked complete

A token on its own is not enough on a fresh install: Claude Code still stops at the interactive theme and
login screen, so a token-authenticated container is not actually usable unattended. This is
[anthropics/claude-code#8938](https://github.com/anthropics/claude-code/issues/8938); the fix is
`hasCompletedOnboarding: true` in **`~/.claude.json`** (note: that file, *not* `~/.claude/settings.json`).

The feature sets it for you — at build time, and again on every container start via `postStartCommand`,
because `~/.claude.json` can live on a volume that does not exist yet when the image is built. The merge is
done with `jq`, so your other keys in that file are preserved. Opt out with `"autoOnboarding": false`.

### 2. A missing host token does not break the container

`${localEnv:CLAUDE_CODE_OAUTH_TOKEN}` expands to an **empty string** when the host has no such variable —
the variable still ends up *defined* in the container, just blank. Claude Code would then see a credential
that is present but empty instead of falling back to browser login.

So the feature drops empty `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN`
values in `/etc/profile.d/claude-code.sh`. The same `devcontainer.json` therefore works for teammates who
have a token on their host and those who do not: the first group is signed in automatically, the second
gets the normal browser login. Non-empty values are never touched.

### Why this line lives in `devcontainer.json` and not in the feature

A feature can set environment variables — this one uses `containerEnv` for
`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` above. What it cannot do is **substitute a host value**, which is what
forwarding a token requires. Verified against `@devcontainers/cli` 0.87.0:

| Where | Property | Literal value | `${localEnv:...}` |
| --- | --- | --- | --- |
| Feature | `containerEnv` | ✅ works | ❌ **fails the build** — emitted verbatim as a Dockerfile `ENV`, which Docker rejects with `unsupported modifier (:H) in substitution` |
| Feature | `remoteEnv` | ❌ ignored | ❌ ignored — `remoteEnv` is not a Feature property |
| `devcontainer.json` | `remoteEnv` | ✅ works | ✅ works |

So the one-line `remoteEnv` entry above is the only place the forwarding can be declared. Everything that
*can* be automated — the onboarding flag, the empty-value cleanup, and the subprocess scrub — is.

### 3. The token is kept out of the agent's subprocesses

`remoteEnv` puts the token in the environment of every process in the container — including, by default,
every command Claude Code runs on your behalf. A `printenv` in the Bash tool would show it, and so would
anything a build script chooses to log.

The feature therefore sets, via `containerEnv`:

```json
"CLAUDE_CODE_SUBPROCESS_ENV_SCRUB": "1"
```

Claude Code then strips Anthropic and cloud provider credentials from the environment of the subprocesses
it spawns — the Bash tool, hooks, and MCP stdio servers — while still using the token itself to
authenticate. It applies whether or not the [Bash sandbox](https://code.claude.com/docs/en/sandboxing) is
enabled.

Things to know:

* **Requires Claude Code 2.1.83 or newer, and this is enforced.** On an older release the variable is
  silently ignored, which would leave you with a configuration that looks hardened and is not. So
  `"version"` has a floor: an older pin **fails the build** with an explanatory error instead of installing.
  The check runs before anything is downloaded, and a second check after install catches a `latest` or
  `stable` channel that somehow resolved below the floor.
* **The docs describe it as a best-effort scrub** of Anthropic, cloud and GitHub Actions secrets. The exact
  variable list is not published, so treat it as defense in depth, not a guarantee.
* **It also affects your own tooling.** If a script the agent runs legitimately needs `ANTHROPIC_API_KEY`,
  it will no longer see it. That is the intended trade-off; override it in your `devcontainer.json` if you
  need the old behaviour:

  ```jsonc
  "containerEnv": { "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB": "0" }
  ```

> **What this does not do.** The scrub keeps the credential out of *subprocess environments*. It is not a
> boundary against an agent that is determined to find it: anything running as the same user can still read
> the credential store under `~/.claude`. For a real boundary, restrict egress so a leaked token cannot be
> sent anywhere (see below), run the agent as a separate unprivileged user, or use short-lived tokens for
> untrusted repositories.

## Persist authentication and settings across rebuilds

By default the container's home directory is discarded on rebuild, so **you have to sign in again every
time**. Claude Code keeps its token, settings and session history in
[`~/.claude`](https://code.claude.com/docs/en/claude-directory). Mount a named volume there:

```jsonc
"mounts": [
    "source=claude-code-config-${devcontainerId},target=/home/vscode/.claude,type=volume"
]
```

* **Match the target to your `remoteUser`'s home.** `/home/vscode` is right for
  `mcr.microsoft.com/devcontainers/base:ubuntu`. It is wrong for `node`, `root` or a custom user — and a
  wrong path fails *silently*: the volume mounts somewhere nothing reads and you keep signing in.
* **Mounting somewhere else?** Set [`CLAUDE_CONFIG_DIR`](https://code.claude.com/docs/en/env-vars) to the
  mount path so Claude Code reads and writes there.
* **`${devcontainerId}` keeps the state per project.** `~/.claude` holds live credentials, so do not share
  one volume across projects you do not equally trust.
* **Codespaces:** `~/.claude` survives stopping and starting a codespace but is still cleared on rebuild,
  so the mount applies there too. To carry authentication *across* codespaces, store `ANTHROPIC_API_KEY`
  or a `CLAUDE_CODE_OAUTH_TOKEN` as a Codespaces secret instead.

### Why the feature does not do this for you

A feature's `mounts` and `containerEnv` are static metadata merged into the container unconditionally —
option values cannot be interpolated into them. So this could not be offered as an opt-in boolean, only as
always-on. And a feature cannot know your `remoteUser`'s home directory at authoring time, so an always-on
mount would have to either hardcode `/home/vscode` or redirect `CLAUDE_CONFIG_DIR` away from `~/.claude`
for everybody. One documented line that you own beats both.

## Restricting network egress

**This feature does not restrict network access.** That matters, because Anthropic's own
[warning](https://code.claude.com/docs/en/devcontainer) is blunt:

> When executed with `--dangerously-skip-permissions`, dev containers do not prevent a malicious project
> from exfiltrating anything accessible inside the container, including the Claude Code credentials stored
> in `~/.claude`.

An egress allowlist is what turns "Claude can run anything in here" into a bounded blast radius. Rather
than building that into this feature, use the template:

```
ghcr.io/olibutzki/devcontainer-templates/egress-firewall:0.0.1
```

### Why a template, and why external

Anthropic's reference container runs [`init-firewall.sh`](https://github.com/anthropics/claude-code/blob/main/.devcontainer/init-firewall.sh)
*inside* the workload container, which is why it has to grant that container `NET_ADMIN` and `NET_RAW`
through `runArgs`. Those are exactly the capabilities needed to flush the rules — the process being
confined holds the key to its own cell. The docs treat this as optional and explicitly invite a
replacement:

> The firewall script and these capabilities are not required for Claude Code itself: you can leave them
> out and rely on your own network controls instead.

The `egress-firewall` template is such a control, applied one layer out. It puts the dev container on a
Docker network declared `internal: true`, so the container has **no default route to the internet at all**,
and runs a Squid sidecar as the only gateway, filtering HTTPS by hostname via `CONNECT` without decrypting
it. Nothing inside the dev container needs `NET_ADMIN`, and unsetting `HTTPS_PROXY` gets an attacker
nowhere, because there is no route to fall back to.

That topology — a second container, a private network, a compose file — is something a *feature* cannot
create: features run inside an already-composed container. Hence a template.

### Applying it

```bash
devcontainer templates apply -t ghcr.io/olibutzki/devcontainer-templates/egress-firewall:0.0.1 -w .
```

Or in VS Code: **Dev Containers: New Dev Container…** → **Show All Definitions…** → paste the template id.
Then add this feature to the `features` block of the generated `devcontainer.json`.

### Allowlist

Add these to the template's `allowed-domains.txt`, per
[network access requirements](https://code.claude.com/docs/en/network-config#network-access-requirements):

| Host | Needed for |
| --- | --- |
| `api.anthropic.com` | API requests, WebFetch domain safety check, feature flags |
| `claude.ai` | claude.ai sign-in (and serves `install.sh`) |
| `claude.com` | sign-in redirect; pre-approved WebFetch documentation lookups |
| `platform.claude.com` | OAuth token exchange, refresh and revocation — needed for **both** account types |
| `downloads.claude.ai` | native installer, auto-updater, plugin downloads |
| `storage.googleapis.com` | plugin metadata shown in `/plugin`; artifact uploads |
| `code.claude.com` | documentation lookups by the built-in claude-code-guide agent |
| `raw.githubusercontent.com` | changelog feed for `/release-notes` |
| `mcp-proxy.anthropic.com` | only if you use claude.ai MCP connectors |
| `bridge.claudeusercontent.com` | only if you use Claude in Chrome |

Notes on the edges of that list:

* The two Datadog intake hosts carry **optional** operational telemetry. Rather than allowlisting them, turn
  them off: `"containerEnv": { "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1" }`.
* `registry.npmjs.org` and `formulae.brew.sh` are **not** needed — they apply to npm and Homebrew installs,
  and this feature uses neither. Your project's own toolchain may still need the npm registry.
* If you leave `downloads.claude.ai` off the list, set `"disableAutoUpdater": true` here so the CLI stops
  retrying an update it cannot reach.
* The allowlist is a **runtime** boundary. This feature downloads from `claude.ai` at **image build** time,
  before it applies — the template's README lists build-time feature downloads (and DNS) as residual
  channels outside its model.

## Organization policy

A dev container is a good place to apply policy, because the same configuration runs on every machine:

* `/etc/claude-code/managed-settings.json`, copied in from your Dockerfile, outranks anything in `~/.claude`
  or the project's `.claude/`. Note that anyone with write access to the repository can edit that Dockerfile
  — for policy engineers cannot bypass, use
  [server-managed settings](https://code.claude.com/docs/en/server-managed-settings) or MDM.
* `containerEnv` applies [environment variables](https://code.claude.com/docs/en/env-vars) to every session,
  e.g. `DISABLE_AUTOUPDATER` or `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`.
* To forbid `--dangerously-skip-permissions` outright, set `permissions.disableBypassPermissionsMode` to
  `"disable"` in managed settings.

## Running without permission prompts

Claude Code refuses `--dangerously-skip-permissions` when launched as root, so set a non-root `remoteUser`.
Even then, skipping prompts removes your chance to review tool calls: Claude can still modify any file in
the bind-mounted workspace — which is your host's working copy — and reach anything the network policy
allows. Pair it with the egress restrictions above, or use
[auto mode](https://code.claude.com/docs/en/permission-modes#eliminate-prompts-with-auto-mode) for fewer
prompts without disabling the safety checks.

## Supported versions

`"version"` accepts `latest`, `stable`, or an exact version **2.1.83 or newer**. Older pins are rejected at
build time — see [the scrub section](#3-the-token-is-kept-out-of-the-agents-subprocesses) for why the floor
exists. If you need an older Claude Code badly enough to give that up, pin the *feature* to a release before
this floor rather than trying to work around it.

## OS support

Debian/Ubuntu on x64 or arm64. Other base images fail the build with a clear message rather than installing
something half-working.
