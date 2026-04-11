# Multiline Text & Input Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add word-wrap and `\n` support for text display and multiline editing for input, powered by a shared text layout engine.

**Architecture:** A new `text` package provides `compute_lines` which breaks a string into visual lines given a font and max width. Both `draw_text` and `draw_input` consume these lines. Input editing gains ENTER (newline), UP/DOWN (line navigation), and line-aware HOME/END. Scroll handling reuses the existing `scroll_offsets` map pattern.

**Tech Stack:** Odin, Raylib (text measurement/rendering), LuaJIT/Fennel (bridge)

**Spec:** `docs/superpowers/specs/2026-04-11-multiline-text-design.md`

---

## File Structure

| File | Responsibility |
|------|---------------|
| `src/host/text/layout.odin` | New: text layout engine — compute_lines, cursor_to_line, point_to_cursor |
| `src/host/types/view_tree.odin` | Add `overflow: string` to NodeText and NodeInput |
| `src/host/bridge/bridge.odin` | Parse `overflow` for text and input nodes |
| `src/host/input/state.odin` | Rename `scroll_offset` → `scroll_offset_x`, add `scroll_offset_y` |
| `src/host/input/edit.odin` | Line-aware move_home/move_end, new move_up/move_down |
| `src/host/input/input.odin` | ENTER inserts newline, UP/DOWN/HOME/END key handling, multiline click |
| `src/host/render.odin` | Rewrite draw_text and draw_input for multiline, text scroll |

---

### Task 1: Create text layout engine

**Files:**
- Create: `src/host/text/layout.odin`

- [ ] **Step 1: Create the text package with Text_Line and compute_lines**

Create `src/host/text/layout.odin`:

```odin
package text

import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

Text_Line :: struct {
	start: int, // byte offset inclusive
	end:   int, // byte offset exclusive
	width: f32, // rendered pixel width
}

// Measure pixel width of a substring.
measure_range :: proc(text: string, start: int, end: int, font_obj: rl.Font, font_size: f32, spacing: f32) -> f32 {
	if start >= end do return 0
	cstr := strings.clone_to_cstring(text[start:end], context.temp_allocator)
	return rl.MeasureTextEx(font_obj, cstr, font_size, spacing).x
}

// Compute visual line breaks for text with word-wrap and \n support.
// max_width <= 0 means no wrapping (only break on \n).
compute_lines :: proc(
	text: string,
	font_obj: rl.Font,
	font_size: f32,
	spacing: f32,
	max_width: f32,
) -> [dynamic]Text_Line {
	lines: [dynamic]Text_Line

	if len(text) == 0 {
		append(&lines, Text_Line{start = 0, end = 0, width = 0})
		return lines
	}

	line_start := 0
	last_space := -1        // byte offset of last space (word break point)
	last_space_width: f32 = 0 // line width up to (not including) last_space

	pos := 0
	for pos < len(text) {
		// Hard line break
		if text[pos] == '\n' {
			w := measure_range(text, line_start, pos, font_obj, font_size, spacing)
			append(&lines, Text_Line{start = line_start, end = pos, width = w})
			pos += 1
			line_start = pos
			last_space = -1
			continue
		}

		// Track word boundaries
		if text[pos] == ' ' {
			last_space = pos
			last_space_width = measure_range(text, line_start, pos, font_obj, font_size, spacing)
		}

		// Advance past this character
		_, size := utf8.decode_rune(transmute([]u8)text[pos:])
		next_pos := pos + size

		// Check if line exceeds max_width
		if max_width > 0 && next_pos > line_start {
			line_width := measure_range(text, line_start, next_pos, font_obj, font_size, spacing)
			if line_width > max_width && pos > line_start {
				if last_space >= line_start {
					// Break at last word boundary
					append(&lines, Text_Line{
						start = line_start,
						end   = last_space,
						width = last_space_width,
					})
					line_start = last_space + 1 // skip the space
					last_space = -1
				} else {
					// No word boundary — break at character level
					w := measure_range(text, line_start, pos, font_obj, font_size, spacing)
					append(&lines, Text_Line{start = line_start, end = pos, width = w})
					line_start = pos
					last_space = -1
				}
			}
		}

		pos = next_pos
	}

	// Emit final line
	w := measure_range(text, line_start, len(text), font_obj, font_size, spacing)
	append(&lines, Text_Line{start = line_start, end = len(text), width = w})

	return lines
}

// Map a byte offset (cursor) to a visual line index and byte offset within that line.
cursor_to_line :: proc(lines: []Text_Line, cursor: int) -> (line_idx: int, col_offset: int) {
	for i := 0; i < len(lines); i += 1 {
		line := lines[i]
		// Cursor is in this line if it's within [start, end],
		// or it's at end and this is the last line
		if cursor <= line.end || i == len(lines) - 1 {
			return i, cursor - line.start
		}
	}
	return len(lines) - 1, 0
}

// Map a click position (relative to content area top-left) to a byte offset.
// Accounts for scroll offsets.
point_to_cursor :: proc(
	lines: []Text_Line,
	text: string,
	x: f32,
	y: f32,
	font_obj: rl.Font,
	font_size: f32,
	spacing: f32,
	line_height: f32,
	scroll_x: f32,
	scroll_y: f32,
) -> int {
	if len(lines) == 0 do return 0

	// Determine which line was clicked
	adjusted_y := y + scroll_y
	line_idx := int(adjusted_y / line_height)
	if line_idx < 0 do line_idx = 0
	if line_idx >= len(lines) do line_idx = len(lines) - 1

	line := lines[line_idx]
	if line.start >= line.end do return line.start

	// Find character within line
	adjusted_x := x + scroll_x
	best_pos := line.start
	best_dist := abs(adjusted_x)

	pos := line.start
	for pos < line.end {
		_, size := utf8.decode_rune(transmute([]u8)text[pos:])
		pos += size
		w := measure_range(text, line.start, pos, font_obj, font_size, spacing)
		dist := abs(adjusted_x - w)
		if dist < best_dist {
			best_dist = dist
			best_pos = pos
		}
	}

	return best_pos
}

// Compute line height from font size (matches existing convention).
line_height :: proc(font_size: f32) -> f32 {
	return font_size + 4
}
```

