# uv — fast Python packaging on every workstation

Installs [`uv`](https://github.com/astral-sh/uv) (and `uvx`) from Astral at image
build time, so a new `ra` workstation can create virtualenvs, install packages, and
run tools without waiting on `pip`.

## What you get

```bash
$ uv venv && uv pip install requests      # create a venv and install into it
$ uvx ruff check .                         # run a tool in a throwaway env, no install
```

Both `uv` and `uvx` are baked into `/usr/local/bin` during the image build, so they
are on `PATH` the moment the workstation boots — no first-boot download.

## Install

```bash
# From the plugin repo (installs just this plugin):
ra plugin install https://github.com/adamtait/ra-plugins uv

# Or from a local clone:
ra plugin install ./uv
```

`ra` prompts for config, then applies the plugin to every subsequent `ra create`.
Set `enabled` to `true` when prompted.

## Configuration

| Field     | Type | Default | Description                       |
|-----------|------|---------|-----------------------------------|
| `enabled` | bool | `false` | Install `uv` on the workstation.  |

`uv` tracks the latest release (no version pin). The binary is downloaded over HTTPS
from the GitHub `releases/latest` redirect; note there is **no** checksum verification
step (unlike the `terraform` and `pulumi` plugins).
