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
| AI interface | HTTP dev server + MCP |

## Getting started

```bash
# Build from source
odin build src/host -out:build/redin

# Run an app
./build/redin examples/kitchen-sink.fnl

# Run with dev server + hot reload
./build/redin --dev examples/kitchen-sink.fnl
```

## Prerequisites

```bash
# Ubuntu/Debian
sudo apt-get install -y luajit libluajit-5.1-dev libssl-dev
```

| Dependency | Purpose | Required |
|-----------|---------|----------|
| **Odin** (nightly) | Compiles the host/renderer | Yes |
| **Raylib** | Bundled with Odin | -- |
| **LuaJIT** (`luajit` + `libluajit-5.1-dev`) | Runs tests, AOT compiles Fennel | Yes |
| **OpenSSL** (`libssl-dev`) | HTTPS support via odin-http | Yes |
| **Babashka** (`bb`) | Runs MCP server | Optional |

## Test

```bash
# Fennel runtime tests (95 tests)
luajit test/lua/runner.lua test/lua/test_*.fnl

# Build check
odin build src/host -out:build/redin
```

## Project structure

```
src/host/                Odin host application
  main.odin              Entry point and main loop
  render.odin            Raylib renderer
  bridge/                Lua/Fennel bridge
  input/                 Input handling
  parser/                File parsers
  types/                 Shared type definitions
src/runtime/             Fennel runtime modules
examples/                Demo apps
test/lua/                Fennel unit tests
test/ui/                 UI integration tests (Babashka)
mcp/                     MCP server for AI tools
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
