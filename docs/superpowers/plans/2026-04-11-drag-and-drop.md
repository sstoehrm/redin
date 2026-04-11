# Drag-and-Drop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add framework-level drag-and-drop with group-scoped matching, automatic theme variants, and high-level event dispatch.

**Architecture:** Drag state (dragging_idx, drag_over_idx) lives in the input package alongside focused_idx. The bridge parses `:draggable` and `:dropable` 3-element vectors from Lua into new node fields. The renderer applies `#drag-start` and `#drag` theme variants based on drag state. Drop events are delivered through the existing Dispatch_Event pipeline.

**Tech Stack:** Odin, Raylib (input/rendering), LuaJIT (bridge), Fennel (test app), Babashka (UI tests)

**Spec:** `docs/superpowers/specs/2026-04-11-drag-and-drop-design.md`

---

## File Structure

| File | Responsibility |
|------|---------------|
| `src/host/types/view_tree.odin` | Add draggable/dropable fields to NodeHbox, NodeVbox |
| `src/host/types/listener_events.odin` | Add DragListener, DropListener to Listener union |
| `src/host/types/input_events.odin` | Add Drag_Event, Drop_Event to Dispatch_Event union |
| `src/host/bridge/bridge.odin` | Parse `:draggable`/`:dropable` attrs, deliver Drag/Drop events |
| `src/host/input/drag.odin` | New file: drag state, detection, processing |
| `src/host/input/input.odin` | Extract DragListener/DropListener in extract_listeners |
| `src/host/input/user_events.odin` | Suppress clicks during drag |
| `src/host/render.odin` | Apply `#drag-start` and `#drag` theme variants in draw_box |
| `src/host/main.odin` | Wire drag processing into the main loop |
| `test/ui/drag_app.fnl` | Minimal drag-and-drop test app |
| `test/ui/test_drag.bb` | UI tests for drag-and-drop |

---

### Task 1: Add type definitions

**Files:**
- Modify: `src/host/types/view_tree.odin:59-87` (NodeVbox, NodeHbox)
- Modify: `src/host/types/listener_events.odin:1-32`
- Modify: `src/host/types/input_events.odin:42-62`

- [ ] **Step 1: Add draggable/dropable fields to NodeHbox and NodeVbox**

In `src/host/types/view_tree.odin`, add six fields to both structs. The group and event are strings (keywords from Lua), the ctx is a Lua registry ref to the payload.

NodeVbox (after the `height` field, before the closing brace at line 72):

```odin
NodeVbox :: struct {
	overflow: string,
	layoutX:  LayoutX,
	layoutY:  LayoutY,
	aspect:   string,
	width:    union {
		SizeValue,
		f16,
	},
	height:   union {
		SizeValue,
		f16,
	},
	draggable_group: string,
	draggable_event: string,
	draggable_ctx:   i32,
	dropable_group:  string,
	dropable_event:  string,
	dropable_ctx:    i32,
}
```

NodeHbox (after the `height` field, before the closing brace at line 87):

```odin
NodeHbox :: struct {
	overflow: string,
	layoutX:  LayoutX,
	layoutY:  LayoutY,
	aspect:   string,
	width:    union {
		SizeValue,
		f32,
	},
	height:   union {
		SizeValue,
		f32,
	},
	draggable_group: string,
	draggable_event: string,
	draggable_ctx:   i32,
	dropable_group:  string,
	dropable_event:  string,
	dropable_ctx:    i32,
}
```

- [ ] **Step 2: Add DragListener and DropListener to listener types**

In `src/host/types/listener_events.odin`, add before the Listener union:

```odin
DragListener :: struct {
	node_idx: int,
}

DropListener :: struct {
	node_idx: int,
	group:    string,
}
```

Add both to the Listener union:

```odin
Listener :: union {
	HoverListener,
	FocusListener,
	ClickListener,
	KeyListener,
	ChangeListener,
	DragListener,
	DropListener,
}
```