- [ ] **Step 2: Build to verify**

Run: `odin build src/host -out:build/redin`
Expected: Build succeeds (new package compiled but not yet imported)

- [ ] **Step 3: Commit**

```bash
git add src/host/text/layout.odin
git commit -m "feat: add text layout engine with word-wrap and newline support"
```

---

### Task 2: Add overflow field to NodeText and NodeInput + bridge parsing

**Files:**
- Modify: `src/host/types/view_tree.odin` (NodeText, NodeInput)
- Modify: `src/host/bridge/bridge.odin` (text and input parsing in lua_read_node)

- [ ] **Step 1: Add overflow field to NodeText**

In `src/host/types/view_tree.odin`, add `overflow: string` to `NodeText` struct (after `height`):

```odin
NodeText :: struct {
	layoutX:  LayoutX,
	layoutY:  LayoutY,
	content:  string,
	aspect:   string,
	width:    union {
		SizeValue,
		f32,
	},
	height:   union {
		SizeValue,
		f32,
	},
	overflow: string,
}
```

- [ ] **Step 2: Add overflow field to NodeInput**

In `src/host/types/view_tree.odin`, add `overflow: string` to `NodeInput` struct (after `placeholder`):

```odin
NodeInput :: struct {
	change:      string,
	key:         string,
	aspect:      string,
	width:       union {
		SizeValue,
		f32,
	},
	height:      union {
		SizeValue,
		f32,
	},
	value:       string,
	placeholder: string,
	overflow:    string,
}
```

- [ ] **Step 3: Parse overflow for text nodes in bridge**

In `src/host/bridge/bridge.odin`, inside `lua_read_node`, in the `"text"` case, add after the existing height parsing:

```odin
			t.overflow = lua_get_string_field(L, attrs_idx, "overflow")
```

- [ ] **Step 4: Parse overflow for input nodes in bridge**

In the `"input"` case, add after `inp.placeholder`:

```odin
			inp.overflow = lua_get_string_field(L, attrs_idx, "overflow")
```

- [ ] **Step 5: Build to verify**

Run: `odin build src/host -out:build/redin`
Expected: Build succeeds

- [ ] **Step 6: Commit**

```bash
git add src/host/types/view_tree.odin src/host/bridge/bridge.odin
git commit -m "feat: add overflow attr to NodeText and NodeInput"
```

---

### Task 3: Update input state for multiline scroll

