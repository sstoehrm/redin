# Drag Handle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an explicit drag-handle pattern that lets apps mark a small descendant as the grab surface and optionally opts the container itself out of being a grab surface, resolving the text-select-vs-drag click conflict in #94.

**Architecture:** New `:handle` boolean on `:draggable` options + new `:drag-handle` boolean on vbox/hbox/button. Parsed into struct fields, validated post-parse for the "handle false but no descendant handle" case. Listener extraction emits one `DragListener` per grab surface (container and/or each descendant handle), with a new `source_idx` field on `DragListener` so drag capture reads attrs from the draggable container even when the click winner is the handle. Cursor proc gains drag-aware precedence.

**Tech Stack:** Odin (host), Fennel/Lua (app code), Raylib (windowing/cursor), Babashka (UI tests).

**Spec:** `docs/superpowers/specs/2026-04-29-drag-handle-design.md`

---

## File map

**Modified:**
- `src/redin/types/view_tree.odin` — `Draggable_Attrs.handle_off`; `drag_handle` on NodeVbox/NodeHbox/NodeButton
- `src/redin/types/listener_events.odin` — `DragListener.source_idx`
- `src/redin/bridge/bridge.odin` — parser additions in `lua_read_draggable` and per-node-type branches; new `validate_drag_handles` helper
- `src/redin/runtime.odin` — call `validate_drag_handles` before `extract_listeners`
- `src/redin/input/input.odin` — `extract_listeners` emits handle listeners; `set_hover_cursor` precedence
- `src/redin/input/drag.odin` — capture uses `source_idx` instead of `winner`
- `test/ui/drag_app.fnl` — add a third list demonstrating handles
- `test/ui/test_drag.bb` — new test cases for handle behavior
- `examples/kitchen-sink.fnl` — finalize the proposed handle row
- `docs/core-api.md` — drag attribute table updates
- `docs/reference/elements.md` — per-element attribute additions
- `.claude/skills/redin-dev/SKILL.md` — extend drag-and-drop section

**Created (optional, see Task 11):**
- `test/ui/drag_handle_warn_app.fnl` — app for stderr-warning verification
- `test/ui/test_drag_handle_warn.bb` — stderr capture test (only if framework extension is in scope)

---

## Task 1: Data model additions

**Files:**
- Modify: `src/redin/types/view_tree.odin`
- Modify: `src/redin/types/listener_events.odin`

- [ ] **Step 1: Add `handle_off` to `Draggable_Attrs`**

In `src/redin/types/view_tree.odin`, locate the `Draggable_Attrs` struct (around line 55) and add `handle_off` as the last field:

```odin
Draggable_Attrs :: struct {
	tags:       []string,
	event:      string,
	mode:       Drag_Mode,
	aspect:     string,
	animate:    Maybe(Animate_Decoration),
	ctx:        i32,
	handle_off: bool,   // zero-value = container is a grab surface
}
```

- [ ] **Step 2: Add `drag_handle` to NodeVbox / NodeHbox / NodeButton**

In the same file, append `drag_handle: bool` as the last field of each of `NodeVbox`, `NodeHbox`, `NodeButton`:

```odin
NodeVbox :: struct {
	overflow:    string,
	layout:      Anchor,
	aspect:      string,
	width:       union { SizeValue, f16 },
	height:      union { SizeValue, f16 },
	draggable:   Maybe(Draggable_Attrs),
	dropable:    Maybe(Dropable_Attrs),
	drag_over:   Maybe(Drag_Over_Attrs),
	drag_handle: bool,
}

NodeHbox :: struct {
	overflow:    string,
	layout:      Anchor,
	aspect:      string,
	width:       union { SizeValue, f32 },
	height:      union { SizeValue, f32 },
	draggable:   Maybe(Draggable_Attrs),
	dropable:    Maybe(Dropable_Attrs),
	drag_over:   Maybe(Drag_Over_Attrs),
	drag_handle: bool,
}

NodeButton :: struct {
	click:       string,
	click_ctx:   i32,
	width:       union { SizeValue, f32 },
	height:      union { SizeValue, f32 },
	label:       string,
	aspect:      string,
	drag_handle: bool,
}
```

- [ ] **Step 3: Add `source_idx` to DragListener**

In `src/redin/types/listener_events.odin`, modify `DragListener`:

```odin
DragListener :: struct {
	node_idx:   int,    // hit-test surface (handle if present, else container)
	source_idx: int,    // the draggable container; equals node_idx for container-grabs
	tags:       []string,
}
```

- [ ] **Step 4: Build check**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`

Expected: build fails — existing call sites that construct `DragListener` only set `node_idx`/`tags`. We'll fix those in Task 6. Note the failing locations.

- [ ] **Step 5: Temporarily satisfy the build**

To keep intermediate commits compilable and let the parser changes land first, set `source_idx` to match `node_idx` at every existing `DragListener{...}` construction site. There are two of them in `src/redin/input/input.odin` (the vbox and hbox branches of `extract_listeners`):

```odin
append(&listeners, types.Listener(types.DragListener{
	node_idx = idx, source_idx = idx, tags = d.tags,
}))
```

Apply the same change in both vbox and hbox branches.

- [ ] **Step 6: Build check**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/redin/types/view_tree.odin src/redin/types/listener_events.odin src/redin/input/input.odin
git commit -m "types(drag): add handle_off, drag_handle, source_idx fields"
```

---

## Task 2: Parser — read `:handle` in `lua_read_draggable`

**Files:**
- Modify: `src/redin/bridge/bridge.odin` (around line 2020, after the `:aspect` read in `lua_read_draggable`)