- [ ] **Step 3: Add Drag_Event and Drop_Event to Dispatch_Event**

In `src/host/types/input_events.odin`, add after `Click_Event`:

```odin
Drag_Event :: struct {
	event_name:  string,
	context_ref: i32, // Lua registry ref for drag payload
}

Drop_Event :: struct {
	event_name: string,
	from_ref:   i32, // Lua registry ref for drag source payload
	to_ref:     i32, // Lua registry ref for drop target payload
}
```

Add both to the Dispatch_Event union:

```odin
Dispatch_Event :: union {
	Change_Event,
	Key_Event_Dispatch,
	Click_Event,
	Drag_Event,
	Drop_Event,
}
```

- [ ] **Step 4: Build to verify types compile**

Run: `odin build src/host -out:build/redin`
Expected: Build succeeds (new types are defined but not yet used)

- [ ] **Step 5: Commit**

```bash
git add src/host/types/view_tree.odin src/host/types/listener_events.odin src/host/types/input_events.odin
git commit -m "feat: add drag-and-drop type definitions"
```

---

### Task 2: Parse draggable/dropable attrs in bridge

**Files:**
- Modify: `src/host/bridge/bridge.odin:460-513` (vbox/hbox parsing), `bridge.odin:972+` (helpers)

- [ ] **Step 1: Add lua_get_drag_drop helper**

In `src/host/bridge/bridge.odin`, add after `lua_get_number_field` (after line 1042):

```odin
// Read a drag/drop 3-element vector field: [:group :event payload]
// Returns group, event as strings, and payload as a Lua registry ref.
lua_get_drag_drop :: proc(L: ^Lua_State, index: i32, field: cstring) -> (group: string, event: string, ctx: i32) {
	lua_getfield(L, index, field)
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) do return "", "", 0
	tbl := lua_gettop(L)

	// [1] = group keyword
	lua_rawgeti(L, tbl, 1)
	if lua_isstring(L, -1) {
		group = strings.clone_from_cstring(lua_tostring_raw(L, -1))
	}
	lua_pop(L, 1)

	// [2] = event keyword
	lua_rawgeti(L, tbl, 2)
	if lua_isstring(L, -1) {
		event = strings.clone_from_cstring(lua_tostring_raw(L, -1))
	}
	lua_pop(L, 1)

	// [3] = payload (any Lua value, stored as registry ref)
	lua_rawgeti(L, tbl, 3)
	if !lua_isnil(L, -1) {
		ctx = luaL_ref(L, LUA_REGISTRYINDEX) // pops value
	} else {
		lua_pop(L, 1)
	}

	return
}
```

- [ ] **Step 2: Parse draggable/dropable in vbox node reading**

In `lua_read_node`, inside the `"vbox"` case (around line 462), add after the layout parsing block (before `return v`):

```odin
		v.draggable_group, v.draggable_event, v.draggable_ctx = lua_get_drag_drop(L, attrs_idx, "draggable")
		v.dropable_group, v.dropable_event, v.dropable_ctx = lua_get_drag_drop(L, attrs_idx, "dropable")
```

- [ ] **Step 3: Parse draggable/dropable in hbox node reading**

In `lua_read_node`, inside the `"hbox"` case (around line 496), add after the layout parsing block (before `return h`):

```odin
		h.draggable_group, h.draggable_event, h.draggable_ctx = lua_get_drag_drop(L, attrs_idx, "draggable")
		h.dropable_group, h.dropable_event, h.dropable_ctx = lua_get_drag_drop(L, attrs_idx, "dropable")
```

- [ ] **Step 4: Build to verify parsing compiles**

Run: `odin build src/host -out:build/redin`
Expected: Build succeeds

- [ ] **Step 5: Commit**

```bash
git add src/host/bridge/bridge.odin
git commit -m "feat: parse draggable/dropable attrs in bridge"
```

---

### Task 3: Add drag state and detection logic

