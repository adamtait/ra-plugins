# babashka — instant-start Clojure scripting

Installs [babashka](https://github.com/babashka/babashka) (`bb`), a GraalVM-compiled
native Clojure interpreter, at image build time. Startup is measured in milliseconds,
so `bb` is practical for shell-glue scripts where the JVM's boot time would be a
non-starter.

## What you get

```bash
$ bb -e '(println (+ 1 2))'
3
$ bb script.clj                 # run a Clojure script with no JVM warm-up
```

`bb` is installed to `/usr/local/bin/bb` during the build and is on `PATH` at boot.

## Install

```bash
# From the plugin repo (installs just this plugin):
ra plugin install https://github.com/adamtait/ra-plugins babashka

# Or from a local clone:
ra plugin install ./babashka
```

`ra` prompts for config, then applies the plugin to every subsequent `ra create`.
Set `enabled` to `true` when prompted.

## Configuration

| Field     | Type | Default | Description                            |
|-----------|------|---------|----------------------------------------|
| `enabled` | bool | `false` | Install babashka on the workstation.   |

Tracks the latest release. The build downloads the `linux-amd64-static` binary, so
this plugin currently supports **x86_64 only**.
