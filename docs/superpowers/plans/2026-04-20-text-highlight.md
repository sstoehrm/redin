# NodeText selection / highlight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make plain `NodeText` selectable by mouse with the same highlight, click-drag, shift-click, double/triple-click and Ctrl-C behavior users expect from native text widgets. Read the spec at `docs/superpowers/specs/2026-04-20-text-highlight-design.md`.

**Architecture:** Extend the existing singleton `input.state` with a `Selection_Kind` tag and a path-keyed anchor so selections survive view re-flattens. A new `input/text_select.odin` owns the mouse gesture state machine. `render.odin`'s existing input-selection rect block is factored into a shared helper and called for both `NodeInput` and `NodeText`. The `:selection` theme property (already declared but unread) gets plumbed end-to-end as the color source, defaulting to today's hardcoded blue when unset. A read-only `GET /selection` dev-server endpoint makes the UI tests assertable.

**Tech Stack:** Odin (host), raylib (rendering + mouse/keyboard), LuaJIT (bridge), Fennel (test apps), Babashka (UI test harness).

**Branch:** Work happens on `feat/text-highlight` (already checked out). All tasks land on this branch, final PR merges to `main`.

---

## File structure

| File | Role | Action |
|---|---|---|
| `src/host/types/theme.odin` | `Theme` struct | **modify** — add `selection: [4]u8` |
| `src/host/bridge/bridge.odin` | Lua → Theme parsing | **modify** — parse `selection` RGBA, add `lua_get_rgba_field` helper |
| `src/host/parser/theme_parser.odin` | EDN → Theme parsing (test fixtures) | **modify** — parse `selection` key |
| `src/host/parser/theme_parser_test.odin` | EDN theme parser tests | **modify** — add selection coverage |
| `src/host/input/state.odin` | `Input_State` | **modify** — add `Selection_Kind`, `selection_kind`, `selection_path` |
| `src/host/input/state_test.odin` | Selection-state unit tests | **create** |
| `src/host/input/text_select.odin` | NodeText gesture + path resolver | **create** |
| `src/host/input/text_select_test.odin` | Gesture unit tests | **create** |
| `src/host/input/edit.odin` | `copy_selection`, `select_all` | **modify** — branch by kind |
| `src/host/input/apply.odin` | Focus-enter side effects | **modify** — clear text selection when an input gains focus |
| `src/host/input/input.odin` | Main input entrypoint + listener extraction | **modify** — emit `Text_Select_Listener`, drive gesture each frame, set I-beam cursor |
| `src/host/types/listeners.odin` | Listener union | **modify** — add `Text_Select_Listener` |
| `src/host/render.odin` | Selection rect rendering | **modify** — extract `draw_selection_rects`, call for both kinds, read theme color |
| `src/host/bridge/devserver.odin` | Dev-server routing | **modify** — add `GET /selection` |
| `test/ui/text_select_app.fnl` | UI test app | **create** |
| `test/ui/test_text_select.bb` | UI test | **create** |
| `docs/reference/theme.md` | Theme property reference | **modify** — note `:selection` now wired end-to-end |
| `docs/reference/elements.md` | `:selectable` attribute | **modify** — document it on NodeText |
| `.claude/skills/redin-dev/SKILL.md` | Skill theme + node list | **modify** — mention `:selectable`, `:selection` |

---

## Task 1: Add `selection` field to `Theme` struct and parse it (Lua + EDN paths)

**Files:**
- Modify: `src/host/types/theme.odin:10-23`
- Modify: `src/host/bridge/bridge.odin:1150-1193` (`lua_to_theme`)
- Create: `src/host/bridge/bridge.odin:1195-1210` (new `lua_get_rgba_field` near the existing `lua_get_rgb_field`)
- Modify: `src/host/parser/theme_parser.odin` (EDN parser — grep for where `:color` is parsed, add `:selection` alongside)
- Modify: `src/host/parser/theme_parser_test.odin`

- [ ] **Step 1: Write the failing theme-parser test**

Add to `src/host/parser/theme_parser_test.odin`:

```odin
@(test)
test_parse_theme_selection :: proc(t: ^testing.T) {
	input := `{:body {:selection [255 220 0 120]}}`
	theme, ok := _parse_theme_string(input)
	defer {
		for k in theme do delete(k)
		delete(theme)
	}
	testing.expect(t, ok, "parse should succeed")
	body := theme["body"]
	testing.expect_value(t, body.selection, [4]u8{255, 220, 0, 120})
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `odin test src/host/parser`
Expected: `selection` field not declared on `types.Theme` → compile error.

- [ ] **Step 3: Add `selection` field to `Theme` struct**

In `src/host/types/theme.odin`, after `shadow:       Shadow,` add:

```odin
	selection:    [4]u8,   // RGBA; {0,0,0,0} = unset, use default