- [ ] **Step 1: Add `:handle` read after `:aspect`**

In `lua_read_draggable`, after the block reading `:aspect` and before the `parse_animate_attr` call, insert:

```odin
// :handle (optional, default true). Only an explicit `false` disables
// container-as-grab-surface; descendants marked :drag-handle become the
// only grab targets. Validated later by validate_drag_handles.
lua_getfield(L, opts, "handle")
if lua_isboolean(L, -1) {
	if !lua_toboolean(L, -1) do out.handle_off = true
}
lua_pop(L, 1)
```

Confirm `lua_isboolean` and `lua_toboolean` exist in `src/redin/bridge/lua_api.odin`. They do (LuaJIT FFI bindings cover them).

- [ ] **Step 2: Build check**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`

Expected: PASS.

- [ ] **Step 3: Manual round-trip via dev server**

Run: `./build/redin --dev test/ui/drag_app.fnl &`

Edit `test/ui/drag_app.fnl` temporarily — add `:handle false` to one of the `:draggable` options maps. Save. The hot-reloader picks it up. Then:

```bash
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/frames | head -200
```

Confirm the frame parses without errors. Stop the server, revert the edit:

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/shutdown
git checkout test/ui/drag_app.fnl
```

- [ ] **Step 4: Commit**

```bash
git add src/redin/bridge/bridge.odin
git commit -m "parse(drag): read :handle bool on :draggable options"
```

---

## Task 3: Parser — read `:drag-handle` on vbox / hbox

**Files:**
- Modify: `src/redin/bridge/bridge.odin` (vbox branch ~line 1153, hbox branch ~line 1185)

- [ ] **Step 1: Add `lua_get_bool_field_opt` helper if missing**

Search for existing helper:

```bash
rg -n 'lua_get_bool_field_opt' src/redin/bridge/
```

It exists (used by NodeText `:selectable`). Reuse it.

- [ ] **Step 2: Add `:drag-handle` read in the vbox branch**

In `lua_read_node`'s `case "vbox":` branch, after the existing `v.drag_over = lua_read_drag_over(L, attrs_idx)` line, add:

```odin
if dh, exists := lua_get_bool_field_opt(L, attrs_idx, "drag-handle"); exists {
	v.drag_handle = dh
}
```

- [ ] **Step 3: Add the same read in the hbox branch**

In the `case "hbox":` branch, after `h.drag_over = lua_read_drag_over(L, attrs_idx)`:

```odin
if dh, exists := lua_get_bool_field_opt(L, attrs_idx, "drag-handle"); exists {
	h.drag_handle = dh
}
```

- [ ] **Step 4: Build check**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/redin/bridge/bridge.odin
git commit -m "parse(drag): read :drag-handle bool on vbox/hbox"
```

---

## Task 4: Parser — `:drag-handle` on button + click conflict warning

**Files:**
- Modify: `src/redin/bridge/bridge.odin` (button branch ~line 1216)

- [ ] **Step 1: Read `:drag-handle` and conflict-warn in the button branch**

In `lua_read_node`'s `case "button":` branch, replace the existing block:

```odin
case "button":
	btn: types.NodeButton
	if attrs_idx > 0 {
		btn.aspect = lua_get_string_field(L, attrs_idx, "aspect")
		btn.click = lua_get_event_name(L, attrs_idx, "click")
		btn.click_ctx = lua_get_event_ctx(L, attrs_idx, "click")
		btn.width = lua_get_size_f32(L, attrs_idx, "width")
		btn.height = lua_get_size_f32(L, attrs_idx, "height")
	}
	if len(text_content) > 0 do btn.label = text_content
	return btn
```

with:

```odin
case "button":
	btn: types.NodeButton
	if attrs_idx > 0 {
		btn.aspect = lua_get_string_field(L, attrs_idx, "aspect")
		btn.click = lua_get_event_name(L, attrs_idx, "click")
		btn.click_ctx = lua_get_event_ctx(L, attrs_idx, "click")
		btn.width = lua_get_size_f32(L, attrs_idx, "width")
		btn.height = lua_get_size_f32(L, attrs_idx, "height")
		if dh, exists := lua_get_bool_field_opt(L, attrs_idx, "drag-handle"); exists {
			btn.drag_handle = dh
		}
		if btn.drag_handle && len(btn.click) > 0 {
			fmt.eprintln(":button: :drag-handle conflicts with :click — dropping :click")
			delete(btn.click)
			btn.click = ""
			if btn.click_ctx != 0 {
				luaL_unref(L, LUA_REGISTRYINDEX, btn.click_ctx)
				btn.click_ctx = 0
			}
		}
	}
	if len(text_content) > 0 do btn.label = text_content
	return btn
```

Note: we call `delete(btn.click)` because `lua_get_event_name` returns a heap-cloned string; not deleting it would leak. We also `luaL_unref` the click context to release the Lua registry slot.

- [ ] **Step 2: Build check**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`

Expected: PASS.

- [ ] **Step 3: Manual conflict-warning check**

Create a throwaway test file `/tmp/drag_handle_conflict.fnl`:

```fennel
(local dataflow (require :dataflow))
(local theme-mod (require :theme))
(theme-mod.set-theme {:s {:bg [40 40 40]}})
(dataflow.init {})
(global main_view
  (fn []
    [:vbox {:aspect :s}
     [:button {:click :event/x :drag-handle true} "boom"]]))
```

Run with stderr captured:

```bash
./build/redin --dev /tmp/drag_handle_conflict.fnl 2>&1 | grep -i 'drag-handle conflicts' | head -3
```