**Files:**
- Modify: `src/host/input/state.odin`
- Modify: `src/host/input/input.odin` (references to `scroll_offset`)
- Modify: `src/host/render.odin` (references to `state.scroll_offset`)

- [ ] **Step 1: Rename scroll_offset to scroll_offset_x and add scroll_offset_y**

In `src/host/input/state.odin`, change the struct:

```odin
Input_State :: struct {
	text:            [dynamic]u8,
	cursor:          int,
	selection_start: int,
	selection_end:   int,
	scroll_offset_x: f32,
	scroll_offset_y: f32,
	last_dispatched: string,
	active:          bool,
}
```

In `focus_enter`, update the reset:

```odin
	state.scroll_offset_x = 0
	state.scroll_offset_y = 0
```

- [ ] **Step 2: Update all references to scroll_offset**

In `src/host/input/input.odin`, find `state.scroll_offset` and replace with `state.scroll_offset_x`. There should be one reference around line 259:

```odin
					click_x := e.x - rect.x - padding_l + state.scroll_offset_x
```

In `src/host/render.odin`, in `draw_input`, find all references to `input.state.scroll_offset` and replace with `input.state.scroll_offset_x`. There should be references around lines 546-547 and 551-556:

```odin
	if is_focused && input.state.active {
		scroll_offset = input.state.scroll_offset_x
	}
```

And the cursor scroll management around lines 551-556:

```odin
			input.state.scroll_offset_x -= (content_x - cursor_x) + 10
			if input.state.scroll_offset_x < 0 do input.state.scroll_offset_x = 0
			cursor_x = content_x + cursor_x_offset - input.state.scroll_offset_x
		} else if cursor_x > content_x + content_w - 2 {
			input.state.scroll_offset_x += (cursor_x - (content_x + content_w - 2)) + 10
			cursor_x = content_x + cursor_x_offset - input.state.scroll_offset_x
```

- [ ] **Step 3: Build to verify**

Run: `odin build src/host -out:build/redin`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add src/host/input/state.odin src/host/input/input.odin src/host/render.odin
git commit -m "refactor: rename scroll_offset to scroll_offset_x, add scroll_offset_y"
```

---

### Task 4: Rewrite draw_text for multiline

**Files:**
- Modify: `src/host/render.odin` (draw_text proc, apply_scroll_events, scroll_offsets_x map)

- [ ] **Step 1: Add scroll_offsets_x map for horizontal scroll**

In `src/host/render.odin`, after the existing `scroll_offsets: map[int]f32` declaration (around line 34), add:

```odin
scroll_offsets_x: map[int]f32
```

- [ ] **Step 2: Rewrite draw_text to use text layout engine**

Replace the entire `draw_text` proc (lines 657-678) with:

```odin
draw_text :: proc(idx: int, rect: rl.Rectangle, n: types.NodeText, theme: map[string]types.Theme) {
	if len(n.content) == 0 do return

	font_size: f32 = 18
	text_color := rl.BLACK
	font_name := "sans"
	font_weight: u8 = 0

	if len(n.aspect) > 0 {
		if t, ok := theme[n.aspect]; ok {
			if t.font_size > 0 do font_size = f32(t.font_size)
			if t.color != {} do text_color = rl.Color{t.color[0], t.color[1], t.color[2], 255}
			if len(t.font) > 0 do font_name = t.font
			font_weight = t.weight
		}
	}

	f := font.get(font_name, font.style_from_weight(font.Font_Weight(font_weight)))
	spacing: f32 = 0
	lh := text_pkg.line_height(font_size)

	// Compute lines: wrap if not scroll-x
	max_width: f32 = 0
	if n.overflow != "scroll-x" {
		max_width = rect.width
	}
	lines := text_pkg.compute_lines(n.content, f, font_size, spacing, max_width)
	defer delete(lines)

	scrollable_y := n.overflow == "scroll-y"
	scrollable_x := n.overflow == "scroll-x"

	scroll_y: f32 = 0
	scroll_x: f32 = 0
	if scrollable_y {
		scroll_y = scroll_offsets[idx] if idx in scroll_offsets else 0
		total_h := f32(len(lines)) * lh
		max_scroll := total_h - rect.height
		if max_scroll < 0 do max_scroll = 0
		if scroll_y > max_scroll do scroll_y = max_scroll
		if scroll_y < 0 do scroll_y = 0
		scroll_offsets[idx] = scroll_y
	}
	if scrollable_x {
		scroll_x = scroll_offsets_x[idx] if idx in scroll_offsets_x else 0
	}

	if scrollable_y || scrollable_x {
		rl.BeginScissorMode(i32(rect.x), i32(rect.y), i32(rect.width), i32(rect.height))
	}

	for line, i in lines {
		ly := rect.y + f32(i) * lh - scroll_y
		// Skip lines outside visible area
		if ly + lh < rect.y do continue
		if ly > rect.y + rect.height do break

		if line.start < line.end {
			cstr := strings.clone_to_cstring(n.content[line.start:line.end], context.temp_allocator)
			rl.DrawTextEx(f, cstr, {px(rect.x - scroll_x), px(ly)}, font_size, spacing, text_color)
		}
	}

	if scrollable_y || scrollable_x {
		rl.EndScissorMode()
	}
}
```

**Note:** This adds an `idx: int` parameter to `draw_text`. Update the call site in `render_node` (around line 169) from:

```odin
	case types.NodeText:
		draw_text(rect, n, theme)
