<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/redin-logo-horizontal-dark.svg">
    <img src="docs/assets/redin-logo-horizontal.svg" width="520" alt="redin: Native desktop UI with the magic intact.">
  </picture>
</p>

A re-frame inspired desktop UI framework built on Odin, Raylib, and LuaJIT.

Write reactive desktop apps in Fennel (or Lua) with the same dataflow model that makes re-frame a joy: single state atom, event-driven updates, path-tracked subscriptions, declarative effects. No browser, no Electron, no JS bundler.

> **Experimental.** This project is under active reboot. APIs will change.

## Stack

| Layer | Technology |
|-------|-----------|
| Host / renderer | Odin + Raylib |
| Scripting | LuaJIT (Lua 5.1) |
| App language | Fennel (or plain Lua) |
| AI interface | HTTP dev server |

## Getting started

The easiest way to start is with [redin-cli](https://github.com/sstoehrm/redin-cli):

```bash
# Install the CLI (requires Babashka)
curl -sL https://raw.githubusercontent.com/sstoehrm/redin-cli/main/install.sh | bash

# Create a Fennel project
redin-cli new-fnl my-app
cd my-app
./redinw main.fnl

# Or a Lua project
redin-cli new-lua my-app
```

The CLI downloads a pinned redin binary into `.redin/` — no build tools needed. See `redin-cli help` for all commands.

> **⚠️ The shipped binary runs a local control server.** Release binaries (what `redin-cli` downloads) and `./build-dev.sh` builds are compiled with `REDIN_DEV` on, so launching one starts an authenticated HTTP dev server on `localhost`. Any process running as **your own user** can read the per-run token and fully drive the window — dispatch events, run the app's `:shell`/`:http` effects, screenshot it, or shut it down. Read [Security](#security) before running on a shared or untrusted account.

### Building from source

The one-step path is `./setup.sh`, which installs system packages (via apt / dnf / pacman / brew), pulls submodules, and runs `./build-dev.sh`. The manual equivalent is below.

```bash
# Prerequisites (Ubuntu/Debian)
sudo apt-get install -y luajit libssl-dev \
  libgl1-mesa-dev libx11-dev libxrandr-dev libxi-dev \
  libxcursor-dev libxinerama-dev

# Initialize submodules (lib/odin-http)
git submodule update --init --recursive

# Dev build (bakes in REDIN_DEV / REDIN_PROFILE / REDIN_TRACK_MEM)
./build-dev.sh

# Run — dev server starts because REDIN_DEV is compiled in.
# Exactly one positional argument is accepted; extra args exit 2.
./build/redin examples/kitchen-sink.fnl
```

For a release-stripped binary (no dev server, no profile, no tracker), use bare `odin build` instead:

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

| Dependency | Purpose | Required |
|-----------|---------|----------|
| **Odin** (dev-2026-07 or newer) | Compiles the host/renderer | Yes |
| **Raylib** (6.0) | Bundled with Odin (`vendor:raylib`) | -- |
| **LuaJIT** (`luajit`) | Runs tests, AOT compiles Fennel; the C library is statically linked from `vendor/luajit/` so `libluajit-5.1-dev` is not required | Yes |
| **OpenSSL** (`libssl-dev`) | HTTPS support via odin-http | Yes |
| **OpenGL + X11 dev headers** (Linux only — `libgl1-mesa-dev`, `libx11-dev`, `libxrandr-dev`, `libxi-dev`, `libxcursor-dev`, `libxinerama-dev`) | Required by Odin's bundled Raylib at link time | Yes (Linux) |
| **`lib/odin-http` submodule** | Async HTTP client used by `redin.http` | Yes |

## Security

redin's release binary — the one `redin-cli` downloads, and anything built with `./build-dev.sh` — is compiled with `REDIN_DEV` (plus `REDIN_PROFILE` and `REDIN_TRACK_MEM`) baked in. This is deliberate: the shipped binary's audience is AI-driven workflows that need the HTTP dev server. The trade-off is that **every launch starts an authenticated control server on loopback.**

On startup the server binds `localhost:<port>` and writes a per-run 256-bit token to `./.redin-token` (mode 0600, deleted on shutdown). Every request needs `Authorization: Bearer <token>` and a matching `Host` header (a DNS-rebinding defence). A process running as a *different* user cannot read the token. But any process running **as your own user** can read `.redin-token` and then:

- dispatch arbitrary events (`POST /events`) — including any `:shell` or `:http` effect the app registered, i.e. command execution or network access in your context;
- inject clicks and keystrokes, resize the window, capture a screenshot, or shut it down;
- replace the theme (`PUT /aspects`).

On a machine where you trust every process running under your user, this is a convenience. On a shared or untrusted account, treat a running redin window as fully controllable by anything with your uid.

**If you don't want the dev channel**, build a release-stripped binary yourself — no dev server, no profile overlay, no tracking allocator:

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

The [Dev Server reference](docs/reference/dev-server.md#runtime-caveats) covers the filesystem-trust and token-as-capability caveats in more detail.

## Test

```bash
# Fennel runtime tests
luajit test/lua/runner.lua test/lua/test_*.fnl

# Build check
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

UI integration tests additionally need [Babashka](https://github.com/babashka/babashka#installation) (`bb`), and `xvfb` for headless runs:

```bash
sudo apt-get install -y xvfb
bash test/ui/run-all.sh --headless
```

## Project structure

```
src/cmd/redin/           Thin CLI entry (package main)
  main.odin              Arg parsing, calls redin.run
src/redin/               Importable framework (package redin)
  runtime.odin           Public API + main loop
  render.odin            Raylib renderer
  bridge/                Lua/Fennel bridge
  canvas/                Canvas provider system
  input/                 Input handling
  types/                 Shared type definitions
src/runtime/             Fennel runtime modules
examples/                Demo apps
test/lua/                Fennel unit tests
test/ui/                 UI integration tests (Babashka)
.claude/skills/          Claude Code development skills
docs/                    Documentation
```

## Documentation

### Guides
- [Quickstart](docs/guide/quickstart.md)
- [Building Apps](docs/guide/building-apps.md)
- [Re-frame Quickstart](docs/guide/re-frame-quickstart.md)
- [Lua Guide](docs/guide/lua-guide.md)
- [Fennel Cheatsheet](docs/guide/fennel-cheatsheet.md)

### Reference
- [Elements](docs/reference/elements.md)
- [Theme](docs/reference/theme.md)
- [Effects](docs/reference/effects.md)
- [Dev Server](docs/reference/dev-server.md)
- [Canvas](docs/reference/canvas.md)

### Specs
- [Core API](docs/core-api.md) -- frame format, events, host functions, dev server
- [App API](docs/app-api.md) -- dataflow, effects, view runner