**Files:**
- Create: `src/host/input/drag.odin`
- Modify: `src/host/input/input.odin:10-69` (extract_listeners)

- [ ] **Step 1: Create drag.odin with state and processing**

Create `src/host/input/drag.odin`:

```odin
package input

import "../types"
import rl "vendor:raylib"

DRAG_THRESHOLD :: 4.0

Drag_Source :: struct {
	group:       string,
	event:       string,
	context_ref: i32, // Lua registry ref to payload
}

// Drag state — package-level, like focused_idx
dragging_idx:   int = -1
drag_over_idx:  int = -1
drag_pending:   bool = false
drag_start_pos: rl.Vector2
drag_source:    Drag_Source

// Called each frame from the main loop, after poll() and before process_user_events.
// Returns dispatch events for drag-start and drop.
process_drag :: proc(
	input_events: []types.InputEvent,
	listeners: []types.Listener,
	nodes: []types.Node,
	node_rects: []rl.Rectangle,
) -> [dynamic]types.Dispatch_Event {
	dispatch: [dynamic]types.Dispatch_Event
	mouse := rl.GetMousePosition()

	// Phase 1: Check for new drag initiation (mouse press on a DragListener)
	if !drag_pending && dragging_idx == -1 {
		for event in input_events {
			me, is_mouse := event.(types.MouseEvent)
			if !is_mouse || me.button != .LEFT do continue
			pt := rl.Vector2{me.x, me.y}

			for listener in listeners {
				dl, ok := listener.(types.DragListener)
				if !ok do continue
				if dl.node_idx >= len(node_rects) do continue
				if !rl.CheckCollisionPointRec(pt, node_rects[dl.node_idx]) do continue

				// Hit a draggable node — enter pending state
				drag_pending = true
				drag_start_pos = pt

				// Read drag source info from the node
				switch n in nodes[dl.node_idx] {
				case types.NodeVbox:
					drag_source = {n.draggable_group, n.draggable_event, n.draggable_ctx}
					dragging_idx = dl.node_idx
				case types.NodeHbox:
					drag_source = {n.draggable_group, n.draggable_event, n.draggable_ctx}
					dragging_idx = dl.node_idx
				case types.NodeStack, types.NodeCanvas, types.NodeInput,
					types.NodeButton, types.NodeText, types.NodeImage,
					types.NodePopout, types.NodeModal:
				}
				break
			}
		}
	}

	// Phase 2: Pending → check threshold or cancel
	if drag_pending && dragging_idx >= 0 {
		if rl.IsMouseButtonDown(.LEFT) {
			dx := mouse.x - drag_start_pos.x
			dy := mouse.y - drag_start_pos.y
			dist_sq := dx * dx + dy * dy
			if dist_sq >= DRAG_THRESHOLD * DRAG_THRESHOLD {
				// Threshold crossed — now actively dragging
				drag_pending = false

				// Dispatch drag-start event
				if len(drag_source.event) > 0 {
					append(&dispatch, types.Dispatch_Event(types.Drag_Event{
						event_name  = drag_source.event,
						context_ref = drag_source.context_ref,
					}))
				}
			}
		} else {
			// Mouse released before threshold — cancel, treat as click
			drag_pending = false
			dragging_idx = -1
			drag_over_idx = -1
		}
	}

	// Phase 3: Active dragging — hit-test drop targets each frame
	if !drag_pending && dragging_idx >= 0 {
		if rl.IsMouseButtonDown(.LEFT) {
			// Update drag_over_idx by hit-testing DropListeners with matching group
			drag_over_idx = -1
			for listener in listeners {
				dl, ok := listener.(types.DropListener)
				if !ok do continue
				if dl.group != drag_source.group do continue
				if dl.node_idx >= len(node_rects) do continue
				if rl.CheckCollisionPointRec(mouse, node_rects[dl.node_idx]) {
					drag_over_idx = dl.node_idx
					break
				}
			}
		} else {
			// Mouse released — drop or cancel
			if drag_over_idx >= 0 {
				// Find the drop target's event name and payload
				drop_event := ""
				drop_ctx: i32 = 0
				switch n in nodes[drag_over_idx] {
				case types.NodeVbox:
					drop_event = n.dropable_event
					drop_ctx = n.dropable_ctx
				case types.NodeHbox:
					drop_event = n.dropable_event
					drop_ctx = n.dropable_ctx
				case types.NodeStack, types.NodeCanvas, types.NodeInput,
					types.NodeButton, types.NodeText, types.NodeImage,
					types.NodePopout, types.NodeModal:
				}

				if len(drop_event) > 0 {
					append(&dispatch, types.Dispatch_Event(types.Drop_Event{
						event_name = drop_event,
						from_ref   = drag_source.context_ref,
						to_ref     = drop_ctx,
					}))
				}
			}

			// Reset all drag state
			dragging_idx = -1
			drag_over_idx = -1
			drag_pending = false
			drag_source = {}
		}
	}

	return dispatch
}
```