```

To:

```odin
	case types.NodeText:
		draw_text(idx, rect, n, theme)
```

Also add the import for the text package at the top of render.odin. Since both packages are named `text`, use an alias:

```odin
import text_pkg "text"
```

- [ ] **Step 3: Update apply_scroll_events to handle text nodes**

In the `apply_scroll_events` proc (around line 38), add NodeText to the overflow detection switch:

```odin
				case types.NodeText:
					overflow = n.overflow
```

This goes inside the switch block that currently checks NodeVbox and NodeHbox.

- [ ] **Step 4: Build to verify**

Run: `odin build src/host -out:build/redin`
Expected: Build succeeds

- [ ] **Step 5: Verify manually**

Run: `./build/redin examples/kitchen-sink.fnl`
Expected: Text elements render correctly (single-line text should look the same as before).

- [ ] **Step 6: Commit**

```bash
git add src/host/render.odin
git commit -m "feat: rewrite draw_text for multiline with word-wrap and scroll"
```

---

### Task 5: Add ENTER key and UP/DOWN/HOME/END line navigation to input

**Files:**
- Modify: `src/host/input/edit.odin` (new procs: move_up, move_down, line-aware home/end)
- Modify: `src/host/input/input.odin` (key handling)

- [ ] **Step 1: Add line-aware movement procs to edit.odin**

Add these procs at the end of `src/host/input/edit.odin`, before the `ordered_remove_range` proc:

```odin
// --- Line-aware movement (requires layout lines) ---

import text_pkg "../text"

// Move cursor up one visual line, preserving X position.
move_up :: proc(lines: []text_pkg.Text_Line, text_str: string, font_obj: rl.Font, font_size: f32, sp: f32, shift: bool) {
	old_cursor := state.cursor
	line_idx, _ := text_pkg.cursor_to_line(lines, state.cursor)
	if line_idx <= 0 {
		// Already on first line — move to start of text
		state.cursor = 0
	} else {
		// Get X position of cursor on current line
		cur_line := lines[line_idx]
		x := text_pkg.measure_range(text_str, cur_line.start, state.cursor, font_obj, font_size, sp)
		// Find matching position on previous line
		prev_line := lines[line_idx - 1]
		state.cursor = x_to_cursor_in_line(text_str, prev_line, x, font_obj, font_size, sp)
	}
	if shift {
		start_or_extend_selection(old_cursor, state.cursor)
	} else {
		clear_selection()
	}
}

// Move cursor down one visual line, preserving X position.
move_down :: proc(lines: []text_pkg.Text_Line, text_str: string, font_obj: rl.Font, font_size: f32, sp: f32, shift: bool) {
	old_cursor := state.cursor
	line_idx, _ := text_pkg.cursor_to_line(lines, state.cursor)
	if line_idx >= len(lines) - 1 {
		// Already on last line — move to end of text
		state.cursor = len(state.text)
	} else {
		cur_line := lines[line_idx]
		x := text_pkg.measure_range(text_str, cur_line.start, state.cursor, font_obj, font_size, sp)
		next_line := lines[line_idx + 1]
		state.cursor = x_to_cursor_in_line(text_str, next_line, x, font_obj, font_size, sp)
	}
	if shift {
		start_or_extend_selection(old_cursor, state.cursor)
	} else {
		clear_selection()
	}
}

