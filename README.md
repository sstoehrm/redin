# redin

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
./redinw --dev main.fnl

# Or a Lua project
redin-cli new-lua my-app
```

The CLI downloads a pinned redin binary into `.redin/` — no build tools needed. See `redin-cli help` for all commands.

### Building from source

```bash
# Prerequisites (Ubuntu/Debian)
sudo apt-get install -y luajit libluajit-5.1-dev libssl-dev

# Build
odin build src/host -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin

# Run
./build/redin --dev examples/kitchen-sink.fnl
```

| Dependency | Purpose | Required |
|-----------|---------|----------|
| **Odin** (nightly) | Compiles the host/renderer | Yes |
| **Raylib** | Bundled with Odin | -- |
| **LuaJIT** (`luajit` + `libluajit-5.1-dev`) | Runs tests, AOT compiles Fennel | Yes |
| **OpenSSL** (`libssl-dev`) | HTTPS support via odin-http | Yes |

## Test

```bash
# Fennel runtime tests
luajit test/lua/runner.lua test/lua/test_*.fnl

# Build check
odin build src/host -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

## Project structure

```
src/host/                Odin host application
  main.odin              Entry point and main loop
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
