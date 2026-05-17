# Draggable scrollbar for scroll-y / scroll-x containers

Make the scrollbar thumb (`draw_box_children:894-916`) interactive: drag to
scroll proportionally, click on the gutter to page-up/page-down, swap to a
vertical-resize cursor while hovered or dragging, and visually emphasise the
bar on hover/active. Theme the bar via a new `:scrollbar` aspect with the
usual `#hover` / `#active` state variants.

Closes [#143](https://github.com/sstoehrm/redin/issues/143). Depends on
[#142](https://github.com/sstoehrm/redin/issues/142) (PR
[#144](https://github.com/sstoehrm/redin/pull/144)) being merged first so the
scissor stack reliably clips scrolled content — the regression tests for this
feature pixel-sample over the list and need consistent clipping.

## Motivation

The bar drawn at the right edge (or bottom) of every scrollable container is
purely cosmetic today. Users have to rely on the mouse wheel to scroll, and
on long lists or large content there's no way to jump to a specific position.
The kitchen-sink demo's todo list visibly hints at draggability — the bar is
the conventional shape and colour — but does nothing when clicked.

Adding interactivity here closes a small but visible UX gap, and it's a
natural follow-up to fixing scroll clipping in #142.

## Non-goals

- **Horizontal scrolling.** The same approach applies to `scroll-x`; the
  implementation handles both axes symmetrically. No separate decision.
- **Keyboard scrolling.** PageUp / PageDown / arrow-key navigation of a
  focused scrollable would be a nice complement but is its own feature
  surface (focus model, key handlers, screen-reader semantics). Filed
  separately if/when it comes up.
- **Mobile-style overlay scrollbars** that fade in/out on activity. The bar
  stays visible whenever the content overflows. Apps that want auto-hide
  can drive `:scrollbar { :bg [...] :opacity 0 }` themselves via theme
  swaps; the framework doesn't time it.
- **Custom scrollbar geometry.** No double-arrow chrome at the ends, no
  tick marks. Just thumb + gutter.

## Design

### State (`src/redin/input/scrollbar.odin`, new file)

A parallel state machine to the existing app-level drag system in
`drag.odin`. Putting it there directly would force `Drag_Captured` (which
embeds payload, animate, ctx ref, tags) into a framework-internal context
where none of those fields make sense.

```odin
package input

Scrollbar_Axis :: enum { Y, X }

Scrollbar_Hovering :: struct {
    container_idx: int,
    axis:          Scrollbar_Axis,
}

Scrollbar_Dragging :: struct {
    using hovering:       Scrollbar_Hovering,
    // Cursor's offset from the thumb's top edge at drag-start. Holding
    // this constant keeps the thumb from snapping under the cursor.
    grab_offset_in_thumb: f32,
}

Scrollbar_State :: union { Scrollbar_Hovering, Scrollbar_Dragging }

scrollbar: Scrollbar_State  // nil = idle
```

The `using` in `Scrollbar_Dragging` lifts the `container_idx` / `axis` fields
to the outer struct, mirroring the pattern in `drag.odin:65-69`.

### Per-frame flow

A new `apply_scrollbar(events, nodes, node_rects)` runs after
`apply_listeners` and before `set_hover_cursor` in `runtime.odin` (around
line 248–272). It:

1. Walks scrollable nodes (`overflow == "scroll-y"` or `"scroll-x"`) to
   build the gutter rect for each. **Gutter geometry**:
   - For scroll-y: `rect = {content_rect.x + content_rect.width - bar_w,
     content_rect.y, bar_w, content_rect.height}`, where `bar_w` is the
     theme's `:scrollbar :border-width` (default 4).
   - **Hit zone widens to `bar_w + 8`** (4px on each side) to make grabbing
     forgiving — the visible bar stays narrow, but the cursor doesn't have
     to land exactly on it.
   - For scroll-x: symmetric, gutter spans the bottom edge.

2. Computes the **thumb rect** identical to `draw_box_children:898-901`:
   - `thumb_h = max(content_rect.height * (content_rect.height / total), 20)`
   - `thumb_y = content_rect.y + (scroll_off / max_scroll) * (content_rect.height - thumb_h)`

3. Handles input events:

   | Event | Current state | Cursor location | Action |
   |---|---|---|---|
   | MouseEvent (press) | any | inside thumb | enter `Scrollbar_Dragging`, set `grab_offset_in_thumb = cursor.y - thumb_y` |
   | MouseEvent (press) | any | gutter, above thumb | `scroll_offsets[idx] -= content_rect.height`, clamp |
   | MouseEvent (press) | any | gutter, below thumb | `scroll_offsets[idx] += content_rect.height`, clamp |
   | mouse-move | `Scrollbar_Dragging` | anywhere | compute `new_thumb_y = cursor.y - grab_offset_in_thumb`, derive new `scroll_offsets[idx]` |
   | mouse-up (`is_mouse_button_released`) | `Scrollbar_Dragging` | anywhere | drop to `Scrollbar_Hovering` if still over gutter, else `nil` |
   | mouse-move (no press) | any | over a gutter | enter `Scrollbar_Hovering` for that idx/axis |
   | mouse-move (no press) | any | not over any gutter | `nil` |

   Press detection re-uses the same MouseEvent that already drives
   `apply_listeners`. Release uses `is_mouse_button_released` (the
   non-destructive variant added to use the override correctly for `#139`
   is sufficient; the consumed `is_mouse_button_released` reads cleanly
   in non-takeover mode).

4. Returns nothing. State mutates `input.scrollbar` and
   `scroll_offsets[idx]` in place.

### Hit-test priority

The new state must beat the existing systems that hit-test under the same
pointer:

- **Click listeners (`apply_listeners`):** if scrollbar handled a press,
  `apply_listeners` should not also fire a click for the underlying node.
  Implement as an early-return: `apply_scrollbar` runs first, returns a
  bool `consumed`; `apply_listeners` skips its MouseEvent loop when
  `consumed` is set for that event.
- **Text selection (`process_text_selection`):** same gating — skip while
  `scrollbar` is `Dragging`, and skip the press if the cursor is on a
  scrollbar gutter at press time.
- **Drag system (`drag.odin`):** while `Scrollbar_Dragging`, never enter
  `Drag_Pending`. Two-line check at the top of `drag_update`.

### Drag math

For `scroll-y`:

```
gutter_top    = content_rect.y
gutter_bottom = content_rect.y + content_rect.height
gutter_height = content_rect.height
thumb_h       = max(gutter_height * (gutter_height / total), 20)
max_thumb_y   = gutter_bottom - thumb_h
max_scroll    = total - gutter_height            // total scrollable distance
new_thumb_y   = clamp(cursor.y - grab_offset_in_thumb, gutter_top, max_thumb_y)
new_offset    = (new_thumb_y - gutter_top) / (max_thumb_y - gutter_top) * max_scroll
```

When `total <= gutter_height` (content fits) the bar isn't drawn and the
scrollbar input is inert — `apply_scrollbar` returns early on that idx.

### Theme (`src/redin/types/theme.odin` already supports `:scrollbar` keys)

No schema change. The theme map keys `scrollbar`, `scrollbar#hover`,
`scrollbar#active` participate in the existing parser. Bundled defaults
live in `src/runtime/theme.fnl`:

```fennel
:scrollbar         {:bg [200 200 200] :opacity 0.47 :radius 2 :border-width 4}
:scrollbar#hover   {:bg [200 200 200] :opacity 0.71}
:scrollbar#active  {:bg [230 230 230] :opacity 0.78}
```

`:border-width` doubles as bar thickness — semantically odd, but no schema
addition. Documented inline at the `:scrollbar` entry in the theme docs.

`draw_box_children` reads the merged theme via `resolve_themed_aspect`
keyed by the scrollable container's idx (not the bar — the bar isn't a
node). State variants resolve from `input.scrollbar`:

```odin
state_idx :: proc(idx: int) -> int {
    switch s in input.scrollbar {
    case Scrollbar_Hovering: if s.container_idx == idx do return idx
    case Scrollbar_Dragging: if s.container_idx == idx do return idx
    }
    return -1
}
```

For an idx hovered: pass `idx` to a helper that overlays `:scrollbar#hover`.
For an idx dragging: overlay `:scrollbar#active` on top of `:scrollbar#hover`
(active wins, CSS-style — same precedence as the existing button/input
helpers).

Concretely the bar draws as:

```odin
asp   := resolve_scrollbar_aspect(idx, theme)
alpha := u8(asp.opacity * 255) if asp.opacity > 0 && asp.opacity < 1 else 255
bg    := rl.Color{asp.bg[0], asp.bg[1], asp.bg[2], alpha}
bar_rect := compute_thumb_rect(idx, content_rect, scroll_info)
rl.DrawRectangleRounded(bar_rect, ..., bg)
```

No schema change. The existing `Theme.opacity` field (already used by
surface and other aspects) carries the bar's transparency; `:bg` stays
`[r g b]`. Defaults: `:scrollbar { :bg [200 200 200] :opacity 0.47 ... }`
(`0.47 ≈ 120/255`, matching today's hardcoded `rl.Color{200, 200, 200,
120}`).

### Cursor (`input/input.odin:set_hover_cursor`)

Add precedence above the existing rules:

```odin
switch _ in scrollbar {
case Scrollbar_Hovering:
    rl.SetMouseCursor(.RESIZE_NS if axis == .Y else .RESIZE_EW)
    return
case Scrollbar_Dragging:
    rl.SetMouseCursor(.RESIZE_NS if axis == .Y else .RESIZE_EW)
    return
}
// then the existing drag / pointing-hand / ibeam / default cascade
```

### Mouse-event ownership during drag

While `Scrollbar_Dragging`, the existing event-consumer ordering means:

- `apply_listeners` won't change `focused_idx` because we early-return its
  MouseEvent loop when scrollbar consumed the press.
- `process_text_selection` won't start a selection because of the gating
  check.
- The app's drag system won't enter `Drag_Pending` for the same reason.

Wheel events (`ScrollEvent`) keep working normally during a scrollbar drag
— `apply_scroll_events` continues to mutate the same `scroll_offsets[idx]`
the bar drag is mutating. Last write wins per frame; in practice a user
won't simultaneously wheel and drag.

### Re-flatten safety

`scrollbar.container_idx` is keyed by node idx. On re-flatten the idx may
no longer exist or may refer to a different node. Bounds-check at the
start of `apply_scrollbar`: `if container_idx >= len(node_rects) ||
container_idx < 0 do scrollbar = nil`. Same pattern as
`apply.odin:13-18`'s existing `focused_idx` / `active_idx` guards.

## Tests

### Unit (`src/redin/input/scrollbar_test.odin`)

Pure-math test of the drag formula. Doesn't need raylib. Given a synthetic
container (`gutter_y`, `gutter_h`, `total`, `bar_w`), exercise:

- Press inside thumb at offset `g` → `Scrollbar_Dragging{ grab_offset_in_thumb = g }`.
- Move cursor by `dy` → `scroll_offsets[idx]` increases by
  `dy / (max_thumb_y - gutter_top) * max_scroll`.
- Cursor moves past `gutter_bottom` → offset clamps at `max_scroll`.
- Cursor moves past `gutter_top` → offset clamps at 0.
- Release → state becomes `Scrollbar_Hovering` if cursor still in gutter,
  else `nil`.

### UI integration (`test/ui/scrollbar_drag_app.fnl` + `test_scrollbar_drag.bb`)

Fixture: a scroll-y vbox at known coordinates with enough rows to overflow
(reuse the shape of `scroll_clip_app.fnl`). Total content known, container
size known, so the test can compute expected `scroll_offsets[idx]` from
cursor moves.

| Test | Setup | Action | Assertion |
|---|---|---|---|
| `thumb-rect-present` | none | read `/frames` | gutter / thumb rect inferrable from `node_scroll_info` (need a `/scroll-info/<idx>` endpoint? or assert via screenshot — see "Open" below) |
| `drag-moves-scroll` | takeover, cursor on thumb | `mouse-down`, `mouse-move +50px`, `mouse-up` | `/state` (via host-exposed `scroll-info`) shows offset increased proportionally |
| `click-below-pages-down` | takeover, cursor below thumb in gutter | `mouse-down`, `mouse-up` | offset = one container-height |
| `click-above-pages-up` | takeover, cursor above thumb in gutter | from a non-zero starting offset (via `/input/scroll`), then click above | offset decreases by one container-height |
| `drag-survives-cursor-off-gutter` | takeover, drag in progress | `mouse-move` x to far left of window | offset still updates |
| `cursor-on-thumb-shows-resize` | takeover, cursor on thumb | (no extra) | `GET /window/cursor` returns `RESIZE_NS` |

The cursor assertion requires either: (a) a new `GET /cursor` endpoint that
exposes the current `rl.GetMouseCursor()` value, or (b) screenshot pixel
inspection at the cursor position. Endpoint is cleaner — same as the
existing `/state` pattern.

The "thumb-rect" assertion is the tricky one — the bar is drawn directly
by `draw_box_children`, not as a node, so it doesn't appear in `/frames`.
Either expose `node_scroll_info` via a new `GET /scroll-info` endpoint, or
infer the thumb rect from a screenshot pixel scan. Endpoint is cleaner;
this is the same pattern as `/agent/nodes`.

### Visual smoke (manual)

After implementation, scroll the kitchen-sink list, drag the thumb, click
above and below it. Confirm the thumb follows the cursor smoothly, page
jumps land in the right direction, and the cursor swaps to vertical-resize
on hover.

## New dev-server endpoints

- `GET /scroll-info` — returns `{ <idx>: { total: N, off: N } }` for every
  scrollable container in the current frame. Mirrors the in-memory
  `node_scroll_info` map. Used by tests to assert post-action state.
- `GET /cursor` — returns `{ "kind": "default" | "pointing-hand" | "ibeam"
  | "resize-ns" | "resize-ew" | "resize-all" }` reflecting the current
  `rl.GetMouseCursor()` value. Used by `cursor-on-thumb-shows-resize`.

Both gate on `dev_mode` (`REDIN_DEV`); no production-binary surface.

## Documentation

- `docs/reference/theme.md`: document `:scrollbar` as a new aspect family
  with `#hover` and `#active` variants. Note that `:border-width` is the
  bar thickness.
- `docs/core-api.md`: extend the dev-server table with the two new
  endpoints (`/scroll-info`, `/cursor`).
- `CLAUDE.md`: same.

## Open questions

None that block writing the plan. Two judgment calls deferred to
implementation:

1. **Visual padding inside the gutter.** Current bar touches the
   container's right edge. Adding 2px right-padding makes the bar feel
   inset; not doing so keeps the bar flush. Defer to implementation
   review.
2. **Bar-drawn-but-not-interactive states.** If `total <= gutter_height`
   no bar is drawn (existing behaviour). Confirmed kept as-is — the
   scrollbar feature is no-op when content fits.