// Move cursor to start of current visual line.
move_home_line :: proc(lines: []text_pkg.Text_Line, shift: bool) {
	old_cursor := state.cursor
	line_idx, _ := text_pkg.cursor_to_line(lines, state.cursor)
	state.cursor = lines[line_idx].start
	if shift {
		start_or_extend_selection(old_cursor, state.cursor)
	} else {
		clear_selection()
	}
}

// Move cursor to end of current visual line.
move_end_line :: proc(lines: []text_pkg.Text_Line, shift: bool) {
	old_cursor := state.cursor
	line_idx, _ := text_pkg.cursor_to_line(lines, state.cursor)
	state.cursor = lines[line_idx].end
	if shift {
		start_or_extend_selection(old_cursor, state.cursor)
	} else {
		clear_selection()
	}
}

// Find the byte offset in a line closest to a given X pixel position.
x_to_cursor_in_line :: proc(text_str: string, line: text_pkg.Text_Line, target_x: f32, font_obj: rl.Font, font_size: f32, sp: f32) -> int {
	if line.start >= line.end do return line.start
	best_pos := line.start
	best_dist := abs(target_x)

	pos := line.start
	for pos < line.end {
		_, size := utf8.decode_rune(transmute([]u8)text_str[pos:])
		pos += size
		w := text_pkg.measure_range(text_str, line.start, pos, font_obj, font_size, sp)
		dist := abs(target_x - w)
		if dist < best_dist {
			best_dist = dist
			best_pos = pos
		}
	}
	return best_pos
}
```

- [ ] **Step 2: Update key handling in input.odin for ENTER, UP, DOWN, HOME, END**

In `src/host/input/input.odin`, the `process_user_events` proc needs access to layout lines for line-aware navigation. Add a text layout computation at the start of the focused input processing block (after `controlled_sync`), and update the key handling.

After the `controlled_sync(n.value)` call (around line 182), add:

```odin
		// Compute text layout for multiline navigation
		inp_font := font.get(
			n.aspect != "" ? (theme[n.aspect].font if n.aspect in theme else "sans") : "sans",
			font.style_from_weight(0),
		)
		inp_font_size: f32 = 14
		if n.aspect != "" {
			if t, ok := theme[n.aspect]; ok && t.font_size > 0 {
				inp_font_size = f32(t.font_size)
			}
		}
		inp_spacing: f32 = 0
		// Width for wrapping: use node rect minus padding
		inp_padding_l: f32 = 4
		inp_padding_r: f32 = 4
		if n.aspect != "" {
			if t, ok := theme[n.aspect]; ok {
				if t.padding[3] > 0 do inp_padding_l = f32(t.padding[3])
				if t.padding[1] > 0 do inp_padding_r = f32(t.padding[1])
			}
		}
		inp_content_w: f32 = 0
		if focused_idx >= 0 && focused_idx < len(node_rects) {
			inp_content_w = node_rects[focused_idx].width - inp_padding_l - inp_padding_r
		}
		text_str := get_text()
		layout_lines := text_pkg.compute_lines(text_str, inp_font, inp_font_size, inp_spacing, inp_content_w)
		defer delete(layout_lines)
```

Add the import at the top of input.odin:

```odin
import text_pkg "../text"
import "font" // TODO: check if font is already imported or needs "../font"
```

**Note:** Check the actual import path. The input package is at `src/host/input/`, font is at `src/host/font/`. The import should be `import font "../font"`.

Then update the key handling switch. Add ENTER before the existing BACKSPACE case:

```odin
			case .ENTER:
				insert_char('\n')
				text_changed = true
```

Add UP and DOWN cases after the existing RIGHT case:

```odin
			case .UP:
				move_up(layout_lines[:], text_str, inp_font, inp_font_size, inp_spacing, e.mods.shift)
			case .DOWN:
				move_down(layout_lines[:], text_str, inp_font, inp_font_size, inp_spacing, e.mods.shift)
```

Replace the existing HOME and END cases:

```odin
			case .HOME:
				if e.mods.ctrl {
					move_home(e.mods.shift) // existing: go to text start
				} else {
					move_home_line(layout_lines[:], e.mods.shift)
				}
			case .END:
				if e.mods.ctrl {
					move_end(e.mods.shift) // existing: go to text end
				} else {
					move_end_line(layout_lines[:], e.mods.shift)
				}
