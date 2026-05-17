# Theme state variant rendering — `#hover` and `#active`

Make the documented `aspect#hover` and `aspect#active` theme variants actually
affect rendering. Today the keys parse, the listeners register, and hover
events fire — but no draw site overlays the variant onto the base aspect, so
the visual feedback never appears.

Scope: input package state + render-side aspect resolution + one UI test.
No theme schema change, no API change, no doc rewrite.

## Motivation

`docs/reference/theme.md:151` and `docs/core-api.md:420` both document
`#hover` and `#active` as supported theme state variants, and
`docs/core-api.md:350` literally says *"Applies `aspect#hover` theme
variant"*. The kitchen-sink theme uses them (`:button-primary#hover`,
`:button-icon#hover`, etc.) but pressing or hovering a button produces no
visual change. The same applies to any other aspect carrying these variants.

The wiring is half-built:

| Step                                                  | Status | Site                                    |
|-------------------------------------------------------|--------|-----------------------------------------|
| Theme parser accepts `:foo#hover` / `:foo#active`     | works  | `src/redin/parser/theme_parser.odin`    |
| `HoverListener` registered when `<aspect>#hover` set  | works  | `src/redin/input/input.odin:184`        |
| Per-frame HOVER user-events fire under the cursor     | works  | `src/redin/input/user_events.odin:20`   |
| `ApplyActive{idx}` emitted on mouse-down              | works  | `src/redin/input/apply.odin:46`         |
| Runtime consumes `ApplyActive`                        | **no-op** | `src/redin/runtime.odin:260-261` (empty case) |
| `view.fnl` consumes `:hover` events                   | dropped intentionally | `src/runtime/view.fnl:36`     |
| `render.odin` overlays `<aspect>#hover` / `#active`   | **missing** | `draw_button` (1313), `draw_themed_rect` (1105), `draw_text` (1356), `draw_box_chrome` (696) |
| `#focus` overlay (already works)                      | works  | `src/redin/render.odin:1191`            |

This fix completes the missing edges without touching the rest.

## Non-goals

- **Composed aspects.** `docs/reference/theme.md:165-171` describes
  `{:aspect [:button :danger]}` merging — never built. `aspect: string` on
  every node struct (`types/view_tree.odin:61,71,80,...`), parsed via a
  single `lua_get_string_field` call, never used in any example or test.
  Punt to a follow-up; doc-vs-impl gap is acknowledged but not closed here.
- **Runtime-side hover state.** `view.fnl:36` keeps dropping `:hover` events.
  Visual state is pure Odin — no Lua roundtrip per frame. Apps that *want* to
  react to hover from Fennel can still wire a custom listener; the framework
  doesn't push hover into the dataflow.
- **Doc changes.** The docs already describe the correct behaviour. Code
  catches up to docs, not the other way around.
- **New event delivery to apps.** `#hover` / `#active` are purely visual —
  no new dispatched events, no new public API.

## Design

### State in the `input` package

Mirror the existing `focused_idx` package-level state with two new fields:

```odin
hovered_indices: [dynamic]int   // ordered set, no duplicates
active_idx:      int = -1
```

`hovered_indices` is a set, not a single idx, because the current input
contract (`input.odin:64`) explicitly preserves ancestor hover: a hover on
a nested button does not "shadow" a hover on its row. CSS does the same.
Render iterates by node idx anyway, so membership check is the right shape.

Both are reset to empty / `-1` at the right lifecycle points:

- `hovered_indices`: cleared and rebuilt every frame inside
  `get_user_events`, right where the HOVER user-events are already emitted
  (`user_events.odin:20-28`). Same iteration, just record the idx into the
  set alongside the event append.
- `active_idx`: set in `apply_listeners` (`apply.odin:46`) when a
  `MouseEvent` with `pressed = true` lands on a winner that has a
  `ClickListener` (so non-clickable bg-only nodes can't pin themselves
  active). Cleared in `apply_listeners` when a `MouseEvent` with
  `pressed = false` is observed — *unconditionally*, regardless of cursor
  position. This implements the agreed CSS-like "stays active until
  mouseup, even if you drag off" semantics.

The existing `MouseEvent` already carries press/release state in the
input poller — confirm in implementation; if not, extend the event.

### `runtime.odin:260` no-op cleanup

`runtime.odin:260-261` has an empty case body for `types.ApplyActive`.
Either:

- delete the case + remove `ApplyActive` from `apply_events.odin` if
  nothing else consumes it (active state is set directly in
  `apply_listeners` per the previous section), **or**
- keep `ApplyActive` as the channel and have the runtime set
  `input.active_idx = ev.idx` in the case body.

Decision: **delete the `ApplyActive` event**. State lives in `input`, set
directly by the package that owns it; one less indirection. The
`types.ApplyActive` struct and union case go too. `ApplyFocus` stays as-is
(it does have a non-empty consumer — `input.focus_enter` / `focus_leave`).

### Render-side aspect resolution

Introduce one helper in `render.odin`, used by every draw site that
currently does `theme[n.aspect]`:

```odin
// Merge base aspect + state variants in the documented order.
// Precedence (later overrides earlier): base < #focus < #hover < #active.
// Returns the merged Theme struct; falls back to zero-value if base
// aspect is missing.
resolve_themed_aspect :: proc(
    idx: int,
    aspect: string,
    theme: map[string]types.Theme,
) -> types.Theme
```

Callers replace `if t, ok := theme[n.aspect]; ok { ... }` with
`t := resolve_themed_aspect(idx, n.aspect, theme)` and stop hand-rolling
the `#focus` overlay (it moves into the helper).

State checks inside the helper:

- `#focus` overlay: `idx == input.focused_idx`. Currently only
  meaningful for `NodeInput` (which is where the existing overlay
  lives) — extending it to all aspects is harmless because the existing
  listener-registration in `input.odin:189-197` only attaches a
  `FocusListener` when `<aspect>#focus` is present AND the node is not an
  input. Inputs use their own focus path. Either way: applying `#focus`
  to a focused node with no `<aspect>#focus` entry is a no-op (map miss).
- `#hover` overlay: `slice.contains(input.hovered_indices[:], idx)`.
- `#active` overlay: `idx == input.active_idx`.

Active takes precedence over hover, which takes precedence over focus,
which takes precedence over base — matches the merge order documented in
`docs/reference/theme.md:170-171` (base → composed → state, with state
ordered focus < hover < active).

### Drag interaction

Two cases:

1. **Drag source / preview node.** When a node is rendered as the drag
   source or in the drag-preview clone, the drag system has already
   swapped its aspect to the draggable's `:aspect`
   (`docs/core-api.md:270`). The swap aspect *is* the source-of-truth
   "I am being dragged" visual; we don't want `#hover` / `#active` on
   top of it. **Bypass mechanism**: the helper signature takes `idx`;
   the drag-preview draw paths (`draw_subtree_translated` at
   `render.odin:650,654,659,668`) pass `idx = -1`. A `-1` idx fails
   every state check (`-1 == focused_idx == -1` is possible but
   `focused_idx == -1` means no node is focused anyway; same for
   `active_idx`; and `-1` is never appended to `hovered_indices`). The
   helper short-circuits state overlays when `idx < 0`, making this
   explicit.

2. **Mouse-down that becomes a drag.** `active_idx` is set on mouse-down.
   If the press triggers a drag, the drag preview takes over rendering.
   `active_idx` would still be set on the underlying node until mouseup.
   This is fine: the user doesn't see the underlying node in active state
   (it's covered by the preview / scrolled away), and mouseup clears it
   on drop. No special case needed.

### Re-flatten / index invalidation

The architecture note in CLAUDE.md says every per-node side table indexed
by node idx must be invalidated when bridge re-flattens the frame. Both
`hovered_indices` and `active_idx` qualify. Add invalidation in the same
`clear_frame` site that already resets `focused_idx` / `node_rects`:

- `hovered_indices` is rebuilt every frame anyway — no explicit clear
  needed, but a `clear()` in `clear_frame` is cheap insurance against
  cross-frame leakage if the input pump is skipped.
- `active_idx`: if the active node's idx no longer exists in the new
  frame, the next mouseup will still clear it. To be safe against
  out-of-bounds idx reads, bounds-check before using (mirrors the
  existing `if focused_idx >= len(node_rects)` guard at
  `apply.odin:13`).

## Test plan

One new UI integration test, modelled on the existing
`test/ui/test_input.bb` pattern (which uses `/input/takeover` +
`/input/mouse/*` + assertions).

### `test/ui/hover_active_app.fnl`

A minimal app with two themed buttons sharing the same fixed-size rect
geometry but distinct base / hover / active bg colors:

```fennel
(theme.set-theme
  {:btn          {:bg [50 50 50]   :color [255 255 255] :radius 0}
   :btn#hover    {:bg [100 100 100]}
   :btn#active   {:bg [200 200 200]}})

;; Single button at known coordinates so the test can sample bg pixel.
[:stack {:viewport [[:top_left 0 0 :full :full]]}
  [:button {:aspect :btn :width 100 :height 40 :click [:noop]}
    "btn"]]
```

The flat colour rect (no rounding, no gradient) lets the test sample a
single pixel inside the rect from `/screenshot` and compare against the
known base / hover / active values exactly.

### `test/ui/test_hover_active.bb`

Steps:

1. `GET /frames` to read the button's rect from `attrs.rect`.
2. Sample the screenshot pixel at a fixed bg-only point — top-left
   interior at `rect.x + 4, rect.y + 4` (clears the corner radius and
   any glyph footprint). Assert `[50 50 50]` (base).
3. `POST /input/takeover`, `POST /input/mouse/move` to the rect center,
   wait one frame, `GET /screenshot`, sample same bg-only point →
   assert `[100 100 100]` (hover).
4. `POST /input/mouse/down {button:"left"}`, wait one frame,
   `GET /screenshot` → assert `[200 200 200]` (active).
5. `POST /input/mouse/move` to (0,0) **while still down**, wait one
   frame, `GET /screenshot` → assert active colour persists at the
   button's bg sample point (stays-active-until-mouseup semantics).
6. `POST /input/mouse/up`, wait one frame, `GET /screenshot` →
   assert base colour returns (cursor is at (0,0) now, no longer
   hovered).
7. `POST /input/release`.

Screenshot pixel sampling: Babashka can decode PNG via
`javax.imageio.ImageIO` or via a small Java interop block; pick whichever
is consistent with how other UI tests handle byte responses (the input
test framework already returns binary bodies for `/screenshot` — verify
during implementation, factor a shared helper if it's not already there).

## Out of scope, filed as follow-ups

- **Composed aspects** (`{:aspect [:foo :bar]}`) — type / parser /
  render-resolver work, see Non-goals above.
- **Runtime-side hover state** — apps that want hover dispatch (e.g.
  for tooltips) would need a separate opt-in attribute, not a
  reverse-engineering of `:hover` events out of the listener pipeline.
- **Hover cursor.** `input.set_hover_cursor` already swaps the system
  cursor for hover-listener nodes. Unchanged by this work, mentioned for
  context (a node with `#hover` automatically gets a pointing-hand
  cursor today — that part already works).
