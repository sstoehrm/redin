# NodeText selection / highlight — design

## Goal

Make plain `NodeText` selectable with the mouse, matching native text-widget behavior. Copy-to-clipboard via `Ctrl-C`. No editing.

Applies only to `NodeText` in v1. Cross-node selection (browser-style drag through multiple paragraphs) is out of scope. A single active selection exists across the whole app — either inside one `NodeInput` *or* inside one `NodeText*, never both.

## Public surface

### Attribute

```fennel
[:text {:selectable false} "…"]
```

`:selectable false` opts a text node out. No attribute = selectable (default-on). Applies only to `NodeText`.

### Theme

The `:selection` color property is already declared in `theme.fnl` and documented in `docs/reference/theme.md` but is not currently read by the Theme struct. This feature wires it up so that:

```fennel
{:body {:font-size 14 :color [40 40 40] :selection [255 220 0 120]}}
```

controls the selection highlight color for **both** `NodeInput` and `NodeText`. One knob, consistent look. Default when omitted: `[51 153 255 100]` — the color currently hardcoded in `render.odin`.

### Events

None. Selection is purely view-layer; apps do not observe it. `Ctrl-C` works without app involvement. If a future use case needs app-observable selection, a host function `redin.get_selection()` can be added then.

### Mouse cursor

I-beam (`rl.MouseCursor.IBEAM`) when hovering any selectable `NodeText`, otherwise default. Only set on transitions.

### Interactions

Standard text-widget mouse behavior. No keyboard focus or Tab order — all gestures originate from the mouse.

- Click-drag: select a range.
- Shift-click: extend the current selection to the click point.
- Double-click: select the word under the click.
- Triple-click: select the line (visual wrapped line) under the click.
- `Ctrl-A`: with an active text selection, expand to the full content of the selected node. No-op when there is no selection.
- `Ctrl-C`: copy selected text to clipboard.
- Clicking elsewhere (in whitespace or into a different node) clears the selection.

Out of scope for v1: `Shift+Arrow`, `Shift+Home/End`, auto-scroll when dragging past the viewport edge.

## State model

Extend the existing singleton `Input_State` in `src/host/input/state.odin`:

```odin
Selection_Kind :: enum { None, Input, Text }