Expected: at least one `:button: :drag-handle conflicts with :click — dropping :click` line. Then shut down (`curl -X POST .../shutdown`).

- [ ] **Step 4: Commit**

```bash
git add src/redin/bridge/bridge.odin
git commit -m "parse(drag): :drag-handle on button drops conflicting :click"
```

---

## Task 5: `validate_drag_handles` post-parse helper

**Files:**
- Modify: `src/redin/bridge/bridge.odin` (new proc, called after frame parse)
- Modify: `src/redin/runtime.odin` (call before `extract_listeners`)

- [ ] **Step 1: Add the helper to bridge.odin**

Insert near the existing `clear_draggable_attrs` definitions (around line 121, before `clear_draggable_attrs`):

```odin
// Walk the flat tree once: for each draggable with handle_off, ensure at
// least one descendant carries drag_handle. Otherwise the draggable is
// silently ungrabbable. Stops the descendant walk at nested-draggable
// boundaries (handle binds to nearest draggable ancestor).
//
// Logged per-frame in line with the existing parse-warning convention
// (no dedupe).
validate_drag_handles :: proc(
	nodes: []types.Node,
	children_list: []types.Children,
	paths: []types.Path,
) {
	for node, idx in nodes {
		handle_off := false
		switch n in node {
		case types.NodeVbox:
			if d, ok := n.draggable.?; ok do handle_off = d.handle_off
		case types.NodeHbox:
			if d, ok := n.draggable.?; ok do handle_off = d.handle_off
		case types.NodeStack, types.NodeCanvas, types.NodeInput,
		     types.NodeButton, types.NodeText, types.NodeImage,
		     types.NodePopout, types.NodeModal:
		}
		if !handle_off do continue
		if !subtree_has_drag_handle(idx, nodes, children_list) {
			fmt.eprintfln(
				":draggable at idx %d has :handle false but no descendant :drag-handle true — ungrabbable",
				idx,
			)
		}
	}
}

// True iff any descendant of `root` carries drag_handle == true.
// Stops descent at nested-draggable boundaries.
subtree_has_drag_handle :: proc(
	root: int,
	nodes: []types.Node,
	children_list: []types.Children,
) -> bool {
	if root < 0 || root >= len(children_list) do return false
	kids := children_list[root]
	for i in 0 ..< int(kids.length) {
		ci := int(kids.value[i])
		if ci < 0 || ci >= len(nodes) do continue
		// Stop at a nested draggable — its descendants belong to it.
		switch n in nodes[ci] {
		case types.NodeVbox:
			if _, ok := n.draggable.?; ok do continue
			if n.drag_handle do return true
		case types.NodeHbox:
			if _, ok := n.draggable.?; ok do continue
			if n.drag_handle do return true
		case types.NodeButton:
			if n.drag_handle do return true
		case types.NodeStack, types.NodeCanvas, types.NodeInput,
		     types.NodeText, types.NodeImage, types.NodePopout,
		     types.NodeModal:
		}
		if subtree_has_drag_handle(ci, nodes, children_list) do return true
	}
	return false
}
```

- [ ] **Step 2: Wire it into the per-frame path in runtime.odin**

In `src/redin/runtime.odin`, the existing block at line 186-189 reads:

```odin
if b.frame_changed {
	delete(listeners)
	listeners = input.extract_listeners(b.paths, b.nodes, b.theme)
}
```

Modify to:

```odin
if b.frame_changed {
	delete(listeners)
	bridge.validate_drag_handles(b.nodes[:], b.children_list[:], b.paths[:])
	listeners = input.extract_listeners(b.paths, b.nodes, b.theme)
}
```

- [ ] **Step 3: Build check**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`

Expected: PASS.

- [ ] **Step 4: Manual warning check**

Throwaway file `/tmp/drag_no_handle.fnl`:

```fennel
(local dataflow (require :dataflow))
(local theme-mod (require :theme))
(theme-mod.set-theme {:s {:bg [40 40 40]}})
(dataflow.init {})
(global main_view
  (fn []
    [:vbox {:aspect :s}
     [:hbox {:draggable [:row {:handle false :event :event/x} 1]}
       [:text {} "no handle"]]]))
```

Run:

```bash
./build/redin --dev /tmp/drag_no_handle.fnl 2>&1 | grep 'ungrabbable' | head -3
```

Expected: at least one `:draggable at idx N has :handle false but no descendant :drag-handle true — ungrabbable` line. Shut down.

- [ ] **Step 5: Commit**

```bash
git add src/redin/bridge/bridge.odin src/redin/runtime.odin
git commit -m "parse(drag): validate :handle false has a descendant handle"
```

---

## Task 6: extract_listeners — emit handle DragListeners with `source_idx`

**Files:**
- Modify: `src/redin/input/input.odin` (extract_listeners around line 43)

- [ ] **Step 1: Add helper `collect_drag_handles_in_subtree`**

Insert near the top of `src/redin/input/input.odin`, after `import` block and before `focused_idx`:

```odin
// Collect descendant indices of `root` that carry drag_handle == true.
// Stops at nested-draggable boundaries — a handle inside an inner
// draggable belongs to that inner one (nearest-ancestor rule).
// Allocates with context.temp_allocator; caller does not free.
collect_drag_handles_in_subtree :: proc(
	root: int,
	nodes: [dynamic]types.Node,
	children_list: [dynamic]types.Children,
) -> [dynamic]int {
	out: [dynamic]int
	out.allocator = context.temp_allocator
	collect_drag_handles_recur(root, nodes, children_list, &out)
	return out
}

