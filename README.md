# ra-plugins

A collection of plugins for the [`remote-agent`](https://github.com/adamtait/remote-agent) (ra) CLI — a tool for creating and managing ephemeral cloud workstations.

Each plugin is a self-contained directory with a `plugin.yaml` manifest and optional scripts that run at image build time, workstation startup, and shell login.

## Plugins

| Plugin | Description |
|--------|-------------|
| [antigravity](./antigravity/) | Installs the Antigravity (`agy`) CLI |
| [aws](./aws/) | AWS CLI v2 with credentials injected from GCP Secret Manager at boot |
| [babashka](./babashka/) | Fast-starting native Clojure interpreter (`bb`) |
| [claude](./claude/) | Claude Code — installs and configures the CLI; supports OAuth or API key |
| [claude-sync](./claude-sync/) | Syncs `~/.claude/` across workstations via a GCS bucket (see its [README](./claude-sync/README.md)) |
| [codex](./codex/) | OpenAI Codex CLI — supports ChatGPT OAuth or API key |
| [et](./et/) | Eternal Terminal server — auto-reconnecting connections via `ra connect --et` |
| [gcloud](./gcloud/) | Google Cloud CLI — authenticates via a service-account key, a Workload Identity Federation config, or the workstation's own attached identity |
| [github](./github/) | GitHub CLI + PAT-based git credential helper; optionally clones repos at first boot |
| [marimo](./marimo/) | Reactive Python notebook server — auto-starts the edit server at boot |
| [terraform](./terraform/) | HashiCorp Terraform CLI |
| [tmux](./tmux/) | tmux — starts a persistent named session at boot and auto-attaches login shells |
| [uv](./uv/) | `uv` — fast Python package and project manager |

## Usage

Install a plugin into your `ra` project:

```bash
ra plugin install ./path/to/plugin
```

`ra` prompts for config values and credentials, stores secrets in GCP Secret Manager, and applies the plugin to all subsequent `ra create` calls.

See the [remote-agent docs](https://github.com/adamtait/remote-agent) for full CLI reference.

---

## Creating a plugin

A plugin is a directory with a `plugin.yaml` and optional shell scripts. Author one locally and install it with `ra plugin install ./my-plugin`.

### Directory structure

```
my-plugin/
├── plugin.yaml                          # required
├── Dockerfile.d/
│   └── 100_my-plugin-install.sh         # optional: build-time hooks
├── workstation-startup.d/
│   └── 250_my-plugin-setup.sh           # optional: per-boot runtime setup
└── profile.d/
    └── 00-my-plugin-env.sh              # optional: login-shell additions
```

Plugin scripts mirror where they land in the image (`/etc/...`):

| Directory | When it runs | Use it for |
|---|---|---|
| `Dockerfile.d/` | Docker image build time | Installing packages, downloading binaries |
| `workstation-startup.d/` | Every container boot, after `200_remote-agent-setup.sh` | Auth setup, credential helpers, first-boot data clones |
| `profile.d/` | Every login shell | PATH additions, shell aliases |

### Script naming conventions

Filenames follow `<NNN>_<plugin-name>-<purpose>.sh`. Numbers control execution order within the directory.

- **`Dockerfile.d/`** — use `100`–`199`
- **`workstation-startup.d/`** — use `250`+. The core `200_remote-agent-setup.sh` runs first; plugin scripts must be ≥ 250 to guarantee secrets are available.
- **`profile.d/`** — no strict convention; existing plugins use `00`–`50`. Lower numbers run first.

### plugin.yaml schema

```yaml
name: my-plugin           # required; becomes RA_PLUGIN_<NAME>_* prefix
version: "1.0.0"
description: "What this plugin does"

config:
  - name: enabled         # include in every plugin
    type: bool            # bool | string | string_list | int
    description: "Enable my plugin?"
    default: false
  - name: my_setting
    type: string
    description: "A string option"
    default: ""
    options: [alpha, beta, gamma]  # omit for free-form input

secrets:
  - name: my_token
    env_var: MY_TOKEN
    description: "API token for my service"
    default_secret_name: my-plugin-token   # GCP Secret Manager name
    value_command:                         # optional: capture at install time
      command: my-cli
      args: ["login"]
      output: stdout                       # stdout | file_base64
      path: "~/.my-cli/auth.json"          # required for file_base64
      validate: json                       # optional: json
      interactive: true

auth_providers:            # omit if no auth choice is needed
  - name: apikey
    description: "Static API key"
    secrets:
      - name: my_apikey
        env_var: MY_APIKEY
        description: "API key from my service's console"
        default_secret_name: my-plugin-apikey
```

`ra plugin install` prompts for each `config` field, the chosen `auth_provider` (if any), and secret values (hidden input). If a field or secret declares `value_command`, `ra` runs that local command and uses its output instead of prompting. Config is written to `config.yaml`; secret values go to GCP Secret Manager.

**Additional top-level fields:**

`port-for-tunnel: <port>` — exposes a workstation port as a tunnel endpoint (e.g. a web server). Used by the `marimo` plugin.

`buckets:` — declares a GCS bucket that `ra` provisions at install time and makes available at runtime via env var. Used by the `claude-sync` plugin. Fields: `name`, `name_template`, `override_field`, `role`, `env_var`.

### Runtime environment contract

`ra create` injects plugin configuration as container env vars:

```
RA_PLUGIN_<UPPERCASE_NAME>_<UPPERCASE_FIELD>=<value>   # config fields
RA_PLUGIN_<UPPERCASE_NAME>_AUTH_PROVIDER=<provider>    # if auth_providers used
RA_SECRET_<UPPERCASE_LOGICAL>_NAME=<gcp-secret-name>   # secret metadata
RA_SECRET_<UPPERCASE_LOGICAL>_VAR=<env-var-name>
```

Secret *values* are fetched from GCP Secret Manager at each boot by `200_remote-agent-setup.sh` and written to `/run/ra/env`. Your startup script reads them by sourcing that file.

**`Dockerfile.d/` scripts do not have access to `RA_PLUGIN_*` env vars.** Build-time behavior must be hardcoded in the script.

### Standard startup script preamble

Every `workstation-startup.d/` script should open with:

```bash
[ -r /run/ra/env ] && set -a && . /run/ra/env && set +a
[ "${RA_PLUGIN_MY_PLUGIN_ENABLED:-false}" = "true" ] || exit 0
```

Line 1 sources fetched secrets. Line 2 exits immediately if the plugin is disabled.

### First-boot markers

For work that should run only once per workstation lifetime (cloning a repo, expensive initial setup):

```bash
FIRST_BOOT_MARKER="/home/user/.ra-my-plugin-first-boot-done"
[ -e "${FIRST_BOOT_MARKER}" ] && exit 0

# ... first-boot work ...

touch "${FIRST_BOOT_MARKER}"
chown user:user "${FIRST_BOOT_MARKER}"
```

### Tips

- **Always gate on `RA_PLUGIN_<NAME>_ENABLED`.** Without it, your script runs on every workstation even when the plugin is not installed.
- **Every-boot scripts must be idempotent.** They run on every container start. Overwrite config files (`>`), don't append (`>>`).
- **`Dockerfile.d/` scripts run as root** with no user home, no secrets, and no runtime env. Keep them to system-level installs only.

### Testing locally

```bash
ra plugin install ./my-plugin --user   # install from local path
ra plugin list                         # confirm installed
ra create                              # rebuild image + reprovision

ra plugin remove my-plugin             # remove when done
```

To test a startup script on a running workstation:

```bash
ra connect
sudo bash /etc/workstation-startup.d/250_my-plugin-setup.sh
```
