# Drag-and-Drop v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generalise drag/drop around tag-set matching, an options-map attribute shape, aspect swaps in place of the v1 `#`-cascade, and a `:preview` clone overlay pass that reuses `:animate` machinery — covering inventory-style use cases (multiple drop targets with different acceptance rules and a tactile preview).

**Architecture:** v1's positional `[:group :event payload]` API and `aspect#drag-start` / `aspect#drag` theme cascade are replaced by `[tags {options-map} payload]` and ordinary aspect swaps. Drag state lives in `input/drag.odin` as a tagged union (`Drag_Idle | Drag_Pending | Drag_Active`). The renderer adds one overlay pass after `:animate :above` that re-renders the dragged subtree at the cursor, click-through. `:animate` gates on drag state for the new fields (`drag_animate`, `drop_animate`, `over_animate`).

**Tech Stack:** Odin (host/renderer/bridge), Raylib, LuaJIT, Fennel. Spec: `docs/superpowers/specs/2026-04-28-drag-and-drop-v2-design.md`. Out-of-scope tracker: [#90](https://github.com/sstoehrm/redin/issues/90).

**Conventions used in this plan:**
- Build command: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
- UI test command: `bash test/ui/run-all.sh --headless` (run from repo root; needs `xvfb-run`)
- Single UI suite: `./build/redin --dev test/ui/<app>.fnl &` then `bb test/ui/run.bb test/ui/test_<name>.bb` then `curl -s -X POST -H "Authorization: Bearer $(cat .redin-token)" http://localhost:$(cat .redin-port)/shutdown`
- Migration is performed in a single PR; the v1 API stops working at task 17 ("Delete v1 fields"). Tasks 1–16 keep v1 working alongside v2 so the build stays green at every commit.

---

## Task 1: Add `Drag_Mode`, `Drag_Attrs`, listener tags, `DragOverListener`, `Drag_Over_Event`

Additive scaffolding. v1 fields stay; v2 fields go in next to them. Build must pass; nothing wired up yet.

**Files:**
- Modify: `src/redin/types/view_tree.odin`
- Modify: `src/redin/types/listener_events.odin`
- Modify: `src/redin/types/input_events.odin`

- [ ] **Step 1: Add `Drag_Mode` and `Drag_Attrs` to `view_tree.odin`**

In `src/redin/types/view_tree.odin`, after the `Animate_Decoration` struct (around line 47):

```odin
Drag_Mode :: enum u8 {
    Preview,    // default — clone of dragged subtree at cursor
    None,       // no clone — source receives aspect/animate in place
}

// Bundled drag/drop/over fields embedded in container nodes via `using`.
Drag_Attrs :: struct {
    // :draggable — declares "what I am" + how I behave while dragged.
    drag_tags:    []string,                  // owned slice of cloned strings
    drag_event:   string,                    // owned, freed by clear_node_strings
    drag_mode:    Drag_Mode,                 // zero = .Preview
    drag_aspect:  string,                    // owned
    drag_animate: Maybe(Animate_Decoration), // owned provider string inside
    drag_ctx:     i32,                       // Lua registry ref (0 = none)

    // :dropable — declares "what I accept" + how it looks on hover.
    drop_tags:    []string,
    drop_event:   string,
    drop_aspect:  string,
    drop_animate: Maybe(Animate_Decoration),
    drop_ctx:     i32,

    // :drag-over — container-level zone (no payload).
    over_tags:    []string,
    over_event:   string,
    over_aspect:  string,
    over_animate: Maybe(Animate_Decoration),
}
```

Embed `using drag: Drag_Attrs` in `NodeVbox` and `NodeHbox`. **Keep the v1 fields** (`draggable_group`, `draggable_event`, `draggable_ctx`, `dropable_group`, `dropable_event`, `dropable_ctx`) — they're deleted in task 17 once nothing references them.

After: NodeVbox and NodeHbox have both v1 (`draggable_group: string`, ...) and v2 (`using drag: Drag_Attrs`) fields side-by-side.

- [ ] **Step 2: Add `tags` to listeners + `DragOverListener` in `listener_events.odin`**

In `src/redin/types/listener_events.odin`:

```odin
DragListener :: struct {
    node_idx: int,
    tags:     []string,         // borrowed from node; lives until next clear_frame
}

DropListener :: struct {
    node_idx: int,
    group:    string,           // v1 — deleted in task 17
    tags:     []string,         // v2 — borrowed from node, freed by clear_node_strings
}

DragOverListener :: struct {
    node_idx: int,
    tags:     []string,
}
```

Add `DragOverListener` to the `Listener` union. Keep `group` on `DropListener` so v1 callers in `extract_listeners` (task 12 swaps them over) still compile.

- [ ] **Step 3: Add `Drag_Over_Event` to `input_events.odin`**

In `src/redin/types/input_events.odin`:

```odin
Drag_Over_Event :: struct {
    event_name: string,
    phase:      Drag_Over_Phase,
}

Drag_Over_Phase :: enum {
    Enter,
    Leave,
}
```

Add `Drag_Over_Event` to the `Dispatch_Event` union.

- [ ] **Step 4: Build verifies**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: clean build. v1 fields stay alongside v2 fields; v1 listener path still works.

- [ ] **Step 5: Commit**

```bash
git add src/redin/types/
git commit -m "feat(types): scaffold Drag_Attrs, listener tags, Drag_Over_Event"
```

---

## Task 2: Add `lua_read_tags` helper

Helper that reads slot 1 of a drag attribute (single keyword OR vector of keywords) into an owned `[]string`. Used by all three v2 parsers in tasks 3–5.

**Files:**
- Modify: `src/redin/bridge/bridge.odin`

- [ ] **Step 1: Add the helper near `lua_get_drag_drop`**

Find `lua_get_drag_drop` (around line 1834 in bridge.odin). Above it, add:

```odin
// Reads slot at `slot_idx` of the table at `tbl_idx` as a tag list:
//   - a string keyword → one-element slice
//   - a Lua array of strings → cloned multi-element slice
//   - anything else → empty slice
// Returned strings are heap-cloned and owned by the caller (freed by
// clear_node_strings via Drag_Attrs cleanup).
lua_read_tags :: proc(L: ^Lua_State, tbl_idx: i32, slot_idx: i32) -> []string {
    lua_rawgeti(L, tbl_idx, slot_idx)
    defer lua_pop(L, 1)

    if lua_isstring(L, -1) {
        out := make([]string, 1)
        out[0] = strings.clone_from_cstring(lua_tostring_raw(L, -1))
        return out
    }

    if lua_istable(L, -1) {
        n := int(lua_objlen(L, -1))
        if n == 0 do return nil
        list_idx := lua_gettop(L)
        out := make([]string, n)
        count := 0
        for i in 1..=n {
            lua_rawgeti(L, list_idx, i32(i))
            if lua_isstring(L, -1) {
                out[count] = strings.clone_from_cstring(lua_tostring_raw(L, -1))
                count += 1
            }
            lua_pop(L, 1)
        }
        if count < n do return out[:count]
        return out
    }

    return nil
}
```

- [ ] **Step 2: Build verifies**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add src/redin/bridge/bridge.odin
git commit -m "feat(bridge): lua_read_tags — single-keyword or vector"
```

---

## Task 3: Add `lua_read_draggable` parser

Reads `[tags {options} payload]` from `:draggable`, populates the draggable-half of `Drag_Attrs`. Not wired in yet.

**Files:**
- Modify: `src/redin/bridge/bridge.odin`

- [ ] **Step 1: Add the parser below `lua_read_tags`**

```odin
// Parse `:draggable [tags {options} payload]`. Populates the drag_* fields
// of `out`. On error, fields stay zero and an error is logged.
lua_read_draggable :: proc(L: ^Lua_State, attrs_idx: i32, out: ^types.Drag_Attrs) {
    if attrs_idx <= 0 do return
    lua_getfield(L, attrs_idx, "draggable")
    defer lua_pop(L, 1)
    if !lua_istable(L, -1) do return
    tbl := lua_gettop(L)

    // Slot 1 — tags
    out.drag_tags = lua_read_tags(L, tbl, 1)
    if len(out.drag_tags) == 0 {
        fmt.eprintln(":draggable: missing or empty tag list, skipping")
        return
    }

    // Slot 2 — options table
    lua_rawgeti(L, tbl, 2)
    if !lua_istable(L, -1) {
        lua_pop(L, 1)
        fmt.eprintln(":draggable: expected options table at slot 2, skipping")
        return
    }
    opts := lua_gettop(L)

    // :event (required)
    lua_getfield(L, opts, "event")
    if lua_isstring(L, -1) {
        out.drag_event = strings.clone_from_cstring(lua_tostring_raw(L, -1))
    }
    lua_pop(L, 1)
    if len(out.drag_event) == 0 {
        fmt.eprintln(":draggable: missing :event in options, skipping")
        lua_pop(L, 1)  // pop opts
        return
    }

    // :mode (optional, default Preview)
    lua_getfield(L, opts, "mode")
    if lua_isstring(L, -1) {
        s := string(lua_tostring_raw(L, -1))
        switch s {
        case "preview": out.drag_mode = .Preview
        case "none":    out.drag_mode = .None
        case:           fmt.eprintfln(":draggable: unknown :mode %q, defaulting to :preview", s)
        }
    }
    lua_pop(L, 1)

    // :aspect (optional)
    lua_getfield(L, opts, "aspect")
    if lua_isstring(L, -1) {
        out.drag_aspect = strings.clone_from_cstring(lua_tostring_raw(L, -1))
    }
    lua_pop(L, 1)

    // :animate (optional, reuse parse_animate_attr against the options table)
    if dec, ok := parse_animate_attr(L, opts); ok {
        out.drag_animate = dec
    }

    lua_pop(L, 1)  // pop opts

    // Slot 3 — payload (any Lua value, stored as registry ref)
    lua_rawgeti(L, tbl, 3)
    if !lua_isnil(L, -1) {
        out.drag_ctx = luaL_ref(L, LUA_REGISTRYINDEX)  // pops value
    } else {
        lua_pop(L, 1)
    }
}
```

Note: `parse_animate_attr` already reads `lua_getfield(L, attrs_idx, "animate")` internally — verify by reading bridge.odin:859 before assuming. If it expects the `:animate` key on the *passed* table (not a parent), it's compatible; if not, factor a sibling `parse_animate_attr_at(L, table_idx)` and call that with `opts`.

- [ ] **Step 2: Verify `parse_animate_attr` is reusable**

Read `src/redin/bridge/bridge.odin:859-932`. The proc opens `lua_getfield(L, attrs_idx, "animate")` itself — it expects to receive the parent attrs table and look up the `animate` key inside. That works for our case (we pass `opts`, which has `:animate` as a key). No factoring needed.

- [ ] **Step 3: Build verifies**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add src/redin/bridge/bridge.odin
git commit -m "feat(bridge): lua_read_draggable parser (options-map shape)"
```

---

## Task 4: Add `lua_read_dropable` parser

Same shape as draggable, fewer fields (no mode).

**Files:**
- Modify: `src/redin/bridge/bridge.odin`

- [ ] **Step 1: Add the parser below `lua_read_draggable`**

```odin
// Parse `:dropable [tags {options} payload]`.
lua_read_dropable :: proc(L: ^Lua_State, attrs_idx: i32, out: ^types.Drag_Attrs) {
    if attrs_idx <= 0 do return
    lua_getfield(L, attrs_idx, "dropable")
    defer lua_pop(L, 1)
    if !lua_istable(L, -1) do return
    tbl := lua_gettop(L)

    out.drop_tags = lua_read_tags(L, tbl, 1)
    if len(out.drop_tags) == 0 {
        fmt.eprintln(":dropable: missing or empty tag list, skipping")
        return
    }

    lua_rawgeti(L, tbl, 2)
    if !lua_istable(L, -1) {
        lua_pop(L, 1)
        fmt.eprintln(":dropable: expected options table at slot 2, skipping")
        return
    }
    opts := lua_gettop(L)

    lua_getfield(L, opts, "event")
    if lua_isstring(L, -1) {
        out.drop_event = strings.clone_from_cstring(lua_tostring_raw(L, -1))
    }
    lua_pop(L, 1)
    if len(out.drop_event) == 0 {
        fmt.eprintln(":dropable: missing :event in options, skipping")
        lua_pop(L, 1)
        return
    }

    lua_getfield(L, opts, "aspect")
    if lua_isstring(L, -1) {
        out.drop_aspect = strings.clone_from_cstring(lua_tostring_raw(L, -1))
    }
    lua_pop(L, 1)

    if dec, ok := parse_animate_attr(L, opts); ok {
        out.drop_animate = dec
    }

    lua_pop(L, 1)

    lua_rawgeti(L, tbl, 3)
    if !lua_isnil(L, -1) {
        out.drop_ctx = luaL_ref(L, LUA_REGISTRYINDEX)
    } else {
        lua_pop(L, 1)
    }
}
```

- [ ] **Step 2: Build verifies**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add src/redin/bridge/bridge.odin
git commit -m "feat(bridge): lua_read_dropable parser"
```

---

## Task 5: Add `lua_read_drag_over` parser

Like draggable/dropable but no payload slot.

**Files:**
- Modify: `src/redin/bridge/bridge.odin`

- [ ] **Step 1: Add the parser below `lua_read_dropable`**

```odin
// Parse `:drag-over [tags {options}]` (no payload slot).
lua_read_drag_over :: proc(L: ^Lua_State, attrs_idx: i32, out: ^types.Drag_Attrs) {
    if attrs_idx <= 0 do return
    lua_getfield(L, attrs_idx, "drag-over")
    defer lua_pop(L, 1)
    if !lua_istable(L, -1) do return
    tbl := lua_gettop(L)

    out.over_tags = lua_read_tags(L, tbl, 1)
    if len(out.over_tags) == 0 {
        fmt.eprintln(":drag-over: missing or empty tag list, skipping")
        return
    }

    lua_rawgeti(L, tbl, 2)
    if !lua_istable(L, -1) {
        lua_pop(L, 1)
        return
    }
    opts := lua_gettop(L)

    // :event is OPTIONAL on :drag-over (visual-only zones don't need a handler)
    lua_getfield(L, opts, "event")
    if lua_isstring(L, -1) {
        out.over_event = strings.clone_from_cstring(lua_tostring_raw(L, -1))
    }
    lua_pop(L, 1)

    lua_getfield(L, opts, "aspect")
    if lua_isstring(L, -1) {
        out.over_aspect = strings.clone_from_cstring(lua_tostring_raw(L, -1))
    }
    lua_pop(L, 1)

    if dec, ok := parse_animate_attr(L, opts); ok {
        out.over_animate = dec
    }

    lua_pop(L, 1)
}
```

- [ ] **Step 2: Build verifies**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add src/redin/bridge/bridge.odin
git commit -m "feat(bridge): lua_read_drag_over parser"
```

---

## Task 6: Wire v2 parsers into `lua_read_node` for vbox/hbox

Populate `Drag_Attrs` alongside v1 fields. Both shapes are populated; consumers still read v1.

**Files:**
- Modify: `src/redin/bridge/bridge.odin`

- [ ] **Step 1: Wire into vbox case**

In `lua_read_node`, vbox case (around line 1088), after the existing `lua_get_drag_drop` calls add v2 reads. Final shape:

```odin
case "vbox":
    v: types.NodeVbox
    if attrs_idx > 0 {
        // ... existing reads of overflow/aspect/width/height/layout ...

        // v1 (deleted in task 17)
        v.draggable_group, v.draggable_event, v.draggable_ctx = lua_get_drag_drop(L, attrs_idx, "draggable")
        v.dropable_group, v.dropable_event, v.dropable_ctx = lua_get_drag_drop(L, attrs_idx, "dropable")

        // v2
        lua_read_draggable(L, attrs_idx, &v.drag)
        lua_read_dropable (L, attrs_idx, &v.drag)
        lua_read_drag_over(L, attrs_idx, &v.drag)
    }
    return v
```

`v.drag` is the embedded `Drag_Attrs`.

- [ ] **Step 2: Wire into hbox case**

Same pattern in the hbox branch (around line 1119):

```odin
case "hbox":
    h: types.NodeHbox
    if attrs_idx > 0 {
        // ... existing reads ...

        h.draggable_group, h.draggable_event, h.draggable_ctx = lua_get_drag_drop(L, attrs_idx, "draggable")
        h.dropable_group, h.dropable_event, h.dropable_ctx = lua_get_drag_drop(L, attrs_idx, "dropable")

        lua_read_draggable(L, attrs_idx, &h.drag)
        lua_read_dropable (L, attrs_idx, &h.drag)
        lua_read_drag_over(L, attrs_idx, &h.drag)
    }
    return h
```

- [ ] **Step 3: Build verifies**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add src/redin/bridge/bridge.odin
git commit -m "feat(bridge): populate Drag_Attrs alongside v1 fields"
```

---

## Task 7: Cleanup `Drag_Attrs` in `clear_node_strings`

Free everything we own when the frame is rebuilt.

**Files:**
- Modify: `src/redin/bridge/bridge.odin`

- [ ] **Step 1: Add a helper next to `clear_node_strings`**

In `bridge.odin`, around line 119 (above `clear_node_strings`):

```odin
clear_drag_attrs :: proc(d: ^types.Drag_Attrs) {
    for s in d.drag_tags do delete(s)
    if d.drag_tags != nil do delete(d.drag_tags)
    if len(d.drag_event) > 0 do delete(d.drag_event)
    if len(d.drag_aspect) > 0 do delete(d.drag_aspect)
    if dec, ok := d.drag_animate.?; ok && len(dec.provider) > 0 do delete(dec.provider)
    if d.drag_ctx != 0 do luaL_unref(g_bridge.L, LUA_REGISTRYINDEX, d.drag_ctx)

    for s in d.drop_tags do delete(s)
    if d.drop_tags != nil do delete(d.drop_tags)
    if len(d.drop_event) > 0 do delete(d.drop_event)
    if len(d.drop_aspect) > 0 do delete(d.drop_aspect)
    if dec, ok := d.drop_animate.?; ok && len(dec.provider) > 0 do delete(dec.provider)
    if d.drop_ctx != 0 do luaL_unref(g_bridge.L, LUA_REGISTRYINDEX, d.drop_ctx)

    for s in d.over_tags do delete(s)
    if d.over_tags != nil do delete(d.over_tags)
    if len(d.over_event) > 0 do delete(d.over_event)
    if len(d.over_aspect) > 0 do delete(d.over_aspect)
    if dec, ok := d.over_animate.?; ok && len(dec.provider) > 0 do delete(dec.provider)

    d^ = {}
}
```

Note: v1 already releases `draggable_ctx` / `dropable_ctx` via `luaL_unref` somewhere — confirm by grepping `luaL_unref` in bridge.odin and matching the pattern. If v1 doesn't, that's a pre-existing leak; it's still released here for v2.

```bash
grep -n "luaL_unref\|draggable_ctx\|dropable_ctx" src/redin/bridge/bridge.odin
```

- [ ] **Step 2: Call the helper in `clear_node_strings`**

In the `NodeVbox` and `NodeHbox` cases:

```odin
case types.NodeVbox:
    if len(v.overflow) > 0 do delete(v.overflow)
    if len(v.aspect) > 0 do delete(v.aspect)
    // v1
    if len(v.draggable_group) > 0 do delete(v.draggable_group)
    if len(v.draggable_event) > 0 do delete(v.draggable_event)
    if len(v.dropable_group) > 0 do delete(v.dropable_group)
    if len(v.dropable_event) > 0 do delete(v.dropable_event)
    // v2
    {
        d := v.drag
        clear_drag_attrs(&d)
    }
case types.NodeHbox:
    // … same pattern …
```

(`v` is a non-pointer copy from the switch, so we copy `v.drag` to a local before passing to clear; the storage in the dynamic array is gone after `clear_frame` deletes the slice anyway.)

- [ ] **Step 3: Build + memory check**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: clean build.

Run: `./build/redin --dev --track-mem test/ui/drag_app.fnl`, click around for 5 seconds, then send a shutdown:
```bash
sleep 5; curl -s -X POST -H "Authorization: Bearer $(cat .redin-token)" http://localhost:$(cat .redin-port)/shutdown
```

Expected: tracking-allocator report shows zero outstanding allocations on shutdown (or only allocations that were already there before this task — eyeball the diff).

- [ ] **Step 4: Commit**

```bash
git add src/redin/bridge/bridge.odin
git commit -m "feat(bridge): free Drag_Attrs in clear_node_strings"
```

---

## Task 8: Deliver `Drag_Over_Event` in `deliver_dispatch_events`

Push enter/leave events into the Lua dispatch pipeline.

**Files:**
- Modify: `src/redin/bridge/bridge.odin`

- [ ] **Step 1: Add the case in the switch**

In `deliver_dispatch_events` (around line 1456 in bridge.odin), add a new switch arm after `Drop_Event`:

```odin
case types.Drag_Over_Event:
    // [:dispatch [:event-name {:phase :enter|:leave}]]
    lua_createtable(L, 2, 0)
    lua_pushstring(L, "dispatch")
    lua_rawseti(L, -2, 1)

    lua_createtable(L, 2, 0)
    ev_name := strings.clone_to_cstring(e.event_name, context.temp_allocator)
    lua_pushstring(L, ev_name)
    lua_rawseti(L, -2, 1)

    // {:phase :enter} or {:phase :leave}
    lua_createtable(L, 0, 1)
    phase: cstring = e.phase == .Enter ? "enter" : "leave"
    lua_pushstring(L, phase)
    lua_setfield(L, -2, "phase")
    lua_rawseti(L, -2, 2)

    lua_rawseti(L, -2, 2)
    lua_rawseti(L, -2, 1)
```

- [ ] **Step 2: Build verifies**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add src/redin/bridge/bridge.odin
git commit -m "feat(bridge): deliver Drag_Over_Event with :phase"
```

---

## Task 9: Add `Drag_State` union and predicates

Add the new state machine types alongside the v1 globals. v1 globals stay for now (used by v1 `process_drag` until task 11 swaps the implementation).

**Files:**
- Modify: `src/redin/input/drag.odin`

- [ ] **Step 1: Add types and predicates above existing globals**

In `src/redin/input/drag.odin`, near the top after the imports:

```odin
// ---- v2 state machine ----

Drag_Captured :: struct {
    src_idx:     int,
    start_pos:   rl.Vector2,
    src_tags:    []string,                       // borrowed from node
    src_event:   string,
    src_mode:    types.Drag_Mode,
    src_aspect:  string,
    src_animate: Maybe(types.Animate_Decoration),
    src_ctx_ref: i32,
}

Drag_Idle    :: struct {}

Drag_Pending :: struct {
    using captured: Drag_Captured,
}

Drag_Active :: struct {
    using captured: Drag_Captured,
    over_zone_idx:  int,        // -1 if no zone hovered
    over_drop_idx:  int,        // -1 if no drop cell hovered
}

Drag_State :: union { Drag_Idle, Drag_Pending, Drag_Active }

drag: Drag_State = Drag_Idle{}
```

The single global `drag` is the v2 state. v1 globals (`dragging_idx`, `drag_over_idx`, `drag_pending`, `drag_start_pos`, `drag_source`) stay in place for now — render.odin reads them until task 14, which deletes those reads. Task 17 then deletes the globals themselves. Predicate procs aren't needed; consumers do `drag.(Drag_Active)` inline.

- [ ] **Step 2: Build verifies**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: clean build (predicates currently unused — that's fine).

- [ ] **Step 3: Commit**

```bash
git add src/redin/input/drag.odin
git commit -m "feat(input): Drag_State tagged union + predicates"
```

---

## Task 10: Add tag-match helpers

Pure functions for tag intersection and depth-aware listener selection by tag match.

**Files:**
- Modify: `src/redin/input/drag.odin`

- [ ] **Step 1: Add helpers below the predicates**

```odin
// True iff src and target share at least one tag.
drag_matches :: proc(src, target: []string) -> bool {
    for s in src do for t in target do if s == t do return true
    return false
}

// Deepest matching DropListener under `pt` whose tags overlap `src_tags`.
// Deepest = highest node_idx (DFS-ordered nodes guarantee descendants > ancestors).
deepest_dropable_match :: proc(
    src_tags: []string,
    pt: rl.Vector2,
    listeners: []types.Listener,
    node_rects: []rl.Rectangle,
) -> int {
    best := -1
    for listener in listeners {
        l, ok := listener.(types.DropListener)
        if !ok do continue
        if !drag_matches(src_tags, l.tags) do continue
        if l.node_idx < 0 || l.node_idx >= len(node_rects) do continue
        if l.node_idx <= best do continue
        if !rl.CheckCollisionPointRec(pt, node_rects[l.node_idx]) do continue
        best = l.node_idx
    }
    return best
}

// Deepest matching DragOverListener under `pt`.
deepest_drag_over_match :: proc(
    src_tags: []string,
    pt: rl.Vector2,
    listeners: []types.Listener,
    node_rects: []rl.Rectangle,
) -> int {
    best := -1
    for listener in listeners {
        l, ok := listener.(types.DragOverListener)
        if !ok do continue
        if !drag_matches(src_tags, l.tags) do continue
        if l.node_idx < 0 || l.node_idx >= len(node_rects) do continue
        if l.node_idx <= best do continue
        if !rl.CheckCollisionPointRec(pt, node_rects[l.node_idx]) do continue
        best = l.node_idx
    }
    return best
}
```

- [ ] **Step 2: Build verifies**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add src/redin/input/drag.odin
git commit -m "feat(input): tag-match + deepest-listener helpers"
```

---

## Task 11: Replace `process_drag` body with state-machine version

Swap the v1 imperative flow for the union-driven state machine. Read v2 fields off the node's `Drag_Attrs`. The existing v1 globals (`dragging_idx`, `drag_over_idx`, `drag_pending`, `drag_start_pos`, `drag_source`) stop being written. The only external readers are render.odin's `#`-cascade blocks (lines 291, 295, 552, 559), which read `input.dragging_idx` / `input.drag_over_idx`. Those reads will see the initial `-1` and the `#`-cascade lookups simply won't fire — that's fine because task 14 deletes those blocks anyway. Visual drag-highlighting between task 11 and task 14 won't work for two-three commits; this is acceptable because the dispatch-based UI tests don't depend on it.

**Files:**
- Modify: `src/redin/input/drag.odin`

- [ ] **Step 1: Replace `process_drag` with the state-machine version**

```odin
process_drag :: proc(
    input_events: []types.InputEvent,
    listeners: []types.Listener,
    nodes: []types.Node,
    node_rects: []rl.Rectangle,
) -> [dynamic]types.Dispatch_Event {
    dispatch: [dynamic]types.Dispatch_Event
    mouse := rl.GetMousePosition()

    switch &s in drag {
    case Drag_Idle:
        // Mouse-down on a DragListener → Pending.
        for event in input_events {
            me, is_mouse := event.(types.MouseEvent)
            if !is_mouse || me.button != .LEFT do continue
            pt := rl.Vector2{me.x, me.y}

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
                src_tags  = tags,
            }
            switch n in nodes[winner] {
            case types.NodeVbox:
                cap.src_event   = n.drag_event
                cap.src_mode    = n.drag_mode
                cap.src_aspect  = n.drag_aspect
                cap.src_animate = n.drag_animate
                cap.src_ctx_ref = n.drag_ctx
            case types.NodeHbox:
                cap.src_event   = n.drag_event
                cap.src_mode    = n.drag_mode
                cap.src_aspect  = n.drag_aspect
                cap.src_animate = n.drag_animate
                cap.src_ctx_ref = n.drag_ctx
            case types.NodeStack, types.NodeCanvas, types.NodeInput,
                 types.NodeButton, types.NodeText, types.NodeImage,
                 types.NodePopout, types.NodeModal:
            }
            if len(cap.src_event) == 0 do continue

            drag = Drag_Pending{captured = cap}
            break
        }

    case Drag_Pending:
        if rl.IsMouseButtonDown(.LEFT) {
            dx := mouse.x - s.start_pos.x
            dy := mouse.y - s.start_pos.y
            if dx*dx + dy*dy >= DRAG_THRESHOLD * DRAG_THRESHOLD {
                if len(s.src_event) > 0 {
                    append(&dispatch, types.Dispatch_Event(types.Drag_Event{
                        event_name  = s.src_event,
                        context_ref = s.src_ctx_ref,
                    }))
                }
                drag = Drag_Active{
                    captured      = s.captured,
                    over_zone_idx = -1,
                    over_drop_idx = -1,
                }
            }
        } else {
            drag = Drag_Idle{}
        }

    case Drag_Active:
        // Re-flatten safety: if the source idx no longer points at a draggable
        // with our tags, cancel.
        if s.src_idx < 0 || s.src_idx >= len(nodes) {
            drag = Drag_Idle{}
            return dispatch
        }

        // Hit-test compatible drop targets and zones.
        new_zone := deepest_drag_over_match(s.src_tags, mouse, listeners, node_rects)
        new_drop := deepest_dropable_match (s.src_tags, mouse, listeners, node_rects)

        // Enter/leave on zone transitions.
        if new_zone != s.over_zone_idx {
            if s.over_zone_idx >= 0 {
                if ev := node_over_event(nodes[s.over_zone_idx]); len(ev) > 0 {
                    append(&dispatch, types.Dispatch_Event(types.Drag_Over_Event{
                        event_name = ev,
                        phase      = .Leave,
                    }))
                }
            }
            if new_zone >= 0 {
                if ev := node_over_event(nodes[new_zone]); len(ev) > 0 {
                    append(&dispatch, types.Dispatch_Event(types.Drag_Over_Event{
                        event_name = ev,
                        phase      = .Enter,
                    }))
                }
            }
            s.over_zone_idx = new_zone
        }
        s.over_drop_idx = new_drop

        if !rl.IsMouseButtonDown(.LEFT) {
            // Drop dispatch.
            if new_drop >= 0 {
                drop_event := ""
                drop_ctx: i32 = 0
                switch n in nodes[new_drop] {
                case types.NodeVbox:
                    drop_event = n.drop_event
                    drop_ctx   = n.drop_ctx
                case types.NodeHbox:
                    drop_event = n.drop_event
                    drop_ctx   = n.drop_ctx
                case types.NodeStack, types.NodeCanvas, types.NodeInput,
                     types.NodeButton, types.NodeText, types.NodeImage,
                     types.NodePopout, types.NodeModal:
                }
                if len(drop_event) > 0 {
                    append(&dispatch, types.Dispatch_Event(types.Drop_Event{
                        event_name = drop_event,
                        from_ref   = s.src_ctx_ref,
                        to_ref     = drop_ctx,
                    }))
                }
            }

            // Final :leave on the active zone.
            if s.over_zone_idx >= 0 {
                if ev := node_over_event(nodes[s.over_zone_idx]); len(ev) > 0 {
                    append(&dispatch, types.Dispatch_Event(types.Drag_Over_Event{
                        event_name = ev,
                        phase      = .Leave,
                    }))
                }
            }

            drag = Drag_Idle{}
        }
    }

    return dispatch
}

// Helper — extract :drag-over event name from a node, "" if not a container or no event.
node_over_event :: proc(n: types.Node) -> string {
    switch v in n {
    case types.NodeVbox: return v.over_event
    case types.NodeHbox: return v.over_event
    case types.NodeStack, types.NodeCanvas, types.NodeInput,
         types.NodeButton, types.NodeText, types.NodeImage,
         types.NodePopout, types.NodeModal:
        return ""
    }
    return ""
}
```

- [ ] **Step 2: Update `is_dragging` to consult the union**

Find the existing `is_dragging` proc near the bottom of `drag.odin`:

```odin
is_dragging :: proc() -> bool {
    return drag_pending || dragging_idx >= 0
}
```

Replace with:

```odin
is_dragging :: proc() -> bool {
    switch _ in drag {
    case Drag_Pending, Drag_Active: return true
    case Drag_Idle:                 return false
    }
    return false
}
```

`is_dragging` is called from `src/redin/input/user_events.odin:35` (suppresses synthetic click while a drag is active). After this change it returns `true` for both Pending and Active, matching v1's `drag_pending || dragging_idx >= 0` semantics.

- [ ] **Step 3: Build verifies**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: clean build.

- [ ] **Step 4: UI smoke**

Run the full UI suite to ensure existing drag behaviour still works (extract_listeners hasn't changed yet, so DropListener still uses v1 `group: string`, but this task only changes when matches happen — between mouse-down and release. For now drag matching uses tags from `DragListener.tags`, which v1's extract_listeners doesn't populate; so drag won't actually trigger. That's expected — task 12 fixes this. To unblock testing, this task is build-verified only; full UI run-all happens after task 12.

Run: `odin build ...` (already ran in step 3) — accept build-only verification for this task.

- [ ] **Step 5: Commit**

```bash
git add src/redin/input/drag.odin
git commit -m "feat(input): replace process_drag with Drag_State machine"
```

---

## Task 12: Update `extract_listeners` to populate tags + emit `DragOverListener`

Switch the listener producer to read v2 fields. After this task, the new state machine in task 11 receives populated `DragListener.tags` and the existing UI tests start passing again under v2.

**Files:**
- Modify: `src/redin/input/input.odin`

- [ ] **Step 1: Update vbox/hbox cases in `extract_listeners`**

In `src/redin/input/input.odin:42-117`, the vbox and hbox cases currently use the v1 fields. Replace:

```odin
case types.NodeVbox:
    aspect = n.aspect
    if len(n.drag_tags) > 0 && len(n.drag_event) > 0 {
        append(&listeners, types.Listener(types.DragListener{
            node_idx = idx, tags = n.drag_tags,
        }))
    }
    if len(n.drop_tags) > 0 && len(n.drop_event) > 0 {
        append(&listeners, types.Listener(types.DropListener{
            node_idx = idx, tags = n.drop_tags, group = "",
        }))
    }
    if len(n.over_tags) > 0 {
        append(&listeners, types.Listener(types.DragOverListener{
            node_idx = idx, tags = n.over_tags,
        }))
    }
case types.NodeHbox:
    aspect = n.aspect
    if len(n.drag_tags) > 0 && len(n.drag_event) > 0 {
        append(&listeners, types.Listener(types.DragListener{
            node_idx = idx, tags = n.drag_tags,
        }))
    }
    if len(n.drop_tags) > 0 && len(n.drop_event) > 0 {
        append(&listeners, types.Listener(types.DropListener{
            node_idx = idx, tags = n.drop_tags, group = "",
        }))
    }
    if len(n.over_tags) > 0 {
        append(&listeners, types.Listener(types.DragOverListener{
            node_idx = idx, tags = n.over_tags,
        }))
    }
```

(`group = ""` keeps the v1 field on `DropListener` populated but harmless until task 17 deletes it.)

- [ ] **Step 2: Update `deepest_listener_idx` to consider `DragOverListener`**

In `input.odin:18-40`, add `DragOverListener` to the listener idx switch:

```odin
case types.DragOverListener:    idx = l.node_idx
```

(So mouse-down inside an `:drag-over` zone with no inner draggable doesn't accidentally swallow the event — actually, `:drag-over` should NOT compete for click winners since it's purely a passive zone. Re-think: keep the switch as-is and exclude `DragOverListener`. The state machine queries it directly via `deepest_drag_over_match`, not via `deepest_listener_idx`.)

After re-thinking: do NOT add `DragOverListener` to the click winner switch. It only participates in `deepest_drag_over_match`.

- [ ] **Step 3: Build + test**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: clean build.

UI test: `test_drag.bb` still uses v1 attrs, so the test app file (`drag_app.fnl`) still emits v1 attrs — neither v1 nor v2 listener path will fire. The existing test suite uses dispatch-based tests (no real drag), so it should still pass:

Run a single drag-test cycle:
```bash
./build/redin --dev test/ui/drag_app.fnl &
sleep 1
bb test/ui/run.bb test/ui/test_drag.bb
curl -s -X POST -H "Authorization: Bearer $(cat .redin-token)" http://localhost:$(cat .redin-port)/shutdown
```

Expected: all 7 tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/redin/input/input.odin
git commit -m "feat(input): extract_listeners reads Drag_Attrs + emits DragOverListener"
```

---

## Task 13: Refactor draw procs to accept rect parameter

Prerequisite for `render_drag_preview`. `draw_box_chrome` currently takes a rect (good); `draw_button`, `draw_text`, `draw_input`, `draw_themed_rect` already take rect. The tree-walker `draw_node` reads `node_rects[idx]` and passes the rect down. We need an *alternate* walker that takes a translation delta and per-node rects from a side computation.

This task only adds an internal helper (`draw_subtree_translated`); does not yet expose it externally.

**Files:**
- Modify: `src/redin/render.odin`

- [ ] **Step 1: Add `draw_subtree_translated` helper**

Below `draw_node` in `render.odin`:

```odin
// Render the subtree rooted at `idx` translated by `delta` and clipping
// no rects — used by the drag preview overlay. Does not write node_rects /
// node_content_rects, so the clone is click-through.
//
// `override_aspect_for_root` is applied to the root if non-empty (lets the
// preview clone use a different aspect than the source).
draw_subtree_translated :: proc(
    idx: int,
    delta: rl.Vector2,
    override_aspect_for_root: string,
    nodes: []types.Node,
    children_list: []types.Children,
    theme: map[string]types.Theme,
) {
    if idx < 0 || idx >= len(nodes) do return
    rect := node_rects[idx]
    rect.x += delta.x
    rect.y += delta.y
    content_rect := node_content_rects[idx]
    content_rect.x += delta.x
    content_rect.y += delta.y

    is_root := len(override_aspect_for_root) > 0

    switch n in nodes[idx] {
    case types.NodeStack:
        draw_subtree_children_translated(idx, delta, nodes, children_list, theme)
    case types.NodeVbox:
        aspect := is_root ? override_aspect_for_root : n.aspect
        draw_box_chrome(idx, rect, aspect, theme)
        draw_subtree_children_translated(idx, delta, nodes, children_list, theme)
    case types.NodeHbox:
        aspect := is_root ? override_aspect_for_root : n.aspect
        draw_box_chrome(idx, rect, aspect, theme)
        draw_subtree_children_translated(idx, delta, nodes, children_list, theme)
    case types.NodeButton:
        b := n
        if is_root do b.aspect = override_aspect_for_root
        draw_button(rect, b, theme)
    case types.NodeText:
        // Pass idx = -1 — the proc treats negative idx as "no selection,
        // no scroll-offset persistence" (see step 2 of this task).
        t := n
        if is_root do t.aspect = override_aspect_for_root
        draw_text(-1, rect, t, theme)
    case types.NodeImage:
        aspect := is_root ? override_aspect_for_root : n.aspect
        draw_themed_rect(rect, aspect, theme)
        rl.DrawRectangleLinesEx(rect, 1, rl.GRAY)
    case types.NodeCanvas:
        // Canvas providers paint into content_rect — translation is enough.
        if len(n.provider) > 0 do canvas.process(n.provider, content_rect)
    case types.NodeInput:
        // Inputs in the preview clone aren't focusable; render as a styled rect.
        draw_themed_rect(rect, n.aspect, theme)
    case types.NodePopout, types.NodeModal:
        // Popouts/modals don't make sense inside a drag preview; skip.
    }
}

draw_subtree_children_translated :: proc(
    idx: int,
    delta: rl.Vector2,
    nodes: []types.Node,
    children_list: []types.Children,
    theme: map[string]types.Theme,
) {
    ch := children_list[idx]
    for i in 0 ..< int(ch.length) {
        // Children take the source's normal aspect, not the override —
        // override only applies to the clone root.
        draw_subtree_translated(int(ch.value[i]), delta, "", nodes, children_list, theme)
    }
}
```

- [ ] **Step 2: Make `draw_text` safe to call with `idx = -1`**

`draw_text` (render.odin:1121) takes `(idx, rect, n, theme)` and uses `idx` for three things: text-line cache lookup (`text_pkg.lookup_lines(idx, ...)` — safe on negative idx, just misses), scroll-offset map reads/writes (`scroll_offsets[idx]` — would write garbage at -1), and selection highlight via `g_paths[idx]` (out-of-bounds at -1 because the existing guard `idx < len(g_paths)` is true for -1).

Wrap the scroll-offset and selection blocks with an `if idx >= 0 {` guard. Specifically:

```odin
// Around line 1166-1182 (scrollable_y / scrollable_x reads of scroll_offsets):
scroll_y: f32 = 0
scroll_x: f32 = 0
if idx >= 0 {
    if scrollable_y {
        scroll_y = scroll_offsets[idx] if idx in scroll_offsets else 0
        // ... existing scroll logic ...
        scroll_offsets[idx] = scroll_y
    }
    if scrollable_x {
        scroll_x = scroll_offsets_x[idx] if idx in scroll_offsets_x else 0
    }
}

// Around line 1201 (selection):
if idx >= 0 && input.state.selection_kind == .Text && idx < len(g_paths) {
    // ... existing selection-highlight block ...
}
```

The text-line cache lookup is already safe on negative idx (the path returns `(_, false)` and falls through to `compute_lines`).

- [ ] **Step 3: Build verifies**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add src/redin/render.odin
git commit -m "feat(render): draw_subtree_translated for drag preview clone"
```

---

## Task 14: Replace `#`-cascade with aspect-swap + animate gating

This is the user-visible visual delta. Delete the `aspect#drag-start` / `aspect#drag` lookups; add aspect swap based on drag state; gate the new drag-conditional `:animate` decorations.

**Files:**
- Modify: `src/redin/render.odin`

- [ ] **Step 1: Delete `#`-cascade in `draw_box_chrome` (~line 540)**

Find this block in `draw_box_chrome`:

```odin
if input.dragging_idx == idx {
    drag_start_key := strings.concatenate({aspect, "#drag-start"}, context.temp_allocator)
    if dt, ok := theme[drag_start_key]; ok && dt.bg != {} {
        bg_color = rl.Color{dt.bg[0], dt.bg[1], dt.bg[2], 255}
        has_bg = true
    }
}
if input.drag_over_idx == idx {
    drag_key := strings.concatenate({aspect, "#drag"}, context.temp_allocator)
    if dt, ok := theme[drag_key]; ok && dt.bg != {} {
        bg_color = rl.Color{dt.bg[0], dt.bg[1], dt.bg[2], 255}
        has_bg = true
    }
}
```

Delete it entirely.

Also delete the equivalent block in `layout_node` (~line 290):

```odin
if input.dragging_idx == idx {
    drag_start_key := strings.concatenate({aspect, "#drag-start"}, context.temp_allocator)
    if dt, ok := theme[drag_start_key]; ok && dt.padding != {} do pad = dt.padding
}
if input.drag_over_idx == idx {
    drag_key := strings.concatenate({aspect, "#drag"}, context.temp_allocator)
    if dt, ok := theme[drag_key]; ok && dt.padding != {} do pad = dt.padding
}
```

Delete both.

- [ ] **Step 2: Add `effective_aspect_for_drag` helper**

Add near the top of render.odin (after imports):

```odin
// Resolve which aspect the renderer should use for `idx` taking active drag
// state into account. Returns the original aspect when nothing applies.
effective_aspect_for_drag :: proc(idx: int, base_aspect: string, n: types.Node) -> string {
    a, ok := input.drag.(input.Drag_Active)
    if !ok do return base_aspect

    // Source node in :none mode swaps to drag aspect.
    if a.src_idx == idx && a.src_mode == .None && len(a.src_aspect) > 0 {
        return a.src_aspect
    }
    // Drop target currently hovered swaps to drop aspect.
    if a.over_drop_idx == idx {
        switch v in n {
        case types.NodeVbox: if len(v.drop_aspect) > 0 do return v.drop_aspect
        case types.NodeHbox: if len(v.drop_aspect) > 0 do return v.drop_aspect
        case types.NodeStack, types.NodeCanvas, types.NodeInput,
             types.NodeButton, types.NodeText, types.NodeImage,
             types.NodePopout, types.NodeModal:
        }
    }
    // Container zone hovered swaps to over aspect.
    if a.over_zone_idx == idx {
        switch v in n {
        case types.NodeVbox: if len(v.over_aspect) > 0 do return v.over_aspect
        case types.NodeHbox: if len(v.over_aspect) > 0 do return v.over_aspect
        case types.NodeStack, types.NodeCanvas, types.NodeInput,
             types.NodeButton, types.NodeText, types.NodeImage,
             types.NodePopout, types.NodeModal:
        }
    }
    return base_aspect
}
```

- [ ] **Step 3: Use `effective_aspect_for_drag` at vbox/hbox draw sites**

In `draw_node`'s vbox/hbox cases (~line 455):

```odin
case types.NodeVbox:
    aspect := effective_aspect_for_drag(idx, n.aspect, nodes[idx])
    draw_box_chrome(idx, rect, aspect, theme)
    draw_box_children(idx, content_rect, n.overflow, true, nodes, children_list, theme)
case types.NodeHbox:
    aspect := effective_aspect_for_drag(idx, n.aspect, nodes[idx])
    draw_box_chrome(idx, rect, aspect, theme)
    draw_box_children(idx, content_rect, n.overflow, false, nodes, children_list, theme)
```

Apply the same swap inside `layout_node`'s vbox/hbox padding lookup (~line 290) — pass the effective aspect into the padding-resolution path.

- [ ] **Step 4: Add animate gating**

In `draw_node`, the existing `:animate :behind` block (~line 444):

```odin
if bridge.g_bridge != nil && idx < len(bridge.g_bridge.node_animations) {
    if dec, has := bridge.g_bridge.node_animations[idx].?; has && dec.z == .Behind {
        drect := resolve_decoration_rect(dec.rect, rect)
        canvas.process(dec.provider, drect)
    }
}
```

Right after this block, add gated drag-conditional :behind animates:

```odin
// Drag-state-gated :animate (drop_animate, over_animate) on :behind layer.
if a, ok := input.drag.(input.Drag_Active); ok {
    // Drop target's :animate fires when this idx is the active drop.
    if a.over_drop_idx == idx {
        if dec, ok := node_drop_animate(nodes[idx]).?; ok && dec.z == .Behind {
            drect := resolve_decoration_rect(dec.rect, rect)
            canvas.process(dec.provider, drect)
        }
    }
    if a.over_zone_idx == idx {
        if dec, ok := node_over_animate(nodes[idx]).?; ok && dec.z == .Behind {
            drect := resolve_decoration_rect(dec.rect, rect)
            canvas.process(dec.provider, drect)
        }
    }
    // Source's drag_animate in :none mode (preview-mode animate runs on the clone, not here)
    if a.src_idx == idx && a.src_mode == .None {
        if dec, ok := node_drag_animate(nodes[idx]).?; ok && dec.z == .Behind {
            drect := resolve_decoration_rect(dec.rect, rect)
            canvas.process(dec.provider, drect)
        }
    }
}
```

Repeat the same pattern in the `:above` block (~line 511) but checking `.Above` instead of `.Behind`. Add helpers:

```odin
node_drag_animate :: proc(n: types.Node) -> Maybe(types.Animate_Decoration) {
    switch v in n {
    case types.NodeVbox: return v.drag_animate
    case types.NodeHbox: return v.drag_animate
    case types.NodeStack, types.NodeCanvas, types.NodeInput,
         types.NodeButton, types.NodeText, types.NodeImage,
         types.NodePopout, types.NodeModal:
    }
    return nil
}
node_drop_animate :: proc(n: types.Node) -> Maybe(types.Animate_Decoration) {
    switch v in n {
    case types.NodeVbox: return v.drop_animate
    case types.NodeHbox: return v.drop_animate
    case types.NodeStack, types.NodeCanvas, types.NodeInput,
         types.NodeButton, types.NodeText, types.NodeImage,
         types.NodePopout, types.NodeModal:
    }
    return nil
}
node_over_animate :: proc(n: types.Node) -> Maybe(types.Animate_Decoration) {
    switch v in n {
    case types.NodeVbox: return v.over_animate
    case types.NodeHbox: return v.over_animate
    case types.NodeStack, types.NodeCanvas, types.NodeInput,
         types.NodeButton, types.NodeText, types.NodeImage,
         types.NodePopout, types.NodeModal:
    }
    return nil
}
```

- [ ] **Step 5: Build verifies**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: clean build.

- [ ] **Step 6: Commit**

```bash
git add src/redin/render.odin
git commit -m "feat(render): aspect-swap + drag animate gating, drop #-cascade"
```

---

## Task 15: Add `render_drag_preview` overlay pass + wire into runtime

The clone-at-cursor render. Runs after `draw_tree`.

**Files:**
- Modify: `src/redin/render.odin`
- Modify: `src/redin/runtime.odin`

- [ ] **Step 1: Add `render_drag_preview` to render.odin**

```odin
DRAG_PREVIEW_OFFSET :: f32(8)

render_drag_preview :: proc(
    nodes: []types.Node,
    children_list: []types.Children,
    theme: map[string]types.Theme,
) {
    a, ok := input.drag.(input.Drag_Active)
    if !ok || a.src_mode != .Preview do return
    if a.src_idx < 0 || a.src_idx >= len(nodes) do return
    if a.src_idx >= len(node_rects) do return

    src_rect := node_rects[a.src_idx]
    mouse    := rl.GetMousePosition()
    delta    := rl.Vector2{
        x = mouse.x - src_rect.x - DRAG_PREVIEW_OFFSET,
        y = mouse.y - src_rect.y - DRAG_PREVIEW_OFFSET,
    }

    draw_subtree_translated(a.src_idx, delta, a.src_aspect, nodes, children_list, theme)

    // :animate on the clone (overlay layer).
    if dec, ok := a.src_animate.?; ok {
        translated := rl.Rectangle{
            src_rect.x + delta.x,
            src_rect.y + delta.y,
            src_rect.width,
            src_rect.height,
        }
        drect := resolve_decoration_rect(dec.rect, translated)
        canvas.process(dec.provider, drect)
    }
}
```

- [ ] **Step 2: Wire into the main render loop**

In `src/redin/runtime.odin:286-288`:

```odin
s_render := profile.begin(.Render)
draw_tree(b.theme, b.nodes[:], b.children_list[:])
render_drag_preview(b.nodes[:], b.children_list[:], b.theme)
profile.end(s_render)
```

- [ ] **Step 3: Build verifies**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: clean build.

- [ ] **Step 4: Commit**

```bash
git add src/redin/render.odin src/redin/runtime.odin
git commit -m "feat(render): render_drag_preview overlay pass"
```

---

## Task 16: Migrate `test/ui/drag_app.fnl` and add new test cases

Switch the test app to v2 attrs, keep existing dispatch-based tests passing, add cases for tags / drag-over / cancel.

**Files:**
- Modify: `test/ui/drag_app.fnl`
- Modify: `test/ui/test_drag.bb`

- [ ] **Step 1: Migrate `drag_app.fnl`**

Replace the file's body so:

- The theme drops `:row#drag` and `:row#drag-start`; adds `:row-dragging` and `:row-drop-hot`.
- Items are tagged `[:item :sword]` (i % 2 == 0) or `[:item :shield]` (odd) — for testing tag matching.
- Each row has `:draggable [tags {options} payload]` and `:dropable [tags {options} payload]`.
- The container has `:drag-over [:item {options}]`.
- New handler `:event/over` records the last `{:phase ...}` it saw.

Final file:

```fennel
;; Test app for drag-and-drop UI tests (v2 API)
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:surface       {:bg [46 52 64] :padding [24 24 24 24]}
   :body          {:font-size 14 :color [216 222 233]}
   :row           {:padding [4 4 4 4]}
   :row-dragging  {:bg [136 46 106] :padding [4 4 4 4] :radius 4}
   :row-drop-hot  {:bg [76 86 106] :padding [4 4 4 4]}
   :muted         {:font-size 13 :color [76 86 106]}
   :muted-armed   {:font-size 13 :color [76 86 106] :bg [54 60 72]}})

(dataflow.init
  {:items [{:text "A" :kind :sword}
           {:text "B" :kind :shield}
           {:text "C" :kind :sword}
           {:text "D" :kind :shield}]
   :last-drag nil
   :last-drop nil
   :last-over nil})

(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :event/drag
  (fn [db event]
    (let [ctx (. event 2)]
      (assoc db :last-drag ctx.value))))

(reg-handler :event/over
  (fn [db event]
    (let [ctx (. event 2)]
      (assoc db :last-over ctx.phase))))

(reg-handler :event/drop
  (fn [db event]
    (let [ctx (. event 2)
          from-idx ctx.from
          to-idx   ctx.to
          items    (get db :items [])]
      (assoc db :last-drop {:from from-idx :to to-idx})
      (when (and from-idx to-idx
                 (> from-idx 0) (<= from-idx (length items))
                 (> to-idx 0)   (<= to-idx (length items))
                 (not= from-idx to-idx))
        (let [item (. items from-idx)
              new-items (icollect [i v (ipairs items)]
                          (when (not= i from-idx) v))]
          (let [insert-at (if (> from-idx to-idx) to-idx (- to-idx 1))]
            (table.insert new-items (math.min insert-at (+ (length new-items) 1)) item)
            (assoc db :items new-items))))
      db)))

(reg-handler :event/reset
  (fn [db event]
    (-> db
        (assoc :items [{:text "A" :kind :sword}
                       {:text "B" :kind :shield}
                       {:text "C" :kind :sword}
                       {:text "D" :kind :shield}])
        (assoc :last-drag nil)
        (assoc :last-drop nil)
        (assoc :last-over nil))))

(reg-sub :items     (fn [db] (get db :items [])))
(reg-sub :last-drag (fn [db] (get db :last-drag)))
(reg-sub :last-drop (fn [db] (get db :last-drop)))
(reg-sub :last-over (fn [db] (get db :last-over)))

(global main_view
  (fn []
    (let [items (subscribe :items)]
      [:vbox {:aspect :surface}
       [:text {:id :title :aspect :body} "Drag Test v2"]
       [:vbox {:id :item-list
               :aspect :muted
               :drag-over [:item {:event :event/over :aspect :muted-armed}]}
        (icollect [i item (ipairs (or items []))]
          [:hbox {:id (.. :row- (tostring i))
                  :aspect :row
                  :height 42
                  :draggable [[:item item.kind]
                              {:mode :preview
                               :event :event/drag
                               :aspect :row-dragging}
                              i]
                  :dropable [[:item item.kind]
                             {:event :event/drop
                              :aspect :row-drop-hot}
                             i]}
           [:text {:id (.. :item- (tostring i)) :aspect :body} item.text]])]])))
```

- [ ] **Step 2: Verify existing tests still pass**

```bash
./build/redin --dev test/ui/drag_app.fnl &
sleep 1
bb test/ui/run.bb test/ui/test_drag.bb
curl -s -X POST -H "Authorization: Bearer $(cat .redin-token)" http://localhost:$(cat .redin-port)/shutdown
```

Expected: all 7 existing tests pass (they dispatch events directly, agnostic to attribute shape).

- [ ] **Step 3: Add new test cases to `test_drag.bb`**

Append at the bottom of `test/ui/test_drag.bb`:

```clojure
;; -- Drag-over phase events --

(deftest drag-over-enter-fires
  (dispatch ["event/reset"])
  (wait-ms 200)
  ;; Synthesise an :event/over with :phase :enter (the framework would fire
  ;; this when a compatible drag enters the zone; here we test the handler
  ;; receives it correctly)
  (dispatch ["event/over" {:phase "enter"}])
  (wait-for (state= "last-over" "enter") {:timeout 2000}))

(deftest drag-over-leave-fires
  (dispatch ["event/over" {:phase "leave"}])
  (wait-for (state= "last-over" "leave") {:timeout 2000}))

;; -- Tag-aware drop --

(deftest drop-shape-includes-tags-context
  ;; The framework filters drops by tag intersection; here the handler
  ;; just receives :from / :to. This case verifies the handler still gets
  ;; the right shape after the API change.
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/drop" {:from 1 :to 4}])
  (wait-ms 200)
  (assert-state "last-drop.from" #(= % 1) "from preserved")
  (assert-state "last-drop.to"   #(= % 4) "to preserved"))
```

- [ ] **Step 4: Run new + existing test suite**

```bash
./build/redin --dev test/ui/drag_app.fnl &
sleep 1
bb test/ui/run.bb test/ui/test_drag.bb
curl -s -X POST -H "Authorization: Bearer $(cat .redin-token)" http://localhost:$(cat .redin-port)/shutdown
```

Expected: 10 tests pass (7 original + 3 new).

- [ ] **Step 5: Commit**

```bash
git add test/ui/drag_app.fnl test/ui/test_drag.bb
git commit -m "test(drag): migrate to v2 API, add :drag-over phase cases"
```

---

## Task 17: Delete v1 fields, globals, and `lua_get_drag_drop`

The big cleanup. After this task, the v1 API is gone — the migration error (per the spec) takes effect.

**Files:**
- Modify: `src/redin/types/view_tree.odin`
- Modify: `src/redin/types/listener_events.odin`
- Modify: `src/redin/input/drag.odin`
- Modify: `src/redin/bridge/bridge.odin`

- [ ] **Step 1: Remove v1 fields from `NodeVbox` / `NodeHbox`**

Delete these from both structs in `view_tree.odin`:

```odin
draggable_group: string,
draggable_event: string,
draggable_ctx:   i32,
dropable_group:  string,
dropable_event:  string,
dropable_ctx:    i32,
```

The `using drag: Drag_Attrs` stays.

- [ ] **Step 2: Remove `group: string` from `DropListener`**

In `listener_events.odin`:

```odin
DropListener :: struct {
    node_idx: int,
    tags:     []string,    // only field besides node_idx now
}
```

Update any references that read `.group` (there shouldn't be any after task 12).

- [ ] **Step 3: Remove v1 globals from `input/drag.odin`**

Delete the v1 globals and the `Drag_Source` struct:

```odin
dragging_idx:   int = -1
drag_over_idx:  int = -1
drag_pending:   bool = false
drag_start_pos: rl.Vector2
drag_source:    Drag_Source

Drag_Source :: struct { ... }
```

Verify no external reads remain:

```bash
grep -rn "input\.dragging_idx\|input\.drag_over_idx\|input\.drag_pending\|input\.drag_source" src/
```

Expected: zero matches (task 14 deleted the last reads in render.odin).

- [ ] **Step 4: Remove `lua_get_drag_drop` and v1 wiring in `lua_read_node`**

In bridge.odin:

- Delete the `lua_get_drag_drop` proc (around line 1834).
- In the `vbox` and `hbox` cases, remove the v1 lines:

```odin
v.draggable_group, v.draggable_event, v.draggable_ctx = lua_get_drag_drop(L, attrs_idx, "draggable")
v.dropable_group, v.dropable_event, v.dropable_ctx = lua_get_drag_drop(L, attrs_idx, "dropable")
```

Keep only the v2 reads (`lua_read_draggable`, `lua_read_dropable`, `lua_read_drag_over`).

- [ ] **Step 5: Remove v1 cleanup in `clear_node_strings`**

In bridge.odin's `clear_node_strings`, remove the v1 lines from the vbox and hbox cases:

```odin
if len(v.draggable_group) > 0 do delete(v.draggable_group)
if len(v.draggable_event) > 0 do delete(v.draggable_event)
if len(v.dropable_group) > 0 do delete(v.dropable_group)
if len(v.dropable_event) > 0 do delete(v.dropable_event)
```

Keep only the `clear_drag_attrs(&d)` call (which handles all v2 fields).

- [ ] **Step 6: Update extract_listeners**

In `input/input.odin`, the `DropListener` push site no longer needs `group = ""`:

```odin
append(&listeners, types.Listener(types.DropListener{
    node_idx = idx, tags = n.drop_tags,
}))
```

- [ ] **Step 7: Build + full UI test suite**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: clean build.

```bash
bash test/ui/run-all.sh --headless
```

Expected: full UI test suite passes (drag suite has 10 tests; total suite count depends on existing apps).

```bash
luajit test/lua/runner.lua test/lua/test_*.fnl
```

Expected: all 122 runtime tests pass.

- [ ] **Step 8: Commit**

```bash
git add src/redin/types/ src/redin/input/ src/redin/bridge/
git commit -m "refactor: delete v1 drag/drop fields, globals, and parser"
```

---

## Task 18: Commit kitchen-sink working-tree edits

Already prepared in the working tree from the brainstorming session. Just commit.

**Files:**
- Modify: `examples/kitchen-sink.fnl`

- [ ] **Step 1: Verify the working tree matches the v2 API**

```bash
git diff examples/kitchen-sink.fnl
```

Expected diff (already in place from brainstorming):
- `:row#drag` / `:row#drag-start` removed; `:row-dragging`, `:row-drop-hot`, `:muted-armed` added.
- `:drag-over [:row-drag {:event :event/over :aspect :muted-armed}]` on the scroll-y vbox.
- `:draggable [:row-drag {:mode :preview :event :event/drag :aspect :row-dragging :animate {...}} i]` on each row.
- `:dropable [:row-drag {:event :event/drop :aspect :row-drop-hot} i]` on each row.

If the diff doesn't match (someone re-edited mid-implementation), restore from this design's section 1 sketch.

- [ ] **Step 2: Smoke test it runs**

```bash
./build/redin --dev examples/kitchen-sink.fnl &
sleep 2
curl -s -H "Authorization: Bearer $(cat .redin-token)" http://localhost:$(cat .redin-port)/frames | head -c 200
curl -s -X POST -H "Authorization: Bearer $(cat .redin-token)" http://localhost:$(cat .redin-port)/shutdown
```

Expected: a JSON frame body emitted to stdout (proves the example loads without parser errors).

- [ ] **Step 3: Commit**

```bash
git add examples/kitchen-sink.fnl
git commit -m "example(kitchen-sink): migrate drag/drop to v2 API"
```

---

## Task 19: Update docs

Public docs and the in-tree skill must reflect v2.

**Files:**
- Modify: `docs/core-api.md`
- Modify: `docs/reference/elements.md`
- Modify: `docs/reference/theme.md`
- Modify: `.claude/skills/redin-dev/SKILL.md`

- [ ] **Step 1: Update `docs/reference/theme.md`**

Find the variant table at lines 155-156 in current main:

```
| drag-start | `#drag-start` | Node is being dragged                  |
| drag       | `#drag`       | Compatible drag hovers over drop target |
```

Delete both rows. Add a paragraph after the variant table explaining that drag/drop visual feedback is no longer expressed via theme cascades — it lives on the `:draggable` / `:dropable` / `:drag-over` attributes' `:aspect` field, which swaps to a regular aspect entry. Cross-reference `docs/core-api.md` § Drag-and-drop.

- [ ] **Step 2: Update `docs/core-api.md`**

Find the existing drag-and-drop section. Replace with a v2-shaped section:

````markdown
### Drag-and-drop

Three universal attributes; all share `[tags {options} ?payload]`:

- `:draggable [tags {options} payload]` — declares "what I am" + how the element behaves while dragged. Required: `:event`. Optional: `:mode` (`:preview` (default) | `:none`), `:aspect`, `:animate`.
- `:dropable [tags {options} payload]` — declares "what I accept" + the hover aspect. Required: `:event`. Optional: `:aspect`, `:animate`.
- `:drag-over [tags {options}]` — container-level zone. Optional: `:event` (fires `:phase :enter` / `:leave`), `:aspect`, `:animate`. No payload slot.

Tags are a single keyword (one tag) or a vector of keywords (multi-tag); a draggable and a dropable interact when their tag sets intersect.

Events:

| Trigger | Payload to handler |
|---|---|
| Drag-start (4px threshold) | `[:event {:value <drag-payload>}]` |
| Drag enters/leaves a `:drag-over` container | `[:event {:phase :enter}]` / `[:event {:phase :leave}]` |
| Drop on a compatible `:dropable` | `[:event {:from <drag-payload> :to <drop-payload>}]` |
````

- [ ] **Step 3: Update `docs/reference/elements.md`**

Update the per-element attribute reference for `vbox` / `hbox` (the only nodes that accept drag/drop attrs) to use the new `[tags {options} payload]` shape. Mirror the wording from `docs/core-api.md`.

- [ ] **Step 4: Update `.claude/skills/redin-dev/SKILL.md`**

Find any `:draggable` / `:dropable` examples in the skill (they're in the architecture and node-types sections). Replace with v2 examples matching the kitchen-sink. Drop any reference to `aspect#drag-start` or `aspect#drag`.

- [ ] **Step 5: Spot-check via grep**

```bash
rg -n 'aspect#drag|#drag-start|lua_get_drag_drop|draggable_group|draggable_event' docs/ .claude/ src/ test/
```

Expected: zero results outside `docs/superpowers/specs/2026-04-11-drag-and-drop-design.md` and `docs/superpowers/plans/2026-04-11-drag-and-drop.md` (those are historical documents and stay as-is).

- [ ] **Step 6: Commit**

```bash
git add docs/ .claude/
git commit -m "docs: drag-and-drop v2 API + remove #-cascade variants"
```

---

## Task 20: Final verification

End-to-end check before declaring the work done.

- [ ] **Step 1: Full verification per `redin-maintenance` skill**

```bash
# Build
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin

# Runtime tests
luajit test/lua/runner.lua test/lua/test_*.fnl

# UI suite (headless if no display)
bash test/ui/run-all.sh --headless

# Memory leak check on drag suite specifically
./build/redin --dev --track-mem test/ui/drag_app.fnl &
sleep 2
bb test/ui/run.bb test/ui/test_drag.bb
curl -s -X POST -H "Authorization: Bearer $(cat .redin-token)" http://localhost:$(cat .redin-port)/shutdown
```

Expected:
- Build: clean
- Runtime tests: 122 / 122 pass
- UI suite: every component test passes
- Memory: tracking allocator reports zero outstanding allocations

- [ ] **Step 2: Manual visual smoke**

```bash
./build/redin --dev examples/kitchen-sink.fnl
```

Manually drag a row in the todo list. Expected:
- Source row stays in the layout (stays visible).
- A clone of the row follows the cursor (offset slightly down-right).
- The pulse-dot animation rides on the clone's top-right corner.
- The container highlights with `:muted-armed` while the drag is active.
- The row under the cursor highlights with `:row-drop-hot`.
- Releasing over a row reorders the list; releasing outside cancels silently.

- [ ] **Step 3: Push branch**

```bash
git push -u origin spec/draggable-v2
```
