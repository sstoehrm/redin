# redin — overview

Odin + Raylib render engine. Fennel + Lua scripting layer.
The core idea: **UI is a pure data problem**.

## Architecture

```
Fennel (app code)
  │
  ▼
Lua VM  ──  app-db (single state table)
  │
  ├──▶ interactions (path → event mapping)
  ├──▶ aspects (theme / design tokens)
  ▼
Frames (pure visual data, Lua tables)
  │
  ├──▶ Odin/Raylib renderer  ──▶ pixels on screen
  ├──▶ redin server ◄──────────── AI agent (read/inject frames)
  └──▶ test harness (assert on pure data)
```

## Three layers

A view function returns three things, cleanly separated:

```fennel
{:frame   [...]   ;; pure visual tree — what to draw
 :bind    [...]   ;; interactions — what responds to input
 :aspects [...]   ;; which design tokens to apply
}
```

## Principles

1. **Data > functions > macros.** Prefer plain tables over abstractions.
2. **Frames are visual. Bindings are behavioral. Aspects are aesthetic.** Three concerns, three data structures.
3. **Pure by default.** Side effects only through the fx system.
4. **One state atom.** If you need to know what the app is doing, print app-db.
5. **AI-native.** The server exposes the same data the renderer consumes. AI writes frames, not pixels.
6. **Design system, not styles.** No inline colors. Name your intentions.

## Non-goals (for now)

- Accessibility
- Multi-window
- GPU shaders
- Animation (beyond aspect state transitions)
- Persistent storage (beyond simple file effects)