```

- [ ] **Step 3: Update click-to-cursor for multiline**

In `process_user_events`, replace the mouse click handling (around lines 252-266):

```odin
		case types.MouseEvent:
			if focused_idx >= 0 && focused_idx < len(node_rects) {
				rect := node_rects[focused_idx]
				pt := rl.Vector2{e.x, e.y}
				if rl.CheckCollisionPointRec(pt, rect) {
					click_x := e.x - rect.x - inp_padding_l
					click_y := e.y - rect.y
					lh := text_pkg.line_height(inp_font_size)
					state.cursor = text_pkg.point_to_cursor(
						layout_lines[:], text_str,
						click_x, click_y,
						inp_font, inp_font_size, inp_spacing, lh,
						state.scroll_offset_x, state.scroll_offset_y,
					)
					clear_selection()
				}
			}
```

- [ ] **Step 4: Build to verify**

Run: `odin build src/host -out:build/redin`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add src/host/input/edit.odin src/host/input/input.odin
git commit -m "feat: add multiline input editing — ENTER, UP/DOWN, line-aware HOME/END"
```

---

### Task 6: Rewrite draw_input for multiline rendering

**Files:**
- Modify: `src/host/render.odin` (draw_input proc)

- [ ] **Step 1: Rewrite draw_input**

Replace the entire `draw_input` proc in `src/host/render.odin` (lines 478-617). The new version:

1. Computes lines via `text_pkg.compute_lines`
2. Draws each text line at the correct Y position
3. Renders selection highlights as per-line rectangles
4. Renders cursor at the correct line and X position
5. Manages vertical scroll to keep cursor visible