- [ ] **Step 2: Extract DragListener and DropListener in extract_listeners**

In `src/host/input/input.odin`, inside the `extract_listeners` proc, add cases for NodeVbox and NodeHbox to create drag/drop listeners. Replace the current `case types.NodeVbox:` and `case types.NodeHbox:` blocks:

```odin
		case types.NodeVbox:
			aspect = n.aspect
			if len(n.draggable_group) > 0 {
				append(&listeners, types.Listener(types.DragListener{node_idx = idx}))
			}
			if len(n.dropable_group) > 0 {
				append(&listeners, types.Listener(types.DropListener{node_idx = idx, group = n.dropable_group}))
			}
		case types.NodeHbox:
			aspect = n.aspect
			if len(n.draggable_group) > 0 {
				append(&listeners, types.Listener(types.DragListener{node_idx = idx}))
			}
			if len(n.dropable_group) > 0 {
				append(&listeners, types.Listener(types.DropListener{node_idx = idx, group = n.dropable_group}))
			}
```

Also update the exhaustive switch in `apply.odin` to handle the new listener types. In `apply_listeners`, inside the switch on listeners (line 38), add cases for the new types:

```odin
				case types.HoverListener, types.KeyListener, types.ChangeListener,
					types.DragListener, types.DropListener:
```

And in `user_events.odin` line 55, update the exhaustive switch:

```odin
				case types.HoverListener, types.KeyListener, types.ChangeListener,
					types.DragListener, types.DropListener:
```

- [ ] **Step 3: Build to verify**

Run: `odin build src/host -out:build/redin`
Expected: Build succeeds

- [ ] **Step 4: Commit**

```bash
git add src/host/input/drag.odin src/host/input/input.odin src/host/input/apply.odin src/host/input/user_events.odin
git commit -m "feat: add drag state machine and listener extraction"
```

---

### Task 4: Deliver drag/drop events to Lua

**Files:**
- Modify: `src/host/bridge/bridge.odin:745-844` (deliver_dispatch_events)

- [ ] **Step 1: Add Drag_Event and Drop_Event delivery**

In `deliver_dispatch_events` in `src/host/bridge/bridge.odin`, add two new cases inside the `switch e in event` block (after the `case types.Key_Event_Dispatch:` block, before the closing `}`):