@(private="file")
collect_drag_handles_recur :: proc(
	root: int,
	nodes: [dynamic]types.Node,
	children_list: [dynamic]types.Children,
	out: ^[dynamic]int,
) {
	if root < 0 || root >= len(children_list) do return
	kids := children_list[root]
	for i in 0 ..< int(kids.length) {
		ci := int(kids.value[i])
		if ci < 0 || ci >= len(nodes) do continue
		// Stop descending into nested draggables.
		nested := false
		switch n in nodes[ci] {
		case types.NodeVbox:
			if _, ok := n.draggable.?; ok do nested = true
			if n.drag_handle do append(out, ci)
		case types.NodeHbox:
			if _, ok := n.draggable.?; ok do nested = true
			if n.drag_handle do append(out, ci)
		case types.NodeButton:
			if n.drag_handle do append(out, ci)
		case types.NodeStack, types.NodeCanvas, types.NodeInput,
		     types.NodeText, types.NodeImage, types.NodePopout,
		     types.NodeModal:
		}
		if !nested do collect_drag_handles_recur(ci, nodes, children_list, out)
	}
}
```

Note: `extract_listeners` currently doesn't take `children_list`. We'll add it as a parameter.

- [ ] **Step 2: Add `children_list` parameter to extract_listeners**

Change the signature from:

```odin
extract_listeners :: proc(
	paths: [dynamic]types.Path,
	nodes: [dynamic]types.Node,
	theme: map[string]types.Theme,
) -> [dynamic]types.Listener {
```

to:

```odin
extract_listeners :: proc(
	paths: [dynamic]types.Path,
	nodes: [dynamic]types.Node,
	children_list: [dynamic]types.Children,
	theme: map[string]types.Theme,
) -> [dynamic]types.Listener {
```

Update the call site in `src/redin/runtime.odin` (the line we touched in Task 5):

```odin
listeners = input.extract_listeners(b.paths, b.nodes, b.children_list, b.theme)
```

- [ ] **Step 3: Replace the vbox `DragListener` emission**

In the `case types.NodeVbox:` branch of `extract_listeners`, replace:

```odin
if d, ok := n.draggable.?; ok && len(d.tags) > 0 && len(d.event) > 0 {
	append(&listeners, types.Listener(types.DragListener{
		node_idx = idx, source_idx = idx, tags = d.tags,
	}))
}
```

with:

```odin
if d, ok := n.draggable.?; ok && len(d.tags) > 0 && len(d.event) > 0 {
	if !d.handle_off {
		append(&listeners, types.Listener(types.DragListener{
			node_idx = idx, source_idx = idx, tags = d.tags,
		}))
	}
	handles := collect_drag_handles_in_subtree(idx, nodes, children_list)
	for h in handles {
		append(&listeners, types.Listener(types.DragListener{
			node_idx = h, source_idx = idx, tags = d.tags,
		}))
	}
}
```

- [ ] **Step 4: Same change in the hbox branch**

Apply the identical replacement in `case types.NodeHbox:`.

- [ ] **Step 5: Build check**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/redin/input/input.odin src/redin/runtime.odin
git commit -m "input(drag): emit handle DragListeners with source_idx"
```

---

## Task 7: drag.odin — capture from `source_idx`

**Files:**
- Modify: `src/redin/input/drag.odin` (lines 173-217)

- [ ] **Step 1: Capture `source_idx` from the winning DragListener**

In `process_drag`, locate the `Drag_Idle` branch (around line 166-220). Replace:

```odin
winner := deepest_listener_idx(listeners, node_rects, pt)
if winner < 0 do continue

// Confirm the deepest listener winner is actually a DragListener.
has_drag := false
tags: []string
for listener in listeners {
	dl, ok := listener.(types.DragListener)
	if !ok do continue
	if dl.node_idx == winner {
		has_drag = true
		tags = dl.tags
		break
	}
}
if !has_drag do continue

// Read drag attrs from the source node (vbox / hbox only).
cap := Drag_Captured{
	src_idx   = winner,
	start_pos = pt,
	src_tags  = clone_string_slice(tags),
}
switch n in nodes[winner] {
```

with:

```odin
winner := deepest_listener_idx(listeners, node_rects, pt)
if winner < 0 do continue

// Confirm the deepest listener winner is actually a DragListener,
// and capture its source_idx (the draggable container — same as
// node_idx for container-grab listeners, the parent draggable for
// handle listeners).
has_drag := false
src_idx := -1
tags: []string
for listener in listeners {
	dl, ok := listener.(types.DragListener)
	if !ok do continue
	if dl.node_idx == winner {
		has_drag = true
		src_idx = dl.source_idx
		tags = dl.tags
		break
	}
}
if !has_drag do continue

// Read drag attrs from the source node (the draggable container).
cap := Drag_Captured{
	src_idx   = src_idx,
	start_pos = pt,
	src_tags  = clone_string_slice(tags),
}
switch n in nodes[src_idx] {
```

- [ ] **Step 2: Build check**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`

Expected: PASS.

- [ ] **Step 3: Smoke test the existing drag path didn't regress**

Run the existing drag UI test:

```bash
bash test/ui/run-all.sh --headless 2>&1 | tail -30
```

Or just the drag suite manually:

```bash
./build/redin --dev test/ui/drag_app.fnl &
sleep 1
bb test/ui/run.bb test/ui/test_drag.bb
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/shutdown
```

Expected: existing drag tests still pass (we haven't changed the default-`:handle true` behavior).

- [ ] **Step 4: Commit**

```bash
git add src/redin/input/drag.odin
git commit -m "input(drag): capture from source_idx so handles drag the container"
```

---

## Task 8: Cursor wiring

**Files:**
- Modify: `src/redin/input/input.odin` (`set_hover_cursor` around line 451)

- [ ] **Step 1: Replace `set_hover_cursor` with the precedence proc**

Replace the existing body:

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

with:

```odin
// Cursor precedence (highest first):
//   1. Active or pending drag → RESIZE_ALL ("grabbing"; raylib has no
//      grab cursor, this is the closest analogue).
//   2. Mouse over a DragListener (handle or container) → POINTING_HAND.
//   3. Mouse over a Text_Select_Listener → IBEAM.
//   4. Otherwise DEFAULT.
set_hover_cursor :: proc(listeners: []types.Listener, node_rects: []rl.Rectangle) {
	switch _ in drag {
	case Drag_Pending, Drag_Active:
		rl.SetMouseCursor(.RESIZE_ALL)
		return
	case Drag_Idle:
	}
	mouse := rl.GetMousePosition()
	for listener in listeners {
		dl, ok := listener.(types.DragListener)
		if !ok do continue
		if dl.node_idx < 0 || dl.node_idx >= len(node_rects) do continue
		if rl.CheckCollisionPointRec(mouse, node_rects[dl.node_idx]) {
			rl.SetMouseCursor(.POINTING_HAND)
			return
		}
	}
	for listener in listeners {
		tl, ok := listener.(types.Text_Select_Listener)
		if !ok do continue
		if tl.node_idx < 0 || tl.node_idx >= len(node_rects) do continue
		if rl.CheckCollisionPointRec(mouse, node_rects[tl.node_idx]) {
			rl.SetMouseCursor(.IBEAM)
			return
		}
	}
	rl.SetMouseCursor(.DEFAULT)
}
```

The `drag` package var is in the same `input` package; direct access is fine.

- [ ] **Step 2: Build check**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`

Expected: PASS.

- [ ] **Step 3: Manual visual check**

Run: `./build/redin --dev test/ui/drag_app.fnl`

Move the mouse:
- Over a row (no handle yet — default `:handle true`) → cursor should be POINTING_HAND.
- Press and hold to start dragging → cursor should switch to RESIZE_ALL.
- Release; cursor returns to POINTING_HAND while still over the row.

Stop the binary.

- [ ] **Step 4: Commit**

```bash
git add src/redin/input/input.odin
git commit -m "input(drag): cursor precedence — drag listeners + active drag state"
```

---

## Task 9: Tests for handle-listener semantics

The dev server can `POST /click` (one-shot) and `POST /events` (synthetic dispatch) but cannot simulate a multi-step mouse gesture (down → move-past-threshold → up). End-to-end Babashka tests like `simulate-drag` therefore aren't feasible without adding mouse-event endpoints, which is out of scope. Instead, we test listener semantics in Odin (matching the existing pattern in `src/redin/input/state_test.odin`) and rely on the existing UI suite for regression coverage.

**Files:**
- Create: `src/redin/input/extract_listeners_test.odin`
- Modify: `test/ui/drag_app.fnl` (small additions for visual / future-proofing only)

- [ ] **Step 1: Create Odin tests for `extract_listeners`**

Create `src/redin/input/extract_listeners_test.odin`:

```odin
package input

import "core:testing"
import "../types"

// Helpers — build a tiny flat tree of N nodes in DFS order with a fixed
// parent layout. Saves repetitive boilerplate in each test.

@(private="file")
mk_draggable :: proc(handle_off: bool) -> Maybe(types.Draggable_Attrs) {
	tags := make([]string, 1)
	tags[0] = "row"
	return types.Draggable_Attrs{
		tags = tags, event = "ev", handle_off = handle_off,
	}
}

@(private="file")
mk_children :: proc(values: ..i32) -> types.Children {
	v := make([]i32, len(values))
	for x, i in values do v[i] = x
	return types.Children{value = v, length = i32(len(values))}
}

@(private="file")
count_drag_listeners :: proc(ls: [dynamic]types.Listener) -> int {
	n := 0
	for l in ls do if _, ok := l.(types.DragListener); ok do n += 1
	return n
}

@(private="file")
drag_listener_with_node :: proc(ls: [dynamic]types.Listener, node_idx: int) -> (types.DragListener, bool) {
	for l in ls {
		if dl, ok := l.(types.DragListener); ok && dl.node_idx == node_idx do return dl, true
	}
	return {}, false
}

// Case 1: default :handle true, no handle children — single DragListener
// at the container, source_idx == node_idx.
@(test)
test_extract_default_handle_emits_container_listener :: proc(t: ^testing.T) {
	nodes: [dynamic]types.Node
	defer delete(nodes)
	append(&nodes, types.Node(types.NodeVbox{
		draggable = mk_draggable(false /* handle_off */),
	}))

	children: [dynamic]types.Children
	defer delete(children)
	append(&children, mk_children())

	paths: [dynamic]types.Path
	defer delete(paths)
	append(&paths, types.Path{})

	theme: map[string]types.Theme
	defer delete(theme)

	ls := extract_listeners(paths, nodes, children, theme)
	defer delete(ls)

	testing.expect_value(t, count_drag_listeners(ls), 1)
	dl, ok := drag_listener_with_node(ls, 0)
	testing.expect(t, ok, "should have DragListener at idx 0")
	testing.expect_value(t, dl.source_idx, 0)
}

// Case 2: :handle false with a child :drag-handle true — single DragListener
// at the handle, source_idx points back to the container.
@(test)
test_extract_handle_off_emits_handle_listener_only :: proc(t: ^testing.T) {
	nodes: [dynamic]types.Node
	defer delete(nodes)
	// idx 0: draggable container with handle_off
	append(&nodes, types.Node(types.NodeVbox{
		draggable = mk_draggable(true),
	}))
	// idx 1: handle vbox
	append(&nodes, types.Node(types.NodeVbox{drag_handle = true}))

	children: [dynamic]types.Children
	defer delete(children)
	append(&children, mk_children(1))   // 0 -> [1]
	append(&children, mk_children())    // 1 leaf

	paths: [dynamic]types.Path
	defer delete(paths)
	append(&paths, types.Path{})
	append(&paths, types.Path{})

	theme: map[string]types.Theme
	defer delete(theme)

	ls := extract_listeners(paths, nodes, children, theme)
	defer delete(ls)

	testing.expect_value(t, count_drag_listeners(ls), 1)
	dl, ok := drag_listener_with_node(ls, 1)
	testing.expect(t, ok, "should have DragListener at handle idx 1")
	testing.expect_value(t, dl.source_idx, 0)
}

// Case 3: default :handle true with a handle child — TWO listeners,
// container + handle, both with source_idx = container idx.
@(test)
test_extract_default_with_handle_emits_both :: proc(t: ^testing.T) {
	nodes: [dynamic]types.Node
	defer delete(nodes)
	append(&nodes, types.Node(types.NodeVbox{
		draggable = mk_draggable(false),
	}))
	append(&nodes, types.Node(types.NodeVbox{drag_handle = true}))

	children: [dynamic]types.Children
	defer delete(children)
	append(&children, mk_children(1))
	append(&children, mk_children())

	paths: [dynamic]types.Path
	defer delete(paths)
	append(&paths, types.Path{})
	append(&paths, types.Path{})

	theme: map[string]types.Theme
	defer delete(theme)

	ls := extract_listeners(paths, nodes, children, theme)
	defer delete(ls)

	testing.expect_value(t, count_drag_listeners(ls), 2)
	dl0, ok0 := drag_listener_with_node(ls, 0)
	dl1, ok1 := drag_listener_with_node(ls, 1)
	testing.expect(t, ok0, "container listener missing")
	testing.expect(t, ok1, "handle listener missing")
	testing.expect_value(t, dl0.source_idx, 0)
	testing.expect_value(t, dl1.source_idx, 0)
}

// Case 4: multiple handles — one DragListener per handle, all sourcing
// the same container.
@(test)
test_extract_multiple_handles_each_emit_listener :: proc(t: ^testing.T) {
	nodes: [dynamic]types.Node
	defer delete(nodes)
	append(&nodes, types.Node(types.NodeVbox{
		draggable = mk_draggable(true),
	}))
	append(&nodes, types.Node(types.NodeVbox{drag_handle = true}))
	append(&nodes, types.Node(types.NodeVbox{drag_handle = true}))

	children: [dynamic]types.Children
	defer delete(children)
	append(&children, mk_children(1, 2))
	append(&children, mk_children())
	append(&children, mk_children())

	paths: [dynamic]types.Path
	defer delete(paths)
	for _ in 0 ..< 3 do append(&paths, types.Path{})

	theme: map[string]types.Theme
	defer delete(theme)

	ls := extract_listeners(paths, nodes, children, theme)
	defer delete(ls)

	testing.expect_value(t, count_drag_listeners(ls), 2)
	for h in []int{1, 2} {
		dl, ok := drag_listener_with_node(ls, h)
		testing.expect(t, ok, "handle listener missing")
		testing.expect_value(t, dl.source_idx, 0)
	}
}

// Case 5: nested draggables — handle inside an inner draggable belongs
// to the inner one, not the outer.
@(test)
test_extract_nested_draggable_does_not_steal_handle :: proc(t: ^testing.T) {
	nodes: [dynamic]types.Node
	defer delete(nodes)
	// idx 0: outer draggable with handle_off
	append(&nodes, types.Node(types.NodeVbox{
		draggable = mk_draggable(true),
	}))
	// idx 1: inner draggable (default handle true, no handle_off)
	append(&nodes, types.Node(types.NodeVbox{
		draggable = mk_draggable(false),
	}))
	// idx 2: handle inside inner — belongs to inner, NOT outer
	append(&nodes, types.Node(types.NodeVbox{drag_handle = true}))

	children: [dynamic]types.Children
	defer delete(children)
	append(&children, mk_children(1))
	append(&children, mk_children(2))
	append(&children, mk_children())

	paths: [dynamic]types.Path
	defer delete(paths)
	for _ in 0 ..< 3 do append(&paths, types.Path{})

	theme: map[string]types.Theme
	defer delete(theme)

	ls := extract_listeners(paths, nodes, children, theme)
	defer delete(ls)

	// Outer: handle_off + no handle in its non-nested subtree → 0 listeners
	// Inner: default + a handle below → container listener (1) + handle (2)
	dl0, _ := drag_listener_with_node(ls, 0)
	_ = dl0
	dl1, ok1 := drag_listener_with_node(ls, 1)
	dl2, ok2 := drag_listener_with_node(ls, 2)
	testing.expect(t, ok1, "inner container listener missing")
	testing.expect(t, ok2, "handle listener missing")
	testing.expect_value(t, dl1.source_idx, 1) // inner is its own source
	testing.expect_value(t, dl2.source_idx, 1) // handle sources inner, not outer
	// Outer should have NO listener (handle_off + 0 reachable handles)
	_, has_outer := drag_listener_with_node(ls, 0)
	testing.expect(t, !has_outer, "outer container should not emit a listener")
}
```

- [ ] **Step 2: Run the Odin tests**

Run:

```bash
odin test src/redin/input -collection:lib=lib -collection:luajit=vendor/luajit
```

Expected: all five new tests pass alongside the existing `state_test` / `text_select_test` suite.

Note: CI (`.github/workflows/test.yml`) currently runs `odin test src/redin/parser` only — the `src/redin/input` test suite already lives outside CI. Optionally, follow up by adding `odin test src/redin/input -collection:lib=lib -collection:luajit=vendor/luajit` as a CI step in a separate PR; do not bundle it with this plan.

- [ ] **Step 3: Add a small handle-using row to drag_app.fnl (visual / future-proofing only)**

Append a single handle-using row to the existing `:item-list` content for visual inspection during `bash test/ui/run-all.sh`. Modify `main_view` so the existing items list contains a third top-level vbox below the existing one:

```fennel
[:vbox {:id :handle-row-demo :aspect :muted}
 [:hbox {:id :handle-row
         :aspect :row :height 42
         :draggable [:demo
                     {:mode :preview
                      :handle false
                      :event :event/drag
                      :aspect :row-dragging} 99]}
  [:vbox {:id :handle-grip
          :width 24 :height 24
          :aspect :muted
          :drag-handle true}]
  [:text {:id :handle-row-text :aspect :body} "drag me by the grip"]]]
```

This isn't asserted on — it just exists so the windowed run-all visualizes the new attribute and confirms no parser regression.

- [ ] **Step 4: Run the full UI suite headless**

```bash
bash test/ui/run-all.sh --headless 2>&1 | tail -40
```

Expected: every existing test still passes (no regression from the listener-extraction signature change or cursor proc).

- [ ] **Step 5: Commit**

```bash
git add src/redin/input/extract_listeners_test.odin test/ui/drag_app.fnl
git commit -m "test(drag): Odin unit tests for handle-listener emission semantics"
```

---

## Task 10: Memory check

**Files:** none (verification only)

- [ ] **Step 1: Run `--track-mem` against the extended drag app**

```bash
./build/redin --dev --track-mem test/ui/drag_app.fnl 2>&1 | tee /tmp/drag-trackmem.log &
sleep 2
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
# Poke the new lists so handle-listener allocation paths run.
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/click \
     -d '{"x":50,"y":120}'
sleep 1
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/shutdown
sleep 1
grep -iE 'leak|outstanding' /tmp/drag-trackmem.log | head
```

Expected: no `leak` / `outstanding` allocations beyond what the existing baseline reports (run the same command against the pre-handle binary if the baseline isn't known).

If anything new leaks, the most likely culprit is the `subtree_has_drag_handle` recursion or the `collect_drag_handles_in_subtree` temp_allocator usage. The latter is freed by `free_all(context.temp_allocator)` at the start of each loop iteration in runtime.odin (line 183), so it shouldn't show up; investigate if it does.

- [ ] **Step 2: Commit any fixes**

If no leaks, no commit. If a leak is fixed, commit with `mem(drag): <description>`.

---

## Task 11: Stderr-warning tests (best-effort, optional)

**Files:**
- Create: `test/ui/drag_handle_warn_app.fnl` (only if pursuing automated capture)
- Create: `test/ui/test_drag_handle_warn.bb` (same)

This task automates the two parse-warning checks (button click+handle conflict, draggable handle-off without descendant). The current `redin-test` framework spawns the binary inside `bb test/ui/run.bb` but does not capture stderr.

- [ ] **Step 1: Decide scope**

Inspect whether `test/ui/run.bb` already redirects stderr or could be extended trivially:

```bash
cat test/ui/run.bb
```

If the harness already pipes stderr into a buffer (`(slurp ...)` style), build the tests. If extending it would require nontrivial framework work, **skip this task** and rely on the manual checks already done in Task 4 Step 3 and Task 5 Step 4. Document the manual-verify decision in the commit message of Task 13 (docs sweep).

- [ ] **Step 2: If pursuing — create the warning-test app**

`test/ui/drag_handle_warn_app.fnl`:

```fennel
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme {:s {:bg [40 40 40] :padding [12 12 12 12]}})
(dataflow.init {})

(global main_view
  (fn []
    [:vbox {:aspect :s}
     ;; Triggers: ":button: :drag-handle conflicts with :click — dropping :click"
     [:button {:click :event/x :drag-handle true} "boom"]
     ;; Triggers: ":draggable at idx N has :handle false but no descendant :drag-handle true — ungrabbable"
     [:hbox {:draggable [:row {:handle false :event :event/y} 1]}
       [:text {} "no handle here"]]]))
```

- [ ] **Step 3: Test it**

`test/ui/test_drag_handle_warn.bb`:

```clojure
(deftest emits-button-conflict-warning
  (let [stderr (read-stderr-buffer)]
    (is (some #(re-find #":drag-handle conflicts with :click" %) (clojure.string/split-lines stderr)))))

(deftest emits-handle-off-no-descendant-warning
  (let [stderr (read-stderr-buffer)]
    (is (some #(re-find #":handle false but no descendant" %) (clojure.string/split-lines stderr)))))
```

`read-stderr-buffer` is the new framework primitive; only build it if framework extension is in scope.

- [ ] **Step 4: Run**

```bash
./build/redin --dev test/ui/drag_handle_warn_app.fnl &
sleep 1
bb test/ui/run.bb test/ui/test_drag_handle_warn.bb
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/shutdown
```

- [ ] **Step 5: Commit**

```bash
git add test/ui/drag_handle_warn_app.fnl test/ui/test_drag_handle_warn.bb test/ui/run.bb
git commit -m "test(drag): cover :drag-handle parse warnings"
```

---

## Task 12: Update `examples/kitchen-sink.fnl`

**Files:**
- Modify: `examples/kitchen-sink.fnl` (currently has the user's WIP `:drag-handle :tag` proposal)

- [ ] **Step 1: Inspect current diff**

```bash
git diff examples/kitchen-sink.fnl
```

Confirm the working tree has the `:handle false` + handle-button proposal that motivated this work.

- [ ] **Step 2: Replace the proposal with the final API**

Replace the row in the kitchen-sink todo list (around line 220-245 area) so the row uses `:handle false` on the draggable hbox plus an empty `:vbox` child carrying `:drag-handle true`. Final shape:

```fennel
[:hbox {:aspect :row
        :height 42
        :draggable [:row-drag
                    {:mode :preview
                     :handle false
                     :event :event/drag
                     :aspect :row-dragging
                     :animate {:provider :pulse-dot
                               :rect [:top_left -8 -8 14 14]
                               :z :above}}
                    i]
        :dropable [:row-drag
                   {:event :event/drop
                    :aspect :row-drop-hot}
                   i]}
 [:vbox {:width 24
         :aspect :drag-handle
         :drag-handle true}]
 [:text {:aspect :body} item.text]
 [:button {:width 250
           :aspect :button
           :click [:test/remove i]} "remove"]]
```

Place the `:vbox` handle child *before* the text so it sits at the leading edge of the row (matching macOS Reminders / Notion convention). The `:drag-handle` aspect already has `{:bg [66 66 86]}` from the user's working tree — no theme change needed.

- [ ] **Step 3: Visual check**

```bash
./build/redin --dev examples/kitchen-sink.fnl
```

Confirm:
- Clicking on the row's text starts a text selection (no drag).
- Clicking on the small grip handle starts a drag.
- Mid-drag, the row clones at the cursor (preview mode).
- Releasing on another row reorders.

Stop the binary.

- [ ] **Step 4: Commit**

```bash
git add examples/kitchen-sink.fnl
git commit -m "example(kitchen-sink): use :drag-handle for the todo row"
```

---

## Task 13: Docs + skill sweep

**Files:**
- Modify: `docs/core-api.md`
- Modify: `docs/reference/elements.md`
- Modify: `.claude/skills/redin-dev/SKILL.md`

- [ ] **Step 1: `docs/core-api.md`**

Find the `:draggable` section. Add a row to the options-map table:

```
| `:handle` | bool, default `true` | When `false`, the container is NOT itself a grab surface. Only descendants marked `:drag-handle true` initiate drags. Validates at parse time — warns to stderr if no descendant carries `:drag-handle true`. |
```

Find or add the per-element attribute reference for vbox / hbox / button. Add `:drag-handle` (bool, default `false`) — "Marks this node as a grab surface for the nearest `:draggable` ancestor. On `:button`, mutually exclusive with `:click` (parser warns and drops `:click` if both present)."

- [ ] **Step 2: `docs/reference/elements.md`**

Same per-element addition. Confirm the file structure first:

```bash
rg -n '^##|^###' docs/reference/elements.md | head -30
```

Add `:drag-handle` to the vbox, hbox, and button sections.

- [ ] **Step 3: `.claude/skills/redin-dev/SKILL.md`**

Locate the "Drag-and-drop attributes" section. After the existing example, add:

````markdown
### Drag handles

When a draggable container has interactive children (text that should be selectable, buttons), the click winner is the deepest hit — usually the text — so dragging-by-row-body breaks. Use a drag handle:

```fennel
[:hbox {:draggable [:row-drag {:handle false :event :event/drag} payload]
        :dropable  [:row-drag {:event :event/drop} payload]}
 [:vbox {:width 24 :aspect :grip :drag-handle true}]   ;; grab surface
 [:text {} item.text]                                  ;; selectable
 [:button {:click :remove} "x"]]                       ;; clickable
```

`:handle false` on the draggable opts the container out; `:drag-handle true` on any descendant marks it as a grab surface for the nearest `:draggable` ancestor. `:handle true` (default) keeps the container as a grab surface and makes any handles additive.

`:drag-handle` is allowed on `:vbox`, `:hbox`, and `:button`. On a button, it's mutually exclusive with `:click` (parser warns, drops `:click`).
````

- [ ] **Step 4: Sanity-grep for stale references**

```bash
rg -n '\:drag-handle\s+\:[a-z]' docs/ .claude/skills/ examples/
```

Should return nothing (the WIP `:drag-handle :tag` form is gone everywhere; the final form uses `true`).

- [ ] **Step 5: Commit**

```bash
git add docs/core-api.md docs/reference/elements.md .claude/skills/redin-dev/SKILL.md
git commit -m "docs(drag): document :handle and :drag-handle attributes"
```

---

## Final verification

- [ ] **All-suite headless pass:**

```bash
bash test/ui/run-all.sh --headless 2>&1 | tail -20
```

Expected: all suites green.

- [ ] **Fennel runtime suite (sanity, should be untouched):**

```bash
luajit test/lua/runner.lua test/lua/test_*.fnl 2>&1 | tail -5
```

Expected: 122 tests passing.

- [ ] **Close issue #94:** add a comment referencing the spec + plan + commits and close.
