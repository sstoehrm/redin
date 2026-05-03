# Mouse takeover for UI testing

**Status:** design
**Date:** 2026-05-01

## Problem

The current drag UI test (`test/ui/test_drag.bb`) bypasses the input
pipeline entirely: it calls `dispatch` with hand-crafted Lua events
(`event/drag`, `event/drop`, `event/over`) and asserts on the resulting
state. This verifies that the Fennel handlers work, but **never
exercises** the press → threshold-cross → drop pipeline in
`src/redin/input/drag.odin`. A regression in the Odin-side state machine
would not be caught.

The dev server already has `POST /click` for injecting a `MouseEvent`
press, but it cannot drive a drag because:

1. `process_drag` reads `rl.GetMousePosition()` directly each frame
   (drag.odin:131, 224, 283).
2. `process_drag` reads `rl.IsMouseButtonDown(.LEFT)` directly to decide
   when Pending → Active and when Active → drop.
3. A single injected press event is followed immediately by raylib
   reporting button-up, so the framework never sees the held state.

## Goals

- A UI test can drive a full drag-and-drop sequence (press, move past
  threshold, move over drop target, release) through the dev server,
  exercising the real `process_drag` state machine.
- A UI test can inject `Esc` mid-drag to test cancel behavior.
- The mechanism does not change behavior for normal (non-test) runs.
- The mechanism does not require monkey-patching raylib.

## Non-goals

- Pixel-diff golden-image testing. Mid-drag screenshots are saved as
  artifacts for human / agent inspection, not asserted on.
- Scroll-wheel takeover. Not needed for the current drag tests.
- Driving real production input through the dev server (this is a
  test-only feature).

## Design overview

Three layers:

1. **`input.override` package state** — a mouse-state struct that, when
   `active`, takes precedence over raylib polling.
2. **Dev-server endpoints** — explicit takeover lifecycle plus
   fine-grained mouse and key injection.
3. **Test framework helpers** — Babashka-side wrappers in
   `test/ui/redin_test.bb` plus a rect-of helper that reads layout
   positions embedded in `/frames`.

### Layer 1 — input override

A new file `src/redin/input/override.odin`:

```odin
package input

import rl "vendor:raylib"

Mouse_Override :: struct {
    active:        bool,
    pos:           rl.Vector2,
    button_left:   bool,
    button_right:  bool,
    button_middle: bool,

    // Edge-detection flags. Set by dev-server handlers when button state
    // changes; consumed and cleared by poll() each frame to synthesise
    // MouseEvent press / release events into the input stream.
    pending_press_left,    pending_release_left:    bool,
    pending_press_right,   pending_release_right:   bool,
    pending_press_middle,  pending_release_middle:  bool,
}

override: Mouse_Override

mouse_pos :: proc() -> rl.Vector2 {
    if override.active do return override.pos
    return rl.GetMousePosition()
}

is_mouse_button_down :: proc(btn: rl.MouseButton) -> bool {
    if override.active {
        switch btn {
        case .LEFT:   return override.button_left
        case .RIGHT:  return override.button_right
        case .MIDDLE: return override.button_middle
        case:         return false
        }
    }
    return rl.IsMouseButtonDown(btn)
}

is_mouse_button_pressed :: proc(btn: rl.MouseButton) -> bool {
    if override.active {
        switch btn {
        case .LEFT:
            r := override.pending_press_left
            override.pending_press_left = false
            return r
        case .RIGHT:
            r := override.pending_press_right
            override.pending_press_right = false
            return r
        case .MIDDLE:
            r := override.pending_press_middle
            override.pending_press_middle = false
            return r
        case: return false
        }
    }
    return rl.IsMouseButtonPressed(btn)
}

// is_mouse_button_released is symmetric; reads + clears pending_release_*.
```

The `pending_*` flags act as a one-shot edge: a single
`POST /input/mouse/down` followed by N frames of holding produces
exactly one press event (matching raylib's `IsMouseButtonPressed`
semantics), and `is_mouse_button_down` continues to report `true` for
the held duration.