```odin
		case types.Drag_Event:
			// [:dispatch [:event-name {:value payload}]]
			lua_createtable(L, 2, 0)
			lua_pushstring(L, "dispatch")
			lua_rawseti(L, -2, 1)

			lua_createtable(L, 2, 0)
			ev_name := strings.clone_to_cstring(e.event_name, context.temp_allocator)
			lua_pushstring(L, ev_name)
			lua_rawseti(L, -2, 1)

			// Context: {:value payload}
			lua_createtable(L, 0, 1)
			if e.context_ref != 0 {
				lua_rawgeti(L, LUA_REGISTRYINDEX, e.context_ref)
			} else {
				lua_pushnil(L)
			}
			lua_setfield(L, -2, "value")
			lua_rawseti(L, -2, 2)

			lua_rawseti(L, -2, 2)
			lua_rawseti(L, -2, 1)

		case types.Drop_Event:
			// [:dispatch [:event-name {:from source-payload :to target-payload}]]
			lua_createtable(L, 2, 0)
			lua_pushstring(L, "dispatch")
			lua_rawseti(L, -2, 1)

			lua_createtable(L, 2, 0)
			ev_name := strings.clone_to_cstring(e.event_name, context.temp_allocator)
			lua_pushstring(L, ev_name)
			lua_rawseti(L, -2, 1)

			// Context: {:from source :to target}
			lua_createtable(L, 0, 2)
			if e.from_ref != 0 {
				lua_rawgeti(L, LUA_REGISTRYINDEX, e.from_ref)
			} else {
				lua_pushnil(L)
			}
			lua_setfield(L, -2, "from")
			if e.to_ref != 0 {
				lua_rawgeti(L, LUA_REGISTRYINDEX, e.to_ref)
			} else {
				lua_pushnil(L)
			}
			lua_setfield(L, -2, "to")
			lua_rawseti(L, -2, 2)

			lua_rawseti(L, -2, 2)
			lua_rawseti(L, -2, 1)
```

- [ ] **Step 2: Build to verify**

Run: `odin build src/host -out:build/redin`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add src/host/bridge/bridge.odin
git commit -m "feat: deliver drag/drop dispatch events to Lua"
```

---

### Task 5: Apply theme variants in renderer

**Files:**
- Modify: `src/host/render.odin:229-359` (draw_box)

- [ ] **Step 1: Apply #drag-start and #drag theme variants in draw_box**

In `src/host/render.odin`, inside `draw_box`, after loading the base aspect properties (the block starting at line 242 `if len(aspect) > 0`), add drag variant resolution. Replace the current block:

```odin
	if len(aspect) > 0 {
		if t, ok := theme[aspect]; ok {
			if t.bg != {} {
				bg := rl.Color{t.bg[0], t.bg[1], t.bg[2], 255}
				rl.DrawRectangleRec(rect, bg)
			}
			if t.padding != {} {
				content_rect = rl.Rectangle {
					rect.x + f32(t.padding[3]),
					rect.y + f32(t.padding[0]),
					rect.width - f32(t.padding[1]) - f32(t.padding[3]),
					rect.height - f32(t.padding[0]) - f32(t.padding[2]),
				}
			}
		}
	}
```

With:

```odin
	if len(aspect) > 0 {
		bg_color: rl.Color
		has_bg := false
		pad: [4]u8

		if t, ok := theme[aspect]; ok {
			if t.bg != {} {
				bg_color = rl.Color{t.bg[0], t.bg[1], t.bg[2], 255}
				has_bg = true
			}
			pad = t.padding
		}

		// Apply drag theme variants (override base)
		if input.dragging_idx == idx {
			drag_start_key := strings.concatenate({aspect, "#drag-start"}, context.temp_allocator)
			if dt, ok := theme[drag_start_key]; ok {
				if dt.bg != {} {
					bg_color = rl.Color{dt.bg[0], dt.bg[1], dt.bg[2], 255}
					has_bg = true
				}
				if dt.padding != {} do pad = dt.padding
			}
		}
		if input.drag_over_idx == idx {
			drag_key := strings.concatenate({aspect, "#drag"}, context.temp_allocator)
			if dt, ok := theme[drag_key]; ok {
				if dt.bg != {} {
					bg_color = rl.Color{dt.bg[0], dt.bg[1], dt.bg[2], 255}
					has_bg = true
				}
				if dt.padding != {} do pad = dt.padding
			}
		}

		if has_bg {
			rl.DrawRectangleRec(rect, bg_color)
		}
		if pad != {} {
			content_rect = rl.Rectangle {
				rect.x + f32(pad[3]),
				rect.y + f32(pad[0]),
				rect.width - f32(pad[1]) - f32(pad[3]),
				rect.height - f32(pad[0]) - f32(pad[2]),
			}
		}
	}