```

- [ ] **Step 4: Make the EDN parser populate it**

In `src/host/parser/theme_parser.odin` find the block that reads `:color` into the Theme (grep for `"color"` and a 3-byte rgb parse). Right after the `color` case add a `selection` case that consumes a 4-element RGBA vector. (The parser already has 3-byte rgb and 4-byte shadow-color helpers; reuse the 4-byte path.)

- [ ] **Step 5: Re-run the parser test**

Run: `odin test src/host/parser`
Expected: all 25 tests pass (24 existing + 1 new).

- [ ] **Step 6: Add the Lua → Theme path**

In `src/host/bridge/bridge.odin` add a new helper near `lua_get_rgb_field`:

```odin
lua_get_rgba_field :: proc(L: ^Lua_State, index: i32, field: cstring) -> [4]u8 {
	lua_getfield(L, index, field)
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) do return {}
	abs := lua_gettop(L)
	out: [4]u8
	for i in 0 ..< 4 {
		lua_rawgeti(L, abs, i32(i + 1))
		out[i] = u8(lua_tonumber(L, -1))
		lua_pop(L, 1)
	}
	return out
}
```

Then inside `lua_to_theme`, right after `t.shadow = lua_get_shadow_field(...)`, add:

```odin
t.selection = lua_get_rgba_field(L, props_idx, "selection")
```

- [ ] **Step 7: Build + verify nothing broke**

Run:
```
odin build src/host -out:build/redin
odin test src/host/parser
```
Expected: clean build, 25 parser tests pass.

- [ ] **Step 8: Commit**

```
git add src/host/types/theme.odin src/host/bridge/bridge.odin src/host/parser/theme_parser.odin src/host/parser/theme_parser_test.odin
git commit -m "feat(theme): plumb :selection rgba property into Theme struct"
```

---

## Task 2: Use themed selection color in `NodeInput` (no behavior change, just replace the hardcoded constant)

**Files:**
- Modify: `src/host/render.odin:837` (the hardcoded constant) and the block at 919–933 that references it

- [ ] **Step 1: Read the existing block**

Open `src/host/render.odin` and locate (near line 837):

```odin
selection_color := rl.Color{51, 153, 255, 100}
```

and the rendering block (near 919–933) which references `selection_color`.

- [ ] **Step 2: Replace with theme lookup + fallback**

Replace the `selection_color := ...` line with:

```odin
// Theme selection color; fall back to the legacy blue when unset.
selection_color := rl.Color{51, 153, 255, 100}
if len(n.aspect) > 0 {
	if aspect, ok := theme[n.aspect]; ok {
		if aspect.selection != ([4]u8{}) {
			selection_color = rl.Color{
				aspect.selection[0], aspect.selection[1],
				aspect.selection[2], aspect.selection[3],
			}
		}
	}
}
```

(`n` here is the bound `NodeInput`; `theme` is already in scope — check the function signature; it's passed through `draw_input`.)

- [ ] **Step 3: Build**

Run: `odin build src/host -out:build/redin`
Expected: clean.

- [ ] **Step 4: Regression UI test**

```
bash test/ui/run-all.sh 2>&1 | grep -E "^Running:|^Results:|test suite"
```
Expected: all suites report `0 failed`. `test_input` in particular must still pass.

- [ ] **Step 5: Commit**

```
git add src/host/render.odin
git commit -m "feat(render): source NodeInput selection color from theme :selection"
```

---

## Task 3: Extract `draw_selection_rects` helper (prep for NodeText reuse)

**Files:**
- Modify: `src/host/render.odin` (extract the existing multi-line rect code into a reusable proc)

- [ ] **Step 1: Read the existing rendering block**

Locate the block (currently ~lines 919–933) that iterates wrapped lines and emits `DrawRectangleRec` for each line segment.

- [ ] **Step 2: Extract a helper**

Add (near the other `draw_*` helpers in `render.odin`):

```odin
// Draw one selection rect per wrapped line, clipping the [lo, hi) byte range
// against each line's byte span. rect is the text node's content rect (pre-
// scrolled). Assumes `lines` are the result of text_pkg.compute_lines for the
// same text + width.
draw_selection_rects :: proc(
	lines: []text_pkg.Text_Line,
	text: string,
	lo, hi: int,
	font_obj: rl.Font,
	font_size, spacing, line_height: f32,
	rect: rl.Rectangle,
	color: rl.Color,
) {
	if lo >= hi do return
	for line, i in lines {
		line_lo := max(lo, line.start)
		line_hi := min(hi, line.end)
		if line_lo >= line_hi do continue
		x0 := text_pkg.measure_range(text, line.start, line_lo, font_obj, font_size, spacing)
		x1 := text_pkg.measure_range(text, line.start, line_hi, font_obj, font_size, spacing)
		y := rect.y + f32(i) * line_height
		rl.DrawRectangleRec(rl.Rectangle{rect.x + x0, y, x1 - x0, line_height}, color)
	}
}
```

- [ ] **Step 3: Replace the inlined block with a call to the helper**

In the `NodeInput` draw path, replace the existing for-loop over lines with:

```odin
draw_selection_rects(lines, text, lo, hi, font_obj, font_size, spacing, lh, content_rect, selection_color)
```

(Variable names come from the surrounding code — match them.)

- [ ] **Step 4: Build + regression**

```
odin build src/host -out:build/redin
bash test/ui/run-all.sh 2>&1 | grep -E "^Results:|test suite"
```
Expected: clean build; all existing UI suites pass; `test_input` visually unchanged.

- [ ] **Step 5: Commit**

```
git add src/host/render.odin
git commit -m "refactor(render): extract draw_selection_rects helper"
```

---

## Task 4: Add `Selection_Kind` + `selection_path` to `Input_State`

**Files:**
- Modify: `src/host/input/state.odin`
- Create: `src/host/input/state_test.odin`

- [ ] **Step 1: Write the failing unit test**

Create `src/host/input/state_test.odin`:

```odin
package input

import "core:testing"
import "../types"

@(test)
test_set_text_selection_stores_path_copy :: proc(t: ^testing.T) {
	state_init()
	defer state_destroy()

	// Caller-owned buffer; we expect state to copy it.
	src := []u8{0x01, 0x02, 0x03, 0x04}
	set_text_selection(src, 2, 5)

	testing.expect_value(t, state.selection_kind, Selection_Kind.Text)
	testing.expect_value(t, state.selection_start, 2)
	testing.expect_value(t, state.selection_end, 5)
	testing.expect_value(t, len(state.selection_path), 4)

	// Mutate source — state should be unaffected.
	src[0] = 0xFF
	testing.expect_value(t, state.selection_path[0], u8(0x01))
}

@(test)
test_clear_text_selection_frees_path :: proc(t: ^testing.T) {
	state_init()
	defer state_destroy()

	src := []u8{0x10, 0x20}
	set_text_selection(src, 0, 0)
	clear_text_selection()

	testing.expect_value(t, state.selection_kind, Selection_Kind.None)
	testing.expect_value(t, len(state.selection_path), 0)
}