#### Call-site sweep

Replace all direct raylib mouse reads with the new helpers. Audited
sites:

- `src/redin/input/input.odin` — `poll()` (line 148, 184), `set_hover_cursor()` (line 452)
- `src/redin/input/drag.odin` — `process_drag()` (lines 131, 224, 283)
- `src/redin/input/text_select.odin` — 4 sites (lines 137, 144, 163, plus one more)
- `src/redin/input/user_events.odin` — line 17

The override is package-global state in `input`, mirroring how raylib
itself is global. Threading an `Input_Source` parameter through every
call site was considered and rejected — the indirection cost outweighs
the purity benefit when the underlying input source (raylib) is already
global.

### Layer 2 — dev-server endpoints

All endpoints require `Authorization: Bearer <token>` (existing pattern).
All return `{"ok":true}` on success or `{"error":"..."}` with appropriate
4xx status on failure.

| Method | Path | Body | Description |
|---|---|---|---|
| POST | `/input/takeover` | `{}` | Sets `input.override.active = true`. Resets pos to (0,0) and all buttons up. **409** if already active. |
| POST | `/input/release` | `{}` | Clears `input.override.active`. **409** if not active. |
| POST | `/input/mouse/move` | `{"x":N,"y":N}` | Sets override position. **409** if not active. **400** if x/y NaN/Inf. Out-of-bounds positions are allowed (drag-out-of-window is a real case worth testing). |
| POST | `/input/mouse/down` | `{"button":"left\|right\|middle"}` | Sets `pending_press_*` and `button_*`. **409** if not active. **409** if button already down. |
| POST | `/input/mouse/up` | `{"button":"left\|right\|middle"}` | Sets `pending_release_*` and clears `button_*`. **409** if button already up. |
| POST | `/input/key` | `{"key":"escape\|enter\|...","mods":{"shift":bool,...}}` | Synthesises one `KeyEvent`. Does **not** require takeover. `mods` is optional. |

#### Threading

Server handlers run on the HTTP thread. They mutate `input.override`
fields directly. This is safe because the runtime loop reads override
state only between frames (in `poll()`, `process_drag`, etc.), not
concurrently with handler writes. The existing `event_queue` in the
dev server uses the same shared-mutation pattern, and the same
constraint applies (mutation between frames is fine; mid-frame races
are out of scope).

#### Why explicit lifecycle

`/input/mouse/*` returns 409 unless `/input/takeover` was called first.
A forgotten `/input/release` becomes a 409 on the next test, not silent
state leakage into subsequent tests.

#### Why `/input/key` is one-shot

Key state is event-driven, not continuous polling. The framework only
reads `KeyEvent` from the input stream; there is no `IsKeyDown` check in
the input pipeline that needs override. A one-shot synthesis suffices,
and skipping the takeover gate keeps the API minimal.

### Layer 3 — `/frames` rect embedding

To click on a specific element, tests need its screen rect.

Modify the `/frames` handler so each node's attrs object gains a
`"rect": [x, y, w, h]` field:

```json
[":hbox", {"aspect": "row", "id": "row-1", "rect": [16, 64, 488, 40]}, ...]
```

#### Implementation

Replace the current path through `lua_value_to_json` for `/frames` with
a dedicated walker that:

1. Walks the Lua frame tree DFS (mirroring `lua_read_node`'s
   flattening order).
2. Maintains a counter that advances at each node, used as index into
   `render.node_rects`.
3. For each node, emits `[tag, attrs-with-rect, ...children]` JSON.

The walker bounds-checks each access into `node_rects` and emits a
`null` rect if the index is out of range (which can happen briefly
during hot-reload, when `b.nodes` was re-flattened but render hasn't
run yet).

#### Staleness

Rects come from the most recently *rendered* frame, which may lag the
last *pushed* tree by one tick. Tests that fetch `/frames` immediately
after dispatching an event must `wait-ms` (already standard practice
for state assertions that depend on a re-render).

### Layer 4 — test framework helpers

Add to `test/ui/redin_test.bb`:

```clojure
(defn input-takeover [] (post-json "/input/takeover" {}))
(defn input-release  [] (post-json "/input/release"  {}))
(defn input-mouse-move [x y] (post-json "/input/mouse/move" {:x x :y y}))
(defn input-mouse-down [btn] (post-json "/input/mouse/down" {:button (name btn)}))
(defn input-mouse-up   [btn] (post-json "/input/mouse/up"   {:button (name btn)}))
(defn input-key
  ([k]      (post-json "/input/key" {:key (name k)}))
  ([k mods] (post-json "/input/key" {:key (name k) :mods mods})))

(defn rect-of
  "Read [x y w h] from a frame node's :rect attr."
  [node]
  (let [attrs (frame-attrs node)
        [x y w h] (get attrs :rect)]
    {:x x :y y :w w :h h}))
```

## Test recipe

The new drag test (added to `test/ui/test_drag.bb` or as a sibling
file) drives the full pipeline:

```clojure
(deftest drag-preview-pops-out
  (dispatch ["event/reset"])
  (wait-ms 100)
  (let [src (rect-of (find-element {:id :row-1}))
        dst (rect-of (find-element {:id :row-3}))
        sx  (+ (:x src) 10) sy (+ (:y src) 10)
        dx  (+ (:x dst) 10) dy (+ (:y dst) 10)]
    (input-takeover)
    (input-mouse-move sx sy)
    (input-mouse-down :left)
    (input-mouse-move (+ sx 20) (+ sy 5))    ; cross 4px threshold
    (wait-for (state= "last-drag" 1))
    (input-mouse-move dx dy)                 ; preview over drop target
    (wait-ms 50)                             ; let render catch up
    (screenshot "test/ui/artifacts/drag_preview.png")
    (input-mouse-up :left)
    (wait-for (state= "last-drop.from" 1))
    (input-release)))

(deftest drag-esc-cancels
  (dispatch ["event/reset"])
  (wait-ms 100)
  (let [src (rect-of (find-element {:id :row-1}))
        sx  (+ (:x src) 10) sy (+ (:y src) 10)]
    (input-takeover)
    (input-mouse-move sx sy)
    (input-mouse-down :left)
    (input-mouse-move (+ sx 20) sy)
    (wait-for (state= "last-drag" 1))
    (input-key :escape)
    (wait-ms 50)
    (input-mouse-up :left)
    (assert-state "last-drop" nil?)
    (input-release)))
```

`test/ui/artifacts/` is gitignored. The run-all script creates it if
missing. The screenshot is for human / agent verification — no
automated pixel assertion.

## Failure modes and edge cases

- **Test crashes between takeover and release.** The override state
  persists, but each test app invocation starts a fresh process under
  `run-all.sh`, so leakage is bounded to one test file.
- **Real keyboard / mouse during a takeover under a windowed run.**
  Real keyboard events still fire (only mouse is overridden). Real
  mouse position is ignored. Acceptable — tests run under xvfb in CI
  where there is no real input.
- **Out-of-sync `node_rects` length vs. frame tree.** Walker bounds-
  checks; emits `null` rects on mismatch.
- **Button-down sent when already down (or up when already up).** 409,
  to surface bugs in test scripts.

## Documentation updates

- `CLAUDE.md` — dev-server endpoint table.
- `docs/core-api.md` — dev-server section, frame-format note about the
  `:rect` attr.
- `docs/reference/dev-server.md` — new endpoints with examples.
- `.claude/skills/redin-dev/SKILL.md` — dev-server table, drag test
  example.
- `.claude/skills/redin-maintenance/SKILL.md` — note that drag tests
  now exercise the real input pipeline.

## Out of scope (future work)

- `GET /pixel?x=N&y=N` — would let tests assert preview-clone bg color
  programmatically. Skipped this round per "agent verifies for now".
- Server-side gesture script endpoint — multi-step drag in a single
  HTTP call. Skipped: explicit per-step calls match existing test
  cadence and are easier to debug.
- Scroll-wheel injection. No current tests need it.