```

- [ ] **Step 2: Build to verify**

Run: `odin build src/host -out:build/redin`
Expected: Build succeeds

- [ ] **Step 3: Commit**

```bash
git add src/host/render.odin
git commit -m "feat: apply drag theme variants in box renderer"
```

---

### Task 6: Wire drag processing into main loop

**Files:**
- Modify: `src/host/main.odin:67-124`

- [ ] **Step 1: Call process_drag and deliver its events**

In `src/host/main.odin`, add the drag processing call after `apply_listeners` and before `process_user_events`. Insert after line 103 (after the focus leave block):

```odin
		// Process drag state machine
		drag_events := input.process_drag(
			input_events[:], listeners[:], b.nodes[:], node_rects[:],
		)
		defer delete(drag_events)
		bridge.deliver_dispatch_events(&b, drag_events[:])
```

The drag processing must happen before `process_user_events` so that drag-initiated clicks are consumed before being treated as regular clicks.

- [ ] **Step 2: Suppress click events during active drag**

In `src/host/input/drag.odin`, add a helper to check if a drag is active. At the top of the file after the state variables:

```odin
// Returns true if a drag gesture is in progress (pending or active).
// Used by the main loop to suppress normal click processing.
is_dragging :: proc() -> bool {
	return drag_pending || dragging_idx >= 0
}
```

In `src/host/input/user_events.odin`, inside `get_user_events`, guard the click/focus listener processing so it's skipped during a drag. Wrap the `case types.MouseEvent:` block inside the `for event in input_events` loop:

Replace line 33-34:

```odin
		case types.MouseEvent:
			if e.button != .LEFT do continue
```

With:

```odin
		case types.MouseEvent:
			if e.button != .LEFT do continue
			if is_dragging() do continue
```

This prevents click and focus events from firing when the user is dragging.

- [ ] **Step 3: Build and manually test with kitchen-sink**

Run: `odin build src/host -out:build/redin`
Expected: Build succeeds

Run: `./build/redin examples/kitchen-sink.fnl`
Expected: App launches. Dragging a row should show `#drag-start` theme variant on source, `#drag` on hover target. (Note: no event handlers registered yet in kitchen-sink, so no state changes on drop.)

- [ ] **Step 4: Commit**

```bash
git add src/host/main.odin src/host/input/drag.odin src/host/input/user_events.odin
git commit -m "feat: wire drag processing into main loop"
```

---

### Task 7: Write drag-and-drop test app

**Files:**
- Create: `test/ui/drag_app.fnl`

- [ ] **Step 1: Write the test app**

Create `test/ui/drag_app.fnl`:

```fennel
;; Test app for drag-and-drop UI tests
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:surface {:bg [46 52 64] :padding [24 24 24 24]}
   :body    {:font-size 14 :color [216 222 233]}
   :row     {:padding [4 4 4 4]}
   :row#drag {:bg [76 86 106]}
   :row#drag-start {:bg [136 46 106]}})

(dataflow.init
  {:items [{:text "A"} {:text "B"} {:text "C"} {:text "D"}]
   :last-drag nil
   :last-drop nil})

(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :event/drag
  (fn [db event]
    (let [ctx (. event 2)]
      (assoc db :last-drag ctx.value))))

(reg-handler :event/drop
  (fn [db event]
    (let [ctx (. event 2)]
      (assoc db :last-drop {:from ctx.from :to ctx.to})
      ;; Reorder items: move item at :from to position :to
      (let [from-idx ctx.from
            to-idx ctx.to
            items (get db :items [])]
        (when (and from-idx to-idx
                   (> from-idx 0) (<= from-idx (length items))
                   (> to-idx 0) (<= to-idx (length items))
                   (not= from-idx to-idx))
          (let [item (. items from-idx)
                new-items (icollect [i v (ipairs items)]
                            (when (not= i from-idx) v))]
            ;; Insert at to-idx (adjust if removing shifted indices)
            (let [insert-at (if (> from-idx to-idx) to-idx (- to-idx 1))]
              (table.insert new-items (math.min insert-at (+ (length new-items) 1)) item)
              (assoc db :items new-items)))))
      db)))

(reg-handler :event/reset
  (fn [db event]
    (assoc (assoc (assoc db :items [{:text "A"} {:text "B"} {:text "C"} {:text "D"}])
                  :last-drag nil)
           :last-drop nil)))

(reg-sub :items (fn [db] (get db :items [])))
(reg-sub :last-drag (fn [db] (get db :last-drag)))
(reg-sub :last-drop (fn [db] (get db :last-drop)))

(global main_view
  (fn []
    (let [items (subscribe :items)
          last-drag (subscribe :last-drag)
          last-drop (subscribe :last-drop)]
      [:vbox {:aspect :surface}
       [:text {:id :title :aspect :body} "Drag Test"]
       [:text {:id :last-drag-val :aspect :body}
        (.. "drag:" (tostring (or last-drag "")))]
       [:text {:id :last-drop-from :aspect :body}
        (.. "drop-from:" (tostring (or (and last-drop last-drop.from) "")))]
       [:text {:id :last-drop-to :aspect :body}
        (.. "drop-to:" (tostring (or (and last-drop last-drop.to) "")))]
       [:vbox {:id :item-list}
        (icollect [i item (ipairs (or items []))]
          [:hbox {:id (.. :row- (tostring i))
                  :aspect :row
                  :height 42
                  :draggable [:row :event/drag i]
                  :dropable [:row :event/drop i]}
           [:text {:id (.. :item- (tostring i)) :aspect :body} item.text]])]])))
```

- [ ] **Step 2: Verify test app loads**

Run: `./build/redin test/ui/drag_app.fnl`
Expected: Window opens showing "Drag Test" with items A, B, C, D listed vertically. Close the window manually.

- [ ] **Step 3: Commit**

```bash
git add test/ui/drag_app.fnl
git commit -m "test: add drag-and-drop test app"
```

---

### Task 8: Write UI tests

**Files:**
- Create: `test/ui/test_drag.bb`

- [ ] **Step 1: Write the test file**

Create `test/ui/test_drag.bb`:

```clojure
(require '[redin-test :refer :all])

;; -- Frame structure --

(deftest drag-items-exist
  (let [items (find-elements {:tag :hbox :aspect :row})]
    (assert (= 4 (count items)) (str "Expected 4 row items, got " (count items)))))

(deftest items-have-text
  (assert-element {:tag :text :id :item-1 :text "A"})
  (assert-element {:tag :text :id :item-2 :text "B"})
  (assert-element {:tag :text :id :item-3 :text "C"})
  (assert-element {:tag :text :id :item-4 :text "D"}))

;; -- Drag event --

(deftest drag-event-updates-state
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/drag" {:value 2}])
  (wait-for (state= "last-drag" 2) {:timeout 2000}))

;; -- Drop event --

(deftest drop-event-updates-state
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/drop" {:from 1 :to 3}])
  (wait-ms 200)
  (assert-state "last-drop.from" #(= % 1) "drop from should be 1")
  (assert-state "last-drop.to" #(= % 3) "drop to should be 3"))

(deftest drop-reorders-items
  (dispatch ["event/reset"])
  (wait-ms 200)
  ;; Move item 1 (A) to position 3
  (dispatch ["event/drop" {:from 1 :to 3}])
  (wait-ms 300)
  ;; After moving A from 1 to 3: [B, A, C, D]
  (assert-element {:tag :text :id :item-1 :text "B"})
  (assert-element {:tag :text :id :item-2 :text "A"})
  (assert-element {:tag :text :id :item-3 :text "C"})
  (assert-element {:tag :text :id :item-4 :text "D"}))

;; -- Reset --

(deftest reset-clears-drag-state
  (dispatch ["event/drag" {:value 1}])
  (wait-ms 100)
  (dispatch ["event/reset"])
  (wait-for (state= "last-drag" nil) {:timeout 2000})
  (assert-state "last-drop" nil? "Reset should clear last-drop"))

(deftest reset-restores-items
  (dispatch ["event/drop" {:from 1 :to 3}])
  (wait-ms 200)
  (dispatch ["event/reset"])
  (wait-ms 200)
  (assert-element {:tag :text :id :item-1 :text "A"})
  (assert-element {:tag :text :id :item-2 :text "B"})
  (assert-element {:tag :text :id :item-3 :text "C"})
  (assert-element {:tag :text :id :item-4 :text "D"}))
```