Input_State :: struct {
    // existing fields: text, cursor, selection_start, selection_end,
    // scroll_offset_x/y, active, last_dispatched
    selection_kind: Selection_Kind,
    selection_path: []u8           // owned copy of types.Path.value,  // owned copy; empty when kind != Text
}
```

### Identity

- `kind == Input`: `selection_path` is empty. Byte offsets index the edit buffer. Behavior unchanged from today.
- `kind == Text`: `selection_path` pins a specific `NodeText` across re-flattens. Byte offsets index `nodes[resolved_idx].content`.

`focused_idx` today is idx-based and hit-tested every frame. Text selection cannot rely on a continuous hit-test — it is set once on mouse-down and held until cleared. Therefore path-based identity is required.

### Per-frame resolution

Before render, `input.resolve_text_selection(paths, nodes)` walks `paths[]` once, finds the slot whose stored path equals `state.selection_path`, and checks that slot is a `NodeText` with `len(content) >= selection_end`. If not found or invalidated, clear the selection. Runs only when `kind == Text`. O(n_nodes) per frame, bounded and cheap in practice.

### Mutual exclusion

- `focus_enter` (NodeInput clicked): sets `kind = None`, frees `selection_path`.
- `text_select_begin` (selectable NodeText clicked): sets `kind = Text`, sets `active = false`, stores a heap copy of the path.
- `has_selection()` stays as-is (checks offsets, agnostic to kind).
- `copy_selection()` branches on `kind` to source the substring from the right buffer.

### Lifetime

`selection_path` is heap-allocated when selection starts; freed when selection clears, when another selection replaces it, and in `state_destroy`.

## Gesture detection

New file: `src/host/input/text_select.odin`. Owns the click/drag state machine for selectable text. Mirrors how `edit.odin` isolates input-specific editing logic.

File-local state (not part of `Input_State`):

```odin
gesture: struct {
    anchor_offset: int,
    anchor_path:   []u8,    // owned copy of types.Path.value
    click_count:   int,   // 1 / 2 / 3; resets on timeout or node change
    last_click_t:  f64,
}
```

Entry points, called from the main `input` package on each frame (same layer that drives `apply.odin`):

- `text_select_on_mouse_down(pt, shift, nodes, paths, node_rects, theme)` — hit-tests selectable `NodeText`, converts `pt` to a byte offset via existing `text_pkg.compute_lines` and `input.x_to_cursor_in_line`, then starts / extends / promotes to word / promotes to line.
- `text_select_on_mouse_drag(pt, …)` — re-hits under the cursor, sets `state.selection_end`.
- `text_select_on_mouse_up()` — no-op in v1.
- `select_all` extended to check `kind == Text` and set offsets against node content length.

## Rendering

`render.odin` currently draws input-selection rects at lines 919–933. Refactor that block into a helper:

```odin
draw_selection_rects :: proc(lines: []Text_Line, lo, hi: int, rect: rl.Rectangle, color: rl.Color)
```

that iterates wrapped lines, clips the byte range to each line, and emits one `DrawRectangleRec` per line segment. Call it from two places:

1. `NodeInput` path — `kind == Input && is_focused`. (Same behavior as today after refactor.)
2. `NodeText` path — `kind == Text && resolved_text_idx == idx`. New.

The helper gives multi-line selection for `NodeText` for free, which wrapped text requires.

Selection color: resolve from theme via the new `:selection` property on the node's aspect. Fallback to current hardcoded default when unset.

## Listener extraction

Add a trivial `Text_Select_Listener { node_idx: int }` emitted by `input.extract_listeners` for every `NodeText` whose `selectable != false`. This gives the input package a pre-filtered candidate list for mouse events, matching how other listeners (click, hover, etc.) are structured, and avoids re-scanning all nodes during the mouse pipeline.

## Dev server

New endpoint for testability:

```
GET /selection
```

Response:

```json
{"kind":"text","text":"selected substring","start":12,"end":27,"path":[…]}
{"kind":"input","text":"input buffer selected substring","start":3,"end":9}
{"kind":"none"}
```

Read-only. No `PUT /selection`. Reusable for future inspection tools.

## Edge cases

| Case | Behavior |
|---|---|
| Re-flatten changes node idx | Path resolver finds new idx next frame; selection persists. |
| Selected node deleted, or content shrinks below `selection_end` | Resolver clears selection on next frame. |
| Drag past node bounds | Clamp offset to `[0, len(content)]`. No auto-scroll. |
| Click inside `:overflow :scroll-y` | Text-select gesture wins when landing on selectable text; wheel still scrolls (different event). |
| `:overflow :scroll-x` on text | Selection rects honor the existing per-node horizontal scroll offset. |
| Empty / whitespace-only content | Selectable but no visible rect. Harmless. |
| Button label (`[:button {} "…"]`) | Not a `NodeText`; not selectable. No conflict. |
| `Ctrl-A` with no active text selection | No-op for text. NodeInput behavior unchanged. |
| `Ctrl-A` during text selection | Expand to full node content. |
| Hotreload mid-selection | Path resolver clears if node is gone. |

## Testing

1. **`GET /selection` endpoint.** Required to make the UI test assertable.
2. **UI test** — `test/ui/text_select_app.fnl` + `test/ui/test_text_select.bb`:
   - Drag selects a range; `GET /selection` confirms substring.
   - `:selectable false` — drag produces no selection.
   - Shift-click extends.
   - Double-click selects word; triple-click selects line.
   - Mutual exclusion: starting a text selection after an input selection clears the input's; clicking an input clears a text selection.
   - `Ctrl-C` (injected key event) writes to clipboard — asserted via clipboard readback.
3. **Visual check.** Screenshot mid-drag; rects must align with glyphs. Screenshot a multi-line selection; one rect per wrapped line.
4. **Memory.** `--track-mem` across repeated select / clear / re-select — `selection_path` heap allocations must balance.
5. **Regression.** Existing `test_input`, `test_multiline`, `test_scroll`, `test_smoke` must still pass. The render-side refactor (extracting `draw_selection_rects`) keeps `NodeInput` visually identical.

## Out of scope

- Cross-node selection.
- Keyboard-driven selection in `NodeText` (`Shift+Arrow`, `Shift+Home/End`).
- Auto-scroll when dragging past a scroll container's viewport.
- App-observable selection events / host function.
- Per-node selection color overriding the aspect's theme `:selection`.
