# redin

A re-frame inspired desktop UI framework. Odin + Raylib renderer, Fennel + Lua scripting layer.

## Design document

The design lives in `design/` as numbered files:

- `00-overview.md` — architecture, principles, non-goals
- `01-frames.md` — visual data format, elements, attributes
- `02-bindings.md` — interaction map (path vectors → events)
- `03-theme.md` — design system / theme tokens (aspects)
- `04-dataflow.md` — re-frame style event → state → view pipeline
- `05-server.md` — HTTP/WS server for AI + dev tools
- `06-testing.md` — testing pure data (frames, handlers, aspects)
- `07-build.md` — module layout and build strategy

**Keep the design docs in sync with the implementation.** When you change behavior, add elements, or alter data formats, update the relevant design file. The design docs are the source of truth for how the system should work.

## Testing

Unit tests are essential. Every change must have corresponding tests. The framework's core value is that frames, bindings, handlers, and aspects are all pure data — test them as data. No rendering needed for most tests.

## Stack

- **Host/renderer:** Odin + Raylib
- **Scripting:** Lua VM with Fennel compiled to Lua
- **AI interface:** localhost HTTP/WS server