- [ ] **Step 2: Run UI tests**

Start the dev server:
```bash
./build/redin --dev test/ui/drag_app.fnl &
sleep 1
```

Run the tests:
```bash
bb test/ui/run.bb test/ui/test_drag.bb
```

Expected: All 7 tests pass.

Stop the dev server:
```bash
curl -s -X POST http://localhost:8800/shutdown
```

- [ ] **Step 3: Commit**

```bash
git add test/ui/test_drag.bb
git commit -m "test: add drag-and-drop UI tests"
```

---

### Task 9: Update docs and kitchen-sink handlers

**Files:**
- Modify: `docs/reference/theme.md` (add drag variants to state table)
- Modify: `examples/kitchen-sink.fnl` (add drag/drop event handlers)

- [ ] **Step 1: Add drag variants to theme docs**

In `docs/reference/theme.md`, in the State Variants table, add:

| State | Suffix | Trigger |
|-------|--------|---------|
| drag-start | `#drag-start` | Node is being dragged |
| drag | `#drag` | Compatible drag hovers over this drop target |

- [ ] **Step 2: Add drag/drop handlers to kitchen-sink**

In `examples/kitchen-sink.fnl`, add handlers after the existing `:test/remove` handler:

```fennel
(reg-handler :event/drag (fn [db event] db))

(reg-handler :event/drop
  (fn [db event]
    (let [ctx (. event 2)
          from-idx ctx.from
          to-idx ctx.to
          items (get db :items [])]
      (when (and from-idx to-idx
                 (> from-idx 0) (<= from-idx (length items))
                 (> to-idx 0) (<= to-idx (length items))
                 (not= from-idx to-idx))
        (let [item (. items from-idx)
              new-items (icollect [i v (ipairs items)]
                          (when (not= i from-idx) v))]
          (let [insert-at (if (> from-idx to-idx) to-idx (- to-idx 1))]
            (table.insert new-items (math.min insert-at (+ (length new-items) 1)) item)
            (assoc db :items new-items)))))
    db))
```

- [ ] **Step 3: Build and verify kitchen-sink**

Run: `odin build src/host -out:build/redin && ./build/redin examples/kitchen-sink.fnl`
Expected: Drag-and-drop reordering works visually in the todo list.

- [ ] **Step 4: Commit**

```bash
git add docs/reference/theme.md examples/kitchen-sink.fnl
git commit -m "docs: add drag theme variants, add kitchen-sink drag handlers"
```

---

### Task 10: Run all tests to verify nothing is broken

- [ ] **Step 1: Run Fennel runtime tests**

Run: `luajit test/lua/runner.lua test/lua/test_*.fnl`
Expected: All 95 tests pass

- [ ] **Step 2: Run UI tests (all)**

```bash
./build/redin --dev test/ui/drag_app.fnl &
sleep 1
bb test/ui/run.bb test/ui/test_drag.bb
curl -s -X POST http://localhost:8800/shutdown
sleep 1
```

Expected: All drag tests pass

- [ ] **Step 3: Verify build is clean**

Run: `odin build src/host -out:build/redin`
Expected: Clean build, no warnings