```odin
draw_input :: proc(
	idx: int,
	rect: rl.Rectangle,
	n: types.NodeInput,
	theme: map[string]types.Theme,
) {
	is_focused := input.focused_idx == idx

	border_color := rl.DARKGRAY
	bg_color := rl.Color{0, 0, 0, 0}
	text_color := rl.WHITE
	placeholder_color := rl.Color{128, 128, 128, 128}
	selection_color := rl.Color{51, 153, 255, 100}
	font_size: f32 = 14
	padding_l: f32 = 4
	padding_r: f32 = 4
	padding_t: f32 = 4
	border_width: f32 = 1
	font_name := "sans"
	font_weight: u8 = 0

	if len(n.aspect) > 0 {
		if t, ok := theme[n.aspect]; ok {
			if t.border != {} do border_color = rl.Color{t.border[0], t.border[1], t.border[2], 255}
			if t.bg != {} do bg_color = rl.Color{t.bg[0], t.bg[1], t.bg[2], 255}
			if t.color != {} do text_color = rl.Color{t.color[0], t.color[1], t.color[2], 255}
			if t.font_size > 0 do font_size = f32(t.font_size)
			if t.border_width > 0 do border_width = f32(t.border_width)
			if t.padding[3] > 0 do padding_l = f32(t.padding[3])
			if t.padding[1] > 0 do padding_r = f32(t.padding[1])
			if t.padding[0] > 0 do padding_t = f32(t.padding[0])
			if len(t.font) > 0 do font_name = t.font
			font_weight = t.weight
		}
		if is_focused {
			focus_key := strings.concatenate({n.aspect, "#focus"}, context.temp_allocator)
			if ft, ok := theme[focus_key]; ok {
				if ft.border != {} do border_color = rl.Color{ft.border[0], ft.border[1], ft.border[2], 255}
			}
		}
	}

	// Draw background and border
	if bg_color.a > 0 do rl.DrawRectangleRec(rect, bg_color)
	rl.DrawRectangleLinesEx(rect, border_width, border_color)

	// Content area
	content_x := rect.x + padding_l
	content_y := rect.y + padding_t
	content_w := rect.width - padding_l - padding_r
	content_h := rect.height - padding_t * 2

	f := font.get(font_name, font.style_from_weight(font.Font_Weight(font_weight)))
	spacing: f32 = 0
	lh := text_pkg.line_height(font_size)

	// Determine text to display
	display_text: string
	show_placeholder := false
	if is_focused && input.state.active {
		display_text = input.get_text()
	} else if len(n.value) > 0 {
		display_text = n.value
	} else if len(n.placeholder) > 0 {
		display_text = n.placeholder
		show_placeholder = true
	}

	// Compute lines
	lines := text_pkg.compute_lines(display_text, f, font_size, spacing, content_w)
	defer delete(lines)

	// Vertical scroll management (keep cursor visible)
	scroll_y: f32 = 0
	if is_focused && input.state.active {
		scroll_y = input.state.scroll_offset_y
		cursor_line, _ := text_pkg.cursor_to_line(lines[:], input.state.cursor)
		cursor_y_top := f32(cursor_line) * lh
		cursor_y_bot := cursor_y_top + lh

		if cursor_y_top < scroll_y {
			scroll_y = cursor_y_top
		} else if cursor_y_bot > scroll_y + content_h {
			scroll_y = cursor_y_bot - content_h
		}
		if scroll_y < 0 do scroll_y = 0
		input.state.scroll_offset_y = scroll_y
	}

	// Scissor clip to content area
	rl.BeginScissorMode(i32(content_x), i32(content_y), i32(content_w), i32(content_h))

	// Draw selection highlight (behind text)
	if is_focused && input.state.active && input.has_selection() {
		lo, hi := input.selection_range()
		for line, i in lines {
			ly := content_y + f32(i) * lh - scroll_y
			if ly + lh < content_y || ly > content_y + content_h do continue

			// Determine selection overlap with this line
			sel_start := max(lo, line.start)
			sel_end := min(hi, line.end)
			if sel_start >= sel_end do continue

			x0 := text_pkg.measure_range(display_text, line.start, sel_start, f, font_size, spacing)
			x1 := text_pkg.measure_range(display_text, line.start, sel_end, f, font_size, spacing)
			sel_rect := rl.Rectangle{content_x + x0, ly, x1 - x0, lh}
			rl.DrawRectangleRec(sel_rect, selection_color)
		}
	}

	// Draw text lines
	color := show_placeholder ? placeholder_color : text_color
	for line, i in lines {
		ly := content_y + f32(i) * lh - scroll_y
		if ly + lh < content_y do continue
		if ly > content_y + content_h do break

		if line.start < line.end {
			cstr := strings.clone_to_cstring(display_text[line.start:line.end], context.temp_allocator)
			rl.DrawTextEx(f, cstr, {px(content_x), px(ly)}, font_size, spacing, color)
		}
	}

	// Draw cursor
	if is_focused && input.state.active {
		cursor_line, _ := text_pkg.cursor_to_line(lines[:], input.state.cursor)
		cur_line := lines[cursor_line]
		cursor_x_offset := text_pkg.measure_range(
			display_text, cur_line.start, input.state.cursor, f, font_size, spacing,
		)
		cursor_x := content_x + cursor_x_offset
		cursor_y := content_y + f32(cursor_line) * lh - scroll_y

		// Cursor blink animation (reuse existing wipe animation)
		cycle := f32(rl.GetTime()) * 0.4
		phase := cycle - f32(i32(cycle))
		wave: f32
		if phase < 0.5 {
			wave = phase * 2
		} else {
			wave = (1 - phase) * 2
		}

		CURSOR_SLICES :: 8
		slice_h := lh / f32(CURSOR_SLICES)
		for s in 0 ..< i32(CURSOR_SLICES) {
			norm := 1.0 - (f32(s) + 0.5) / f32(CURSOR_SLICES)
			alpha_norm := clamp(wave * 2.0 - norm, 0, 1)
			alpha := u8(alpha_norm * f32(text_color.a))
			slice_y := cursor_y + f32(s) * slice_h
			c := rl.Color{text_color.r, text_color.g, text_color.b, alpha}
			rl.DrawLineEx(
				rl.Vector2{cursor_x, slice_y},
				rl.Vector2{cursor_x, slice_y + slice_h},
				1.5,
				c,
			)
		}
	}

	rl.EndScissorMode()
}
```

**Note:** This adds `idx: int` as the first parameter. Update the call site in `render_node` (around line 166) from:

```odin
	case types.NodeInput:
		draw_input(idx, rect, n, theme)
```

This should already match since the existing call passes `idx`.

- [ ] **Step 2: Build to verify**

Run: `odin build src/host -out:build/redin`
Expected: Build succeeds

- [ ] **Step 3: Test manually**

Run: `./build/redin examples/kitchen-sink.fnl`
Expected: Input fields render correctly. Type text that wraps. Press ENTER to create newlines. Use UP/DOWN arrows to navigate lines.

- [ ] **Step 4: Commit**

```bash
git add src/host/render.odin
git commit -m "feat: rewrite draw_input for multiline rendering with scroll"
```

