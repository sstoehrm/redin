# Multiline Text & Input Design

Word-wrap and `\n` support for both text display (NodeText) and text editing (NodeInput). A shared text layout engine computes line breaks, consumed by both the renderer and input system.

## App-facing API

### NodeText

Text nodes gain word-wrap by default when width is constrained. Hard line breaks via `\n` in content are always respected.

```fennel
[:text {:aspect :body :width 300 :height 200} "Line one\nLine two with wrapping"]
[:text {:aspect :body :width 300 :height 200 :overflow :scroll-y} "Long content..."]
[:text {:aspect :code :overflow :scroll-x} "no-wrap long line..."]
```

- Default: word-wrap enabled, content clips at height boundary
- `overflow: scroll-y`: vertical scroll when lines exceed height
- `overflow: scroll-x`: no word-wrap, horizontal scroll for long lines
- No height set: auto-sizes to fit all lines

### NodeInput

Input nodes support multiline editing. ENTER inserts `\n`. Content word-wraps within the input width.

```fennel
[:input {:aspect :input :width 300 :height 120
         :value multi-line-val
         :change [:event/input-change]}]
```

- Fixed height from `:height` attr, vertical scroll when content overflows
- Word-wrap within available width (after padding)
- Cursor navigation: UP/DOWN move between visual lines, HOME/END go to line start/end
- Ctrl+HOME / Ctrl+END: start/end of entire text
- Click-to-position uses both X and Y coordinates
- Selection spans across lines with per-line highlight rectangles

## Text layout engine

New package `src/host/text/` with a single file `layout.odin`.

### Types

```odin
Text_Line :: struct {
    start: int,    // byte offset into source string (inclusive)
    end:   int,    // byte offset into source string (exclusive)
    width: f32,    // rendered pixel width of this line
}
```

### Functions

**`compute_lines(text: string, font: rl.Font, font_size: f32, spacing: f32, max_width: f32) -> [dynamic]Text_Line`**

Computes visual line breaks for a string.

Algorithm:
1. Walk through text character by character (UTF-8 aware)
2. On `\n`: emit current line (start to `\n` position), start new line after `\n`
3. On space: record as potential word-break point
4. When accumulated width exceeds `max_width`: break at last word boundary. If no word boundary exists (single word wider than line), break at character level.
5. If `max_width <= 0`: no wrapping, only break on `\n`

**`cursor_to_line(lines: []Text_Line, cursor: int) -> (line_idx: int, col_offset: int)`**

Maps a byte offset to a visual line index and byte offset within that line. Used by input rendering to determine cursor position.

**`point_to_cursor(lines: []Text_Line, text: string, x: f32, y: f32, font: rl.Font, font_size: f32, spacing: f32, line_height: f32, scroll_x: f32, scroll_y: f32) -> int`**

Maps a click position (relative to content area) to a byte offset. Uses Y to determine line index, then X to determine character position within that line. Accounts for scroll offsets.

## Host-side changes

### Node types (view_tree.odin)

Add `overflow: string` field to NodeText and NodeInput. Same type as NodeVbox/NodeHbox overflow field.

### Bridge parsing (bridge.odin)

Parse `overflow` attr for `"text"` and `"input"` node types in `lua_read_node`.

### Input state (state.odin)

Add `scroll_offset_y: f32` to `Input_State` alongside existing `scroll_offset` (rename existing to `scroll_offset_x` for clarity).

### Input editing (input.odin, edit.odin)

**New key handling:**
- ENTER: insert `\n` at cursor position, mark text as changed
- UP: compute current line from layout, move cursor to same X position on previous line
- DOWN: same, next line
- HOME: move to start of current visual line (not start of text)
- END: move to end of current visual line
- Ctrl+HOME: move to byte 0
- Ctrl+END: move to end of text

**Modified:**
- `move_home()` / `move_end()`: need the layout lines to find current line boundaries
- `click_to_cursor()`: needs Y coordinate and layout lines

**Vertical scroll management:**
- After each edit/cursor move, ensure cursor line is visible within the input height
- Scroll up/down to keep cursor in view, same pattern as horizontal scroll

### Rendering (render.odin)

**`draw_text` rewrite:**
1. Compute lines via `text.compute_lines()` with `max_width` = rect width (or 0 if `scroll-x`)
2. Compute `line_height` from font size (font_size + 4 or similar)
3. If `scroll-y`: apply scissor clip, track scroll offset per node (reuse `scroll_offsets` map)
4. If `scroll-x`: apply scissor clip, track horizontal scroll offset
5. Draw each line at `(rect.x - scroll_x, rect.y + line_idx * line_height - scroll_y)`

**`draw_input` rewrite:**
1. Compute lines via `text.compute_lines()` with `max_width` = content width
2. Draw each line, accounting for `scroll_offset_x` and `scroll_offset_y`
3. Selection: for each line that overlaps the selection range, draw a highlight rectangle spanning the selected portion of that line
4. Cursor: compute line and X offset from layout, draw cursor at `(content_x + x_offset - scroll_x, content_y + line_idx * line_height - scroll_y)`
5. Keep cursor visible: adjust `scroll_offset_y` so cursor line is within the visible area

### Scroll handling for text nodes

Text nodes with `overflow: scroll-y` or `overflow: scroll-x` need scroll state. Reuse the existing `scroll_offsets: map[int]f32` map in render.odin. For nodes needing both axes, add a second map `scroll_offsets_x: map[int]f32`.

Text node scrolling is driven by mouse wheel (same as vbox scroll-y). `apply_scroll_events` needs to handle text nodes with overflow.

## Files to modify/create

| File | Change |
|------|--------|
| `src/host/text/layout.odin` | New: text layout engine (compute_lines, cursor_to_line, point_to_cursor) |
| `src/host/types/view_tree.odin` | Add `overflow: string` to NodeText and NodeInput |
| `src/host/bridge/bridge.odin` | Parse `overflow` for text and input nodes |
| `src/host/input/state.odin` | Add `scroll_offset_y`, rename `scroll_offset` to `scroll_offset_x` |
| `src/host/input/edit.odin` | Line-aware home/end, enter-inserts-newline |
| `src/host/input/input.odin` | UP/DOWN navigation, line-aware HOME/END, multiline click-to-cursor |
| `src/host/render.odin` | Rewrite draw_text and draw_input for multiline, text node scroll |

## Not in scope

- Syntax highlighting
- Tab character handling (treat as regular character)
- Right-to-left text
- Text alignment within lines (left-aligned only)
- Auto-growing input height