@(test)
test_focus_enter_clears_text_selection :: proc(t: ^testing.T) {
	state_init()
	defer state_destroy()
	set_text_selection([]u8{0xAA}, 0, 1)
	focus_enter("buf")
	testing.expect_value(t, state.selection_kind, Selection_Kind.None)
	testing.expect_value(t, len(state.selection_path), 0)
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `odin test src/host/input`
Expected: `Selection_Kind`, `set_text_selection`, `clear_text_selection` not defined.

- [ ] **Step 3: Extend `Input_State`**

In `src/host/input/state.odin`, replace the struct with:

```odin
Selection_Kind :: enum u8 { None, Input, Text }

Input_State :: struct {
	text:            [dynamic]u8,
	cursor:          int,
	selection_start: int,
	selection_end:   int,
	selection_kind:  Selection_Kind,
	selection_path:  [dynamic]u8,   // owned copy of types.Path.value
	scroll_offset_x: f32,
	scroll_offset_y: f32,
	last_dispatched: string,
	active:          bool,
}
```

- [ ] **Step 4: Initialize / clean up**

In `state_init`:

```odin
state.selection_start = -1
state.selection_end = -1
state.selection_kind = .None
```

In `state_destroy`:

```odin
delete(state.text)
delete(state.selection_path)
if len(state.last_dispatched) > 0 {
	delete(state.last_dispatched)
}
```

- [ ] **Step 5: Add the new helpers to `state.odin`**

```odin
// Take ownership of a text-node selection.
set_text_selection :: proc(path: []u8, lo, hi: int) {
	clear(&state.selection_path)
	append(&state.selection_path, ..path)
	state.selection_kind = .Text
	state.selection_start = lo
	state.selection_end = hi
}

clear_text_selection :: proc() {
	clear(&state.selection_path)
	state.selection_kind = .None
	state.selection_start = -1
	state.selection_end = -1
}

// Convenience query used by copy / render.
text_selection_path :: proc() -> []u8 {
	return state.selection_path[:]
}
```

- [ ] **Step 6: Update `focus_enter` to clear any text selection**

In `focus_enter`, before `state.active = true`:

```odin
clear_text_selection()
state.selection_kind = .Input
```

- [ ] **Step 7: Run tests**

Run: `odin test src/host/input`
Expected: 3 tests pass.

- [ ] **Step 8: Rebuild host to catch struct-change fallout**

Run: `odin build src/host -out:build/redin`
Expected: clean.

- [ ] **Step 9: Commit**

```
git add src/host/input/state.odin src/host/input/state_test.odin
git commit -m "feat(input): add Selection_Kind + selection_path to Input_State"
```

---

## Task 5: Branch `copy_selection` and `has_selection` by kind; keep `NodeInput` semantics

**Files:**
- Modify: `src/host/input/edit.odin` (`copy_selection`, `select_all`)
- Modify: `src/host/input/state.odin` (`has_selection` — check kind)
- Modify: `src/host/input/state_test.odin`

- [ ] **Step 1: Add a failing test**

Append to `src/host/input/state_test.odin`:

```odin
@(test)
test_copy_selection_for_text_uses_node_content :: proc(t: ^testing.T) {
	state_init()
	defer state_destroy()

	// Pretend the resolver ran and exposed node content via an input parameter.
	set_text_selection([]u8{0x01}, 3, 8)
	got := copy_selection_source_text("the quick brown fox")
	testing.expect_value(t, got, " qui")
}
```

- [ ] **Step 2: Implement the source-text query in `edit.odin`**

```odin
// Returns the substring implied by the current selection, sourced either from
// the edit buffer (Input kind) or the caller-supplied node content (Text kind).
// Empty string when no selection is active.
copy_selection_source_text :: proc(node_content: string) -> string {
	if !has_selection() do return ""
	lo, hi := selection_range()
	switch state.selection_kind {
	case .Input:
		return string(state.text[lo:hi])
	case .Text:
		if hi > len(node_content) do hi = len(node_content)
		if lo >= hi do return ""
		return node_content[lo:hi]
	case .None:
		return ""
	}
	return ""
}
```

- [ ] **Step 3: Branch `copy_selection` itself**

Replace the body of `copy_selection`:

```odin
// Copy the active selection to the system clipboard.
// Caller provides the read-only source for Text-kind selections.
copy_selection :: proc(node_content_for_text: string = "") {
	src := copy_selection_source_text(node_content_for_text)
	if len(src) == 0 do return
	cstr := strings.clone_to_cstring(src, context.temp_allocator)
	rl.SetClipboardText(cstr)
}
```

(Call sites in `edit.odin` that don't pass a value — e.g. inside `cut_selection` — default to `""`, which is fine because cut is only valid for `.Input` kind where the buffer is the source.)

- [ ] **Step 4: Run tests**

Run: `odin test src/host/input`
Expected: 4 pass.

- [ ] **Step 5: Commit**

```
git add src/host/input/state.odin src/host/input/edit.odin src/host/input/state_test.odin
git commit -m "feat(input): branch copy_selection by Selection_Kind"
```

---

## Task 6: Add `Text_Select_Listener` and extract-selectable-texts

**Files:**
- Modify: `src/host/types/listeners.odin` (find with `grep -n "Listener :: union" src/host/types`)
- Modify: `src/host/input/input.odin` (`extract_listeners`)

- [ ] **Step 1: Find the Listener union**

Run: `grep -n "Listener :: union\|ClickListener\|KeyListener" src/host/types/*.odin`

- [ ] **Step 2: Add the new listener type**

Next to `ClickListener` (or wherever node-indexed listeners live), add:

```odin
// Emitted for every NodeText whose :selectable attribute is not false.
// Consumed by input/text_select.odin.
Text_Select_Listener :: struct {
	node_idx: int,
}
```

And add `Text_Select_Listener,` to the `Listener :: union { … }` list.

- [ ] **Step 3: Add the `:selectable` attribute to NodeText**

Search: `grep -n "NodeText ::" src/host/types/view_tree.odin`. Add a `selectable: bool` field (default `false` will be the "selectable=false" case — we want default-on, so invert semantics: field name `selectable_off` or keep `selectable` default-true by having the parser default it).

The cleanest path: add `not_selectable: bool` (zero-value = selectable, matches default-on behavior without initialization elsewhere).

```odin
NodeText :: struct {
	// existing fields …
	not_selectable: bool,
}
```

- [ ] **Step 4: Parse `:selectable` in the bridge**

Search: `grep -n "NodeText{" src/host/bridge/bridge.odin`. In the `:text` attribute parse block (look near the NodeText construction), add:

```odin
// default true (zero-value = selectable); only the explicit false flips it
sel := lua_get_bool_field(L, attrs_idx, "selectable", true)
txt.not_selectable = !sel
```

(If a `lua_get_bool_field` with default doesn't exist, follow the pattern of the nearby bool fields and write a local fallback.)

- [ ] **Step 5: Emit the listener in `extract_listeners`**

Search: `grep -n "extract_listeners" src/host/input/input.odin`. Inside the per-node loop, after the existing listener emissions for `NodeInput`, add a case for `NodeText`:

```odin
case types.NodeText:
	if !n.not_selectable {
		append(&listeners, types.Listener(types.Text_Select_Listener{node_idx = idx}))
	}
```

- [ ] **Step 6: Build**

Run: `odin build src/host -out:build/redin`
Expected: clean.

- [ ] **Step 7: Commit**

```
git add src/host/types/ src/host/bridge/bridge.odin src/host/input/input.odin
git commit -m "feat(input): add :selectable attr + Text_Select_Listener"
```

---

## Task 7: `text_select.odin` skeleton — mouse-down starts a selection

**Files:**
- Create: `src/host/input/text_select.odin`
- Modify: `src/host/input/input.odin` (call the new dispatcher each frame)

- [ ] **Step 1: Create the module**

```odin
package input

import rl "vendor:raylib"
import "../types"
import text_pkg "../text"
import "../font"

@(private)
gesture: struct {
	anchor_offset: int,
	anchor_path:   [dynamic]u8,
	click_count:   int,
	last_click_t:  f64,
	active_drag:   bool,
}

// Entry called from the input pipeline each frame, AFTER focus/drag have run
// but BEFORE listener-based click dispatch fires.
process_text_selection :: proc(
	input_events: []types.InputEvent,
	listeners: []types.Listener,
	nodes: []types.Node,
	paths: []types.Path,
	node_rects: []rl.Rectangle,
	theme: map[string]types.Theme,
) {
	mouse := rl.GetMousePosition()

	// Phase A: new mouse-down on a selectable text
	for event in input_events {
		me, is_mouse := event.(types.MouseEvent)
		if !is_mouse || me.button != .LEFT do continue
		pt := rl.Vector2{me.x, me.y}

		hit := false
		for listener in listeners {
			tl, ok := listener.(types.Text_Select_Listener)
			if !ok do continue
			if tl.node_idx >= len(node_rects) do continue
			if !rl.CheckCollisionPointRec(pt, node_rects[tl.node_idx]) do continue

			text_node, is_text := nodes[tl.node_idx].(types.NodeText)
			if !is_text do continue

			offset := node_byte_offset_at(text_node, node_rects[tl.node_idx], pt, theme)

			// Copy path and record anchor.
			clear(&gesture.anchor_path)
			append(&gesture.anchor_path, ..paths[tl.node_idx].value[:paths[tl.node_idx].length])
			gesture.anchor_offset = offset
			gesture.active_drag = true

			set_text_selection(gesture.anchor_path[:], offset, offset)
			// Clear any input focus — mutual exclusion.
			focused_idx = -1
			state.active = false
			hit = true
			break
		}

		// Click-elsewhere-to-clear. If this mouse-down didn't land on
		// selectable text AND didn't start an input focus (focus_enter
		// handles that path), drop any existing text selection.
		if !hit && state.selection_kind == .Text {
			clear_text_selection()
		}
	}

	// Phase B: drag extension (Task 8)
	// Phase C: mouse-up (Task 8)
	_ = mouse
}

// Map a point inside a NodeText's rect to a byte offset in its content.
// Uses the wrapped-line layout + existing x_to_cursor_in_line helper.
@(private)
node_byte_offset_at :: proc(
	n: types.NodeText,
	rect: rl.Rectangle,
	pt: rl.Vector2,
	theme: map[string]types.Theme,
) -> int {
	if len(n.content) == 0 do return 0

	font_size: f32 = 18
	font_name := "sans"
	font_weight: u8 = 0
	lh_ratio: f32 = 0
	if len(n.aspect) > 0 {
		if t, ok := theme[n.aspect]; ok {
			if t.font_size > 0 do font_size = f32(t.font_size)
			if len(t.font) > 0 do font_name = t.font
			font_weight = t.weight
			lh_ratio = t.line_height
		}
	}
	f := font.get(font_name, font.style_from_weight(font.Font_Weight(font_weight)))
	spacing := max(font_size / 10, 1)
	lh := text_pkg.line_height(font_size, lh_ratio)

	lines := text_pkg.compute_lines(n.content, f, font_size, 0, rect.width)
	defer delete(lines)

	rel_y := pt.y - rect.y
	line_idx := int(rel_y / lh)
	if line_idx < 0 do line_idx = 0
	if line_idx >= len(lines) do line_idx = len(lines) - 1
	line := lines[line_idx]

	return x_to_cursor_in_line(n.content, line, pt.x - rect.x, f, font_size, spacing)
}

// Exposed for tests.
text_selection_anchor_path :: proc() -> []u8 {
	return gesture.anchor_path[:]
}
```

- [ ] **Step 2: Hook it into the main input pipeline**

In `src/host/main.odin` (or wherever `input.apply_focus` / `input.process_drag` is called — check with `grep -n "process_drag\|apply_focus" src/host/main.odin`), add a call:

```odin
input.process_text_selection(input_events, listeners[:], b.nodes, b.paths, node_rects[:], b.theme)
```

right after the drag pass.

- [ ] **Step 3: Build**

Run: `odin build src/host -out:build/redin`
Expected: clean.

- [ ] **Step 4: Smoke test**

Start the input test app, click into the window but NOT on an input:
```
./build/redin --dev test/ui/input_app.fnl &
sleep 2
curl -s -X POST http://localhost:$(cat .redin-port)/click -d '{"x":50,"y":50}'
curl -s -X POST http://localhost:$(cat .redin-port)/shutdown
```
Expected: no crash. (No visual assertion yet — that comes with rendering in Task 9.)

- [ ] **Step 5: Commit**

```
git add src/host/input/text_select.odin src/host/main.odin
git commit -m "feat(input): text_select gesture module with mouse-down handling"
```

---

## Task 8: Drag extension + mouse-up in the gesture state machine

**Files:**
- Modify: `src/host/input/text_select.odin`

- [ ] **Step 1: Add drag / release logic**

Inside `process_text_selection`, after the Phase-A loop, add:

```odin
// Phase B: drag extension while LMB is held.
if gesture.active_drag && rl.IsMouseButtonDown(.LEFT) {
	// Find the node whose path matches our anchor.
	idx := find_node_by_path(paths, gesture.anchor_path[:])
	if idx < 0 || idx >= len(node_rects) {
		// Node vanished — give up.
		gesture.active_drag = false
	} else {
		text_node, is_text := nodes[idx].(types.NodeText)
		if is_text {
			rect := node_rects[idx]
			offset := node_byte_offset_at(text_node, rect, mouse, theme)
			state.selection_end = offset
			if offset == gesture.anchor_offset {
				state.selection_start = -1
				state.selection_end = -1
			} else {
				state.selection_start = gesture.anchor_offset
			}
		}
	}
}

// Phase C: mouse released — stop tracking drags.
if gesture.active_drag && !rl.IsMouseButtonDown(.LEFT) {
	gesture.active_drag = false
}
```

- [ ] **Step 2: Add the path resolver**

Still in `text_select.odin`:

```odin
// Find the node whose path value equals `p`. Returns -1 if not found.
// (Intentionally exported — devserver's /selection handler reuses it.)
find_node_by_path :: proc(paths: []types.Path, p: []u8) -> int {
	for i in 0 ..< len(paths) {
		if int(paths[i].length) != len(p) do continue
		match := true
		for j in 0 ..< len(p) {
			if paths[i].value[j] != p[j] {
				match = false
				break
			}
		}
		if match do return i
	}
	return -1
}
```

- [ ] **Step 3: Build**

Run: `odin build src/host -out:build/redin`
Expected: clean.

- [ ] **Step 4: Commit**

```
git add src/host/input/text_select.odin
git commit -m "feat(input): drag-extend + release in text selection"
```

---

## Task 9: Render `NodeText` selection rects + read theme `:selection`

**Files:**
- Modify: `src/host/render.odin` (text draw path; resolve selection by path, call `draw_selection_rects`)

- [ ] **Step 1: Locate `draw_text` / the NodeText draw branch**

Run: `grep -n "NodeText\|draw_text" src/host/render.odin | head`.

- [ ] **Step 2: In the NodeText draw block, add selection rendering before glyphs**

Just before the glyph loop (so the rect is under the text), add:

```odin
if input.state.selection_kind == .Text {
	// Compare stored path to this node's path.
	if paths[idx].length > 0 &&
	   int(paths[idx].length) == len(input.state.selection_path) {
		match := true
		for j in 0 ..< int(paths[idx].length) {
			if paths[idx].value[j] != input.state.selection_path[j] {
				match = false
				break
			}
		}
		if match && input.has_selection() {
			lo, hi := input.selection_range()
			if hi > len(n.content) do hi = len(n.content)

			sel_color := rl.Color{51, 153, 255, 100}
			if len(n.aspect) > 0 {
				if aspect, ok := theme[n.aspect]; ok {
					if aspect.selection != ([4]u8{}) {
						sel_color = rl.Color{
							aspect.selection[0], aspect.selection[1],
							aspect.selection[2], aspect.selection[3],
						}
					}
				}
			}
			draw_selection_rects(
				lines, n.content, lo, hi,
				font_obj, font_size, spacing, lh,
				content_rect, sel_color,
			)
		}
	}
}
```

(Use the variable names that already exist in the surrounding draw block — `lines`, `n`, `content_rect`, `font_obj`, `font_size`, `spacing`, `lh`.)

- [ ] **Step 3: Build**

Run: `odin build src/host -out:build/redin`
Expected: clean.

- [ ] **Step 4: Manual smoke**

```
./build/redin --dev test/ui/multiline_app.fnl &
sleep 2
# Click at the start of the text
curl -s -X POST http://localhost:$(cat .redin-port)/click -d '{"x":100,"y":100}'
curl -s http://localhost:$(cat .redin-port)/screenshot > /tmp/sel-smoke.png
curl -s -X POST http://localhost:$(cat .redin-port)/shutdown
```

Open `/tmp/sel-smoke.png` — a zero-width selection won't render a rect, but the process must not crash.

- [ ] **Step 5: Commit**

```
git add src/host/render.odin
git commit -m "feat(render): draw selection rects for NodeText"
```

---

## Task 10: Per-frame selection resolver — drop stale paths, clamp offsets

**Files:**
- Modify: `src/host/input/text_select.odin` (add `resolve_text_selection`)
- Modify: `src/host/main.odin` (call it once per frame after bridge, before layout)

- [ ] **Step 1: Add the resolver**

In `src/host/input/text_select.odin`:

```odin
// Called once per frame after bridge updates `nodes` / `paths`.
// If the selected path no longer resolves to a NodeText, or the content
// has shrunk below selection_end, clear the selection.
resolve_text_selection :: proc(paths: []types.Path, nodes: []types.Node) {
	if state.selection_kind != .Text do return
	idx := find_node_by_path(paths, state.selection_path[:])
	if idx < 0 {
		clear_text_selection()
		return
	}
	text_node, is_text := nodes[idx].(types.NodeText)
	if !is_text {
		clear_text_selection()
		return
	}
	if state.selection_end > len(text_node.content) {
		clear_text_selection()
	}
}
```

- [ ] **Step 2: Call it from main**

In `src/host/main.odin` after `bridge.render_tick(&b)` returns (right where the main loop learns about the latest frame), add:

```odin
input.resolve_text_selection(b.paths, b.nodes)
```

- [ ] **Step 3: Build**

Run: `odin build src/host -out:build/redin`
Expected: clean.

- [ ] **Step 4: Commit**

```
git add src/host/input/text_select.odin src/host/main.odin
git commit -m "feat(input): per-frame resolver clears stale text selections"
```

---

## Task 11: Double-click (word) + triple-click (line) + shift-click (extend)

**Files:**
- Modify: `src/host/input/text_select.odin`

- [ ] **Step 1: Add click-count tracking in Phase A**

Extend Phase A in `process_text_selection` (before calling `set_text_selection`):

```odin
now := rl.GetTime()
if now - gesture.last_click_t < 0.4 && gesture.click_count > 0 {
	gesture.click_count += 1
	if gesture.click_count > 3 do gesture.click_count = 3
} else {
	gesture.click_count = 1
}
gesture.last_click_t = now
```

- [ ] **Step 2: Branch by click count**

Replace the plain `set_text_selection(gesture.anchor_path[:], offset, offset)` with:

```odin
lo, hi := offset, offset
switch gesture.click_count {
case 2:
	lo = prev_word(text_node.content[:], offset)
	hi = next_word(text_node.content[:], offset)
case 3:
	// Expand to the whole wrapped line at `offset`.
	lines := text_pkg.compute_lines(
		text_node.content,
		resolve_font(text_node, theme),
		resolve_font_size(text_node, theme),
		0, node_rects[tl.node_idx].width,
	)
	defer delete(lines)
	idx, _ := text_pkg.cursor_to_line(lines, offset)
	lo = lines[idx].start
	hi = lines[idx].end
}
gesture.anchor_offset = lo
set_text_selection(gesture.anchor_path[:], lo, hi)
```

Write two small private helpers (`resolve_font`, `resolve_font_size`) at the bottom of the file — factored from `node_byte_offset_at`:

```odin
@(private)
resolve_font :: proc(n: types.NodeText, theme: map[string]types.Theme) -> rl.Font {
	font_name := "sans"
	font_weight: u8 = 0
	if len(n.aspect) > 0 {
		if t, ok := theme[n.aspect]; ok {
			if len(t.font) > 0 do font_name = t.font
			font_weight = t.weight
		}
	}
	return font.get(font_name, font.style_from_weight(font.Font_Weight(font_weight)))
}

@(private)
resolve_font_size :: proc(n: types.NodeText, theme: map[string]types.Theme) -> f32 {
	if len(n.aspect) > 0 {
		if t, ok := theme[n.aspect]; ok {
			if t.font_size > 0 do return f32(t.font_size)
		}
	}
	return 18
}
```

(Refactor `node_byte_offset_at` to call these instead of duplicating the resolution logic.)

- [ ] **Step 3: Shift-click extension**

Still in Phase A, before the click-count block, read the mouse-event mods:

```odin
if me.mods.shift && state.selection_kind == .Text {
	// Extend existing selection to the new offset.
	idx := find_node_by_path(paths, gesture.anchor_path[:])
	if idx == tl.node_idx {
		state.selection_end = offset
		gesture.active_drag = true
		return
	}
}
```

- [ ] **Step 4: Build + manual smoke**

```
odin build src/host -out:build/redin
./build/redin --dev test/ui/multiline_app.fnl &
sleep 2
# (visual check via screenshot if desired)
curl -s -X POST http://localhost:$(cat .redin-port)/shutdown
```

- [ ] **Step 5: Commit**

```
git add src/host/input/text_select.odin
git commit -m "feat(input): word / line / shift-click selection gestures"
```

---

## Task 12: Ctrl-A on active text selection + Ctrl-C copy

**Files:**
- Modify: `src/host/input/edit.odin` (`select_all`)
- Modify: `src/host/input/input.odin` (keyboard dispatch when text selection is active)

- [ ] **Step 1: Extend `select_all`**

Replace the existing `select_all` body:

```odin
select_all :: proc(text_node_content: string = "") {
	switch state.selection_kind {
	case .Input:
		state.selection_start = 0
		state.selection_end = len(state.text)
		state.cursor = len(state.text)
	case .Text:
		if len(text_node_content) == 0 do return
		state.selection_start = 0
		state.selection_end = len(text_node_content)
	case .None:
	}
}
```

- [ ] **Step 2: Wire Ctrl-A / Ctrl-C when the kind is Text**

In `src/host/input/input.odin` find the key-event dispatch path for Ctrl-A and Ctrl-C (grep for `copy_selection\|select_all`). Currently it only fires when an input is focused. Split into two paths: inputs use today's logic; when `state.selection_kind == .Text`, resolve the selected NodeText and pass its `content` in:

```odin
if state.selection_kind == .Text {
	idx := find_node_by_path(b_paths, state.selection_path[:])
	content := ""
	if idx >= 0 {
		if tn, ok := b_nodes[idx].(types.NodeText); ok do content = tn.content
	}
	if ke.mods.ctrl && ke.key == .A do select_all(content)
	if ke.mods.ctrl && ke.key == .C do copy_selection(content)
}
```

(Variable names depend on the surrounding context — keep them consistent with the caller.)

- [ ] **Step 3: Build**

Run: `odin build src/host -out:build/redin`
Expected: clean.

- [ ] **Step 4: Commit**

```
git add src/host/input/edit.odin src/host/input/input.odin
git commit -m "feat(input): Ctrl-A / Ctrl-C for NodeText selection"
```

---

## Task 13: I-beam cursor on hover

**Files:**
- Modify: `src/host/input/input.odin` (one pass during input poll)

- [ ] **Step 1: Add the cursor pass**

After the listeners loop in the main input entry point, add:

```odin
set_hover_cursor :: proc(listeners: []types.Listener, node_rects: []rl.Rectangle) {
	mouse := rl.GetMousePosition()
	for listener in listeners {
		tl, ok := listener.(types.Text_Select_Listener)
		if !ok do continue
		if tl.node_idx >= len(node_rects) do continue
		if rl.CheckCollisionPointRec(mouse, node_rects[tl.node_idx]) {
			rl.SetMouseCursor(.IBEAM)
			return
		}
	}
	rl.SetMouseCursor(.DEFAULT)
}
```

Call it from the main loop (after `process_text_selection` returns):

```odin
input.set_hover_cursor(listeners[:], node_rects[:])
```

- [ ] **Step 2: Build + manual check**

Run: `odin build src/host -out:build/redin && ./build/redin examples/kitchen-sink.fnl`
Expected: cursor becomes an I-beam when hovering any text; default elsewhere.

- [ ] **Step 3: Commit**

```
git add src/host/input/input.odin src/host/main.odin
git commit -m "feat(input): I-beam cursor on selectable text hover"
```

---

## Task 14: `GET /selection` dev-server endpoint

**Files:**
- Modify: `src/host/bridge/devserver.odin` (route + handler)

- [ ] **Step 1: Add the route**

Near the existing `GET /aspects` route (around line 364), add:

```odin
} else if req.path == "/selection" {
	handle_get_selection(ds, ch)
}
```

- [ ] **Step 2: Implement the handler**

At the bottom of the GET handlers section:

```odin
handle_get_selection :: proc(ds: ^Dev_Server, ch: ^Response_Channel) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	kind := input.state.selection_kind
	switch kind {
	case .None:
		fmt.sbprintf(&b, `{{"kind":"none"}}`)
	case .Input:
		if !input.has_selection() {
			fmt.sbprintf(&b, `{{"kind":"none"}}`)
		} else {
			lo, hi := input.selection_range()
			text := input.copy_selection_source_text("")
			fmt.sbprintf(&b, `{{"kind":"input","start":%d,"end":%d,"text":%q}}`, lo, hi, text)
		}
	case .Text:
		if !input.has_selection() {
			fmt.sbprintf(&b, `{{"kind":"none"}}`)
		} else {
			lo, hi := input.selection_range()
			// Resolve path to find the node content.
			idx := -1
			for i in 0 ..< len(ds.bridge.paths) {
				p := ds.bridge.paths[i]
				if int(p.length) != len(input.state.selection_path) do continue
				match := true
				for j in 0 ..< int(p.length) {
					if p.value[j] != input.state.selection_path[j] {
						match = false; break
					}
				}
				if match { idx = i; break }
			}
			content := ""
			if idx >= 0 {
				if tn, ok := ds.bridge.nodes[idx].(types.NodeText); ok {
					content = tn.content
				}
			}
			sub := ""
			if hi <= len(content) { sub = content[lo:hi] }
			fmt.sbprintf(&b, `{{"kind":"text","start":%d,"end":%d,"text":%q}}`, lo, hi, sub)
		}
	}
	respond_json(ch, strings.to_string(b))
}
```

(`input` import is already present in `devserver.odin` — if not, `import "../input"` and `import "../types"`.)

- [ ] **Step 3: Build + smoke**

```
odin build src/host -out:build/redin
./build/redin --dev examples/kitchen-sink.fnl &
sleep 2
curl -s http://localhost:$(cat .redin-port)/selection
curl -s -X POST http://localhost:$(cat .redin-port)/shutdown
```
Expected: `{"kind":"none"}` (no selection yet).

- [ ] **Step 4: Commit**

```
git add src/host/bridge/devserver.odin
git commit -m "feat(devserver): GET /selection endpoint"
```

---

## Task 15: Tests — UI + Odin

**Testability note.** `process_text_selection` reads the live mouse state via `rl.IsMouseButtonDown(.LEFT)` each frame (same pattern as `drag.odin`). Raylib's mouse state is not driven by the `MouseEvent` queue, so `POST /click` can't synthesize a *sustained* drag — it fires a single press event and the next frame sees the button as up. Therefore:

- **UI test (Babashka + `/click`, `/selection`):** click-based paths only — single click sets a zero-width selection on the target node, double/triple-click rapid POSTs trigger word/line promotion via `rl.GetTime()`, opt-out suppresses the click effect, clicking an input clears a prior text selection, `GET /selection` returns the expected shape.
- **Odin unit test (no raylib):** path-matching (`find_node_by_path`), per-frame resolver clear-on-disappear / clear-on-shrink, `select_all(.Text, content)` offset math, `copy_selection_source_text` for both kinds. These exercise the pure logic without driving a window.
- **Drag extension + shift-click held-button path:** not covered automatically. Spot-check manually at the end (Task 16, Step 3). If future CI needs drag, a later change can add a synthetic-mouse mode gated behind `--dev`.

**Files:**
- Create: `src/host/input/text_select_test.odin`
- Create: `test/ui/text_select_app.fnl`
- Create: `test/ui/test_text_select.bb`

- [ ] **Step 1: Write the Odin unit tests**

Create `src/host/input/text_select_test.odin`:

```odin
package input

import "core:testing"
import "../types"

@(test)
test_find_node_by_path_returns_match :: proc(t: ^testing.T) {
	p0 := [2]u8{0x01, 0x02}
	p1 := [3]u8{0x0A, 0x0B, 0x0C}
	paths := []types.Path{
		{value = p0[:], length = 2},
		{value = p1[:], length = 3},
	}
	testing.expect_value(t, find_node_by_path(paths, []u8{0x0A, 0x0B, 0x0C}), 1)
	testing.expect_value(t, find_node_by_path(paths, []u8{0x01, 0x02}), 0)
	testing.expect_value(t, find_node_by_path(paths, []u8{0xFF}), -1)
}

@(test)
test_resolve_clears_when_path_missing :: proc(t: ^testing.T) {
	state_init()
	defer state_destroy()
	set_text_selection([]u8{0xAA}, 0, 3)

	empty: []types.Path
	empty_nodes: []types.Node
	resolve_text_selection(empty, empty_nodes)
	testing.expect_value(t, state.selection_kind, Selection_Kind.None)
}

@(test)
test_resolve_clears_when_content_shrinks :: proc(t: ^testing.T) {
	state_init()
	defer state_destroy()

	p := [1]u8{0x01}
	paths := []types.Path{{value = p[:], length = 1}}
	nodes := []types.Node{types.NodeText{content = "hi"}}
	set_text_selection([]u8{0x01}, 0, 5)  // 5 > len("hi") → stale
	resolve_text_selection(paths, nodes)
	testing.expect_value(t, state.selection_kind, Selection_Kind.None)
}
```

Run: `odin test src/host/input`
Expected: all input tests pass (the 4 from Task 4-5 plus these 3).

- [ ] **Step 2: Write the app**

`test/ui/text_select_app.fnl`:

```fennel
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:surface {:bg [46 52 64] :padding [24 24 24 24]}
   :body    {:font-size 16 :color [236 239 244]
             :selection [255 220 0 120]}
   :locked  {:font-size 16 :color [180 180 180]}
   :input   {:bg [59 66 82] :color [236 239 244]
             :border [76 86 106] :border-width 1
             :radius 4 :padding [8 12 8 12] :font-size 14}})

(dataflow.init {:input-value "preset"})
(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :event/input-change
  (fn [db event]
    (let [ctx (. event 2)]
      (assoc db :input-value (or ctx.value "")))))

(global main_view
  (fn []
    [:vbox {:aspect :surface :layout :top_left}
     [:text {:aspect :body :id :para}
      "the quick brown fox jumps over the lazy dog"]
     [:text {:aspect :locked :id :locked-text :selectable false}
      "this paragraph is not selectable"]
     [:input {:aspect :input :id :probe-input :value (subscribe :input-value)
              :change [:event/input-change]}]]))
```

- [ ] **Step 3: Write the UI tests**

`test/ui/test_text_select.bb`:

```clojure
(require '[redin-test :refer :all]
         '[cheshire.core :as json]
         '[babashka.http-client :as http]
         '[clojure.string :as str])

(defn get-selection []
  (let [port (str/trim (slurp ".redin-port"))
        resp (http/get (str "http://localhost:" port "/selection") {:throw false})]
    (when (= 200 (:status resp))
      (json/parse-string (:body resp) true))))

(defn rect-of [id]
  (let [el (find-element {:id id})]
    (when el (get-element-rect el))))   ; helper from redin-test — add if missing

(defn click-at [x y]
  (let [port (str/trim (slurp ".redin-port"))]
    (http/post (str "http://localhost:" port "/click")
               {:body (json/generate-string {:x x :y y})
                :headers {"Content-Type" "application/json"}})))

(deftest no-selection-initially
  (let [sel (get-selection)]
    (assert (= "none" (:kind sel)) (str "expected :none, got " (:kind sel)))))

(deftest single-click-sets-zero-width-selection-on-selectable
  (let [r (rect-of :para)]
    (click-at (+ (:x r) 30) (+ (:y r) (/ (:height r) 2))))
  (wait-for (fn [] (= "text" (:kind (get-selection)))) {:timeout 2000})
  (let [sel (get-selection)]
    (assert (= (:start sel) (:end sel))
            "single click should produce an empty selection")))

(deftest opt-out-has-no-text-selection
  (let [r (rect-of :locked-text)]
    (click-at (+ (:x r) 20) (+ (:y r) (/ (:height r) 2))))
  (wait-ms 200)
  ;; Either still none, or cleared because click-elsewhere-to-clear fired.
  (assert (not= "text" (:kind (get-selection)))))

(deftest clicking-input-clears-text-selection
  (let [r (rect-of :para)]
    (click-at (+ (:x r) 30) (+ (:y r) (/ (:height r) 2))))
  (wait-for (fn [] (= "text" (:kind (get-selection)))) {:timeout 2000})
  (let [ri (rect-of :probe-input)]
    (click-at (+ (:x ri) 20) (+ (:y ri) (/ (:height ri) 2))))
  (wait-ms 200)
  (assert (not= "text" (:kind (get-selection)))))

(deftest double-click-selects-word
  (let [r (rect-of :para)
        x (+ (:x r) 40)
        y (+ (:y r) (/ (:height r) 2))]
    (click-at x y)
    (Thread/sleep 50)   ; well under 400ms double-click window
    (click-at x y))
  (wait-for (fn [] (and (= "text" (:kind (get-selection)))
                        (< (:start (get-selection)) (:end (get-selection)))))
            {:timeout 2000})
  (let [sel (get-selection)]
    (assert (re-find #"\w+" (:text sel)))
    (assert (not (str/starts-with? (:text sel) " ")))
    (assert (not (str/ends-with?   (:text sel) " ")))))

(deftest triple-click-selects-line
  (let [r (rect-of :para)
        x (+ (:x r) 40)
        y (+ (:y r) (/ (:height r) 2))]
    (click-at x y) (Thread/sleep 50)
    (click-at x y) (Thread/sleep 50)
    (click-at x y))
  (wait-for (fn [] (let [s (get-selection)]
                     (and (= "text" (:kind s))
                          (> (- (:end s) (:start s)) 10))))
            {:timeout 2000})
  (let [sel (get-selection)]
    (assert (> (count (:text sel)) 10)
            "triple-click should select at least the whole visual line")))
```

- [ ] **Step 4: Check `redin-test` helpers**

Run: `grep -n "find-element\|get-element-rect" test/ui/redin_test.clj`.

If `get-element-rect` doesn't exist, read a nearby existing helper and add it (it reads the element's `[x y w h]` from the frame, which `/frames` already exposes). Do not invent higher-level helpers — `click-at` is local to the test file because it does one thing.

- [ ] **Step 5: Run the test**

```
./build/redin --dev test/ui/text_select_app.fnl &
sleep 2
bb test/ui/run.bb test/ui/test_text_select.bb
curl -s -X POST http://localhost:$(cat .redin-port)/shutdown
```
Expected: 6/6 pass.

- [ ] **Step 6: Commit**

```
git add src/host/input/text_select_test.odin test/ui/text_select_app.fnl test/ui/test_text_select.bb
# + any redin_test.clj extension
git commit -m "test: NodeText selection — Odin units + UI integration"
```

---

## Task 16: Full regression sweep

- [ ] **Step 1: Run every verification the redin-maintenance skill calls for**

```
odin build src/host -out:build/redin
odin test src/host/profile
odin test src/host/parser
odin test src/host/input
luajit test/lua/runner.lua test/lua/test_*.fnl
bash test/ui/run-all.sh
```
Expected: builds clean; 4/4 profile, 25/25 parser, N/N input, 122/122 fennel, all UI suites 0-failed (minus the pre-existing `test_profile` quirk — it reports no results line under `run-all.sh` on main, standalone it passes).

- [ ] **Step 2: Memory sanity**

```
./build/redin --dev --track-mem test/ui/text_select_app.fnl &
sleep 2
# Drive a few select/clear cycles via /click or /mouse
curl -s -X POST http://localhost:$(cat .redin-port)/click -d '{"x":100,"y":100}'
sleep 0.2
curl -s -X POST http://localhost:$(cat .redin-port)/click -d '{"x":500,"y":500}'
curl -s -X POST http://localhost:$(cat .redin-port)/shutdown
```
Expected: no `leak` / `outstanding` lines on shutdown stderr.

- [ ] **Step 3: Visual spot check**

```
./build/redin --dev test/ui/multiline_app.fnl &
sleep 2
# drag-select a few lines
curl -s http://localhost:$(cat .redin-port)/screenshot > /tmp/text-sel.png
curl -s -X POST http://localhost:$(cat .redin-port)/shutdown
```
Inspect `/tmp/text-sel.png` — one rect per wrapped line, glyphs still render over the highlight, selection color is the themed color (if set).

- [ ] **Step 4: Commit anything that moved (if anything)**

Only if fixup edits were needed. Otherwise skip.

---

## Task 17: Docs + skill sync

**Files:**
- Modify: `docs/reference/theme.md` — note `:selection` is now fully wired (consumed by NodeInput + NodeText)
- Modify: `docs/reference/elements.md` — add `:selectable` attribute to the NodeText section
- Modify: `docs/core-api.md` — add `/selection` to the dev-server endpoint table
- Modify: `.claude/skills/redin-dev/SKILL.md` — mention `:selectable` in the attribute list and `:selection` under theme
- Leave `CLAUDE.md` as-is (no top-level convention change)
- Modify: `.claude/skills/redin-maintenance/SKILL.md` — add `text_select` to the "Available test suites" list

- [ ] **Step 1: Apply the edits**

Concrete content for each is dictated by the surrounding style. Match the neighboring table rows.

- [ ] **Step 2: Grep check**

```
rg -n 'selection_color|:selectable' docs/ .claude/skills/ CLAUDE.md
```
Expected: every code reference has a doc counterpart.

- [ ] **Step 3: Commit**

```
git add docs/ .claude/skills/
git commit -m "docs: NodeText selection — :selectable, :selection, /selection"
```

---

## Task 18: Final PR

- [ ] **Step 1: Push the branch**

```
git push -u origin feat/text-highlight
```

- [ ] **Step 2: Open PR**

```
gh pr create --title "feat: NodeText selection / highlight" --body "$(cat docs/superpowers/specs/2026-04-20-text-highlight-design.md | head -40)"
```

Include a test plan section listing every command from Task 16 and the results.

- [ ] **Step 3: Self-review the diff**

```
gh pr diff | less
```

Walk the diff once. Confirm every file listed in the plan header table is touched, and nothing outside it.