---

### Task 7: Write test app and UI tests

**Files:**
- Create: `test/ui/multiline_app.fnl`
- Create: `test/ui/test_multiline.bb`

- [ ] **Step 1: Write test app**

Create `test/ui/multiline_app.fnl`:

```fennel
;; Test app for multiline text and input
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:surface {:bg [46 52 64] :padding [24 24 24 24]}
   :body    {:font-size 14 :color [216 222 233]}
   :input   {:bg [59 66 82] :color [236 239 244]
             :border [76 86 106] :border-width 1
             :radius 4 :padding [8 12 8 12] :font-size 14}
   :input#focus {:border [136 192 208]}})

(dataflow.init
  {:input-value "Line one\nLine two\nLine three"
   :static-text "Word wrap test: The quick brown fox jumps over the lazy dog. This text should wrap at the container boundary."
   :newline-text "First\nSecond\nThird"})

(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :event/input-change
  (fn [db event]
    (let [ctx (. event 2)]
      (assoc db :input-value (or ctx.value "")))))

(reg-handler :event/reset
  (fn [db event]
    (assoc db :input-value "Line one\nLine two\nLine three")))

(reg-sub :input-value (fn [db] (get db :input-value "")))
(reg-sub :static-text (fn [db] (get db :static-text "")))
(reg-sub :newline-text (fn [db] (get db :newline-text "")))

(global main_view
  (fn []
    (let [input-val (subscribe :input-value)
          static (subscribe :static-text)
          newline (subscribe :newline-text)]
      [:vbox {:aspect :surface}
       [:text {:id :wrap-text :aspect :body :width 200} static]
       [:text {:id :newline-text :aspect :body :width 200} newline]
       [:text {:id :scroll-text :aspect :body :width 200 :height 40 :overflow :scroll-y} static]
       [:input {:id :test-input :aspect :input :width 250 :height 80
                :value input-val
                :change [:event/input-change]}]
       [:text {:id :current-value :aspect :body} (.. "value:" input-val)]])))
```

- [ ] **Step 2: Write UI tests**

Create `test/ui/test_multiline.bb`:

```clojure
(require '[redin-test :refer :all])

;; -- Text display --

(deftest wrap-text-exists
  (assert-element {:tag :text :id :wrap-text}))

(deftest newline-text-exists
  (assert-element {:tag :text :id :newline-text}))

;; -- Input multiline --

(deftest input-has-multiline-value
  (let [state (get-state "input-value")]
    (assert (clojure.string/includes? state "\n")
            "Input value should contain newline")))

(deftest input-change-preserves-newlines
  (dispatch ["event/reset"])
  (wait-ms 200)
  (let [state (get-state "input-value")]
    (assert (= state "Line one\nLine two\nLine three")
            (str "Expected multiline value, got: " state))))

(deftest input-change-with-newline
  (dispatch ["event/input-change" {:value "hello\nworld"}])
  (wait-ms 200)
  (assert-state "input-value" #(= % "hello\nworld") "Value should contain newline"))

;; -- Reset --

(deftest reset-restores-multiline
  (dispatch ["event/input-change" {:value "changed"}])
  (wait-ms 100)
  (dispatch ["event/reset"])
  (wait-for (state= "input-value" "Line one\nLine two\nLine three") {:timeout 2000}))
```

- [ ] **Step 3: Build, start dev server, run tests**

```bash
odin build src/host -out:build/redin
./build/redin --dev test/ui/multiline_app.fnl &
sleep 2
bb test/ui/run.bb test/ui/test_multiline.bb
curl -s -X POST http://localhost:8800/shutdown
```

Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add test/ui/multiline_app.fnl test/ui/test_multiline.bb
git commit -m "test: add multiline text and input UI tests"
```

---

### Task 8: Final verification

- [ ] **Step 1: Run Fennel runtime tests**

Run: `luajit test/lua/runner.lua test/lua/test_*.fnl`
Expected: All tests pass

- [ ] **Step 2: Build check**

Run: `odin build src/host -out:build/redin`
Expected: Clean build

- [ ] **Step 3: Run drag-and-drop tests (regression)**

```bash
./build/redin --dev test/ui/drag_app.fnl &
sleep 2
bb test/ui/run.bb test/ui/test_drag.bb
curl -s -X POST http://localhost:8800/shutdown
```

Expected: All 7 drag tests still pass
