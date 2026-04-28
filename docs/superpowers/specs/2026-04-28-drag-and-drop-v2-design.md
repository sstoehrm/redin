# Drag-and-Drop v2 Design

Replaces the v1 design (`2026-04-11-drag-and-drop-design.md`). v1 supports list-reorder use cases — single group, theme-cascade highlights — but breaks down when more than one drag system has to coexist (e.g. an inventory grid where rows accept any item and equipment slots accept only compatible types). v2 generalises the API around tag-set matching, an options-map shape, aspect swaps in place of theme `#` cascades, and a per-drag preview clone that follows the cursor.

**Dependency:** the `:animate` universal attribute (see `2026-04-27-animate-attribute-design.md`). v2 reuses the animate dispatch and overlay-pass machinery.

---

## App-facing API

Three attributes; all three share the same options-map shape: `[tags options-map ?payload]`. Tags use set-intersection matching: a draggable's tags declare "what I am", a dropable's tags declare "what I accept", and they interact whenever the two sets overlap.

```fennel
;; Source — declares what the dragged thing is and how it behaves while dragged.
:draggable [tags
            {:event   :event/name        ; required — fired on drag-start
             :mode    :preview            ; :preview (default) | :none
             :aspect  :row-dragging       ; optional — clone aspect override
             :animate {:provider :sparkle ; optional — same shape as universal :animate
                       :rect [:top_right -6 -6 12 12]
                       :z :above}}
            payload]

;; Target — declares what kinds it accepts and how it looks while a compatible drag hovers.
:dropable [tags
           {:event  :event/drop           ; required — fired on drop
            :aspect :row-drop-hot         ; optional — aspect swap on hover
            :animate {...}}               ; optional
           payload]

;; Container zone — fires on enter/leave and decorates the whole zone.
:drag-over [tags
            {:event   :event/over         ; optional — :phase :enter | :leave
             :aspect  :grid-armed         ; optional — aspect swap while compatible drag in flight
             :animate {...}}]             ; optional, no payload slot
```

**Tags syntax.** A single keyword (`:item-drag`) is shorthand for a one-element tag list. A vector of keywords (`[:item :weapon :sword]`) declares multiple tags. Match rule:

```odin
drag_matches :: proc(src, target: []string) -> bool {
    for s in src do for t in target do if s == t do return true
    return false
}
```

**Modes** (draggable only):
- `:preview` (default) — clone of the dragged subtree renders at the cursor on the overlay layer; clone is click-through. Source remains in its layout slot. `:aspect` and `:animate` decorate the clone.
- `:none` — no clone. `:aspect` and `:animate` decorate the source in place.

**Events dispatched.**

| Trigger | Lua-side payload |
|---|---|
| Drag-start (4px threshold crossed on a draggable) | `[:event {:value <drag-payload>}]` |
| Compatible drag enters/leaves a `:drag-over` container | `[:event {:phase :enter}]` / `[:event {:phase :leave}]` |
| Drop on a compatible `:dropable` | `[:event {:from <drag-payload> :to <drop-payload>}]` |
| Release over no compatible target | (no event; state resets silently) |

---

## What is removed

The v1 theme cascade (`aspect#drag-start` and `aspect#drag`) is **deleted**. Visual feedback during drag is now expressed as ordinary aspect swaps — the framework substitutes the aspect specified in the options map and the renderer resolves it through the normal theme path.

Concrete deletions:

| Location | What goes |
|---|---|
| `src/redin/render.odin:291-298` | `aspect#drag-start` / `aspect#drag` lookup in padding resolution |
| `src/redin/render.odin:552-565` | `aspect#drag-start` / `aspect#drag` lookup in `draw_box` background |
| `docs/reference/theme.md:155-156` | Theme variant table entries for `drag-start` / `drag` |
| `test/ui/drag_app.fnl:9-10` | `:row#drag` / `:row#drag-start` theme entries (replaced by `:row-dragging`, `:row-drop-hot`) |
| `examples/kitchen-sink.fnl` (current uncommitted edits) | Same — already migrated in the working tree |

The `#` separator itself is unchanged for `#hover`, `#focus`, etc. — the deletion is scoped to the two drag-related variants.

---

## Host data structures

### Listener types — `types/listener_events.odin`

```odin
DragListener :: struct {
    node_idx: int,
    tags:     []string,
}

DropListener :: struct {
    node_idx: int,
    tags:     []string,
}

DragOverListener :: struct {
    node_idx: int,
    tags:     []string,
}

Drag_Over_Event :: struct {
    event_name: string,
    phase:      enum { Enter, Leave },
}
```

`DragListener` and `DropListener` already exist in v1; `tags: []string` replaces the v1 `group: string`. `DragOverListener` and `Drag_Over_Event` are new.

### Node fields — `types/view_tree.odin`

A `Drag_Attrs` record bundles all three attributes' fields. `NodeHbox` and `NodeVbox` (and any future container) embed it via `using`:

```odin
Drag_Mode :: enum { Preview, None }

Drag_Attrs :: struct {
    // draggable
    drag_tags:    []string,
    drag_event:   string,
    drag_mode:    Drag_Mode,        // zero = .Preview
    drag_aspect:  string,
    drag_animate: Animate_Spec,
    drag_ctx:     i32,              // Lua registry ref to payload

    // dropable
    drop_tags:    []string,
    drop_event:   string,
    drop_aspect:  string,
    drop_animate: Animate_Spec,
    drop_ctx:     i32,

    // drag-over
    over_tags:    []string,
    over_event:   string,
    over_aspect:  string,
    over_animate: Animate_Spec,
}
```

The v1 fields (`draggable_group`, `draggable_event`, `draggable_ctx`, `dropable_group`, `dropable_event`, `dropable_ctx`) are deleted from `NodeHbox`/`NodeVbox`.

### Drag state — `input/drag.odin`

Replaces the v1 flat globals with a tagged union state machine:

```odin
Drag_Captured :: struct {
    src_idx:     int,
    start_pos:   rl.Vector2,
    src_tags:    []string,
    src_event:   string,
    src_mode:    Drag_Mode,
    src_aspect:  string,
    src_animate: Animate_Spec,
    src_ctx_ref: i32,
}

Drag_Idle    :: struct {}                   // zero-sized

Drag_Pending :: struct {
    using captured: Drag_Captured,
}

Drag_Active :: struct {
    using captured: Drag_Captured,
    over_zone_idx:  int,                    // -1 if no zone hovered
    over_drop_idx:  int,                    // -1 if no drop cell hovered
}

Drag_State :: union { Drag_Idle, Drag_Pending, Drag_Active }
drag: Drag_State = Drag_Idle{}
```

Predicates the renderer needs:

```odin
is_dragging   :: proc() -> bool { _, ok := drag.(Drag_Active); return ok }
dragging_idx  :: proc() -> int  { if a, ok := drag.(Drag_Active); ok do return a.src_idx;       return -1 }
drag_over_idx :: proc() -> int  { if a, ok := drag.(Drag_Active); ok do return a.over_drop_idx; return -1 }
```

The v1 globals (`dragging_idx: int = -1`, `drag_over_idx: int = -1`, `drag_pending: bool`, `drag_start_pos`, `drag_source: Drag_Source`) are deleted in favour of this union.

---

## Drag lifecycle

### Per-frame flow inside `process_drag`

Called once per frame from the input pipeline (same call site as v1):

```
mouse  := GetMousePosition()
events := this frame's input events

switch s in drag:
    Drag_Idle:
        for each LMB-down event:
            winner = deepest_listener_idx(listeners, node_rects, point)
            if winner is a DragListener:
                capture = read_drag_attrs(nodes[winner])
                drag = Drag_Pending{captured = capture}
                break

    Drag_Pending:
        if LMB still down:
            if dist(mouse, s.start_pos) >= DRAG_THRESHOLD:
                dispatch [Drag_Event{event=s.src_event, ctx=s.src_ctx_ref}]
                drag = Drag_Active{captured = s.captured, over_zone_idx = -1, over_drop_idx = -1}
        else:
            drag = Drag_Idle{}

    Drag_Active:
        if frame was re-flattened and s.src_idx no longer points to a draggable
           with matching tags:
            drag = Drag_Idle{}
            return

        new_zone = deepest_drag_over_match(s.src_tags, mouse, listeners, node_rects)
        new_drop = deepest_dropable_match  (s.src_tags, mouse, listeners, node_rects)

        if new_zone != s.over_zone_idx:
            if s.over_zone_idx >= 0: dispatch over_event(prev zone, :phase :leave)
            if new_zone        >= 0: dispatch over_event(new  zone, :phase :enter)
            s.over_zone_idx = new_zone

        s.over_drop_idx = new_drop

        if LMB released:
            if new_drop >= 0:
                dispatch [Drop_Event{event=drop_event, from=s.src_ctx_ref, to=drop_ctx}]
            if s.over_zone_idx >= 0:
                dispatch over_event(s.over_zone_idx, :phase :leave)
            drag = Drag_Idle{}
```

### Hit-testing rules

- **`:dropable` cells**: deepest-wins — innermost matching `DropListener` whose rect contains the cursor (preserves v1 behaviour).
- **`:drag-over` zones**: deepest-wins — innermost matching `DragOverListener` containing the cursor. Multiple nested zones are allowed; only the innermost gets enter/leave.
- **Click-through during drag**: while `Drag_Active`, the source node remains in `node_rects` and CAN match as a drop target if its tags overlap. Handlers naturally no-op when `from == to`.

### What does NOT fire

- No drop event when the release happens over no compatible target.
- No `:drag-over` event when entering a zone whose tags don't match the active drag.
- No drag-start dispatch if the threshold isn't crossed (treated as a normal click).
- No aspect swap or animate decoration on a target whose tags don't match the active drag — incompatible targets remain in their normal aspect with no decoration.

### Memory ownership

- `src_tags` is a slice into the source node's `drag_tags` field. That memory lives until the next `clear_frame`. Re-flatten safety is the explicit branch in `Drag_Active` above: if the index no longer resolves to a matching draggable, reassign to `Drag_Idle{}`.
- `src_ctx_ref` is a Lua registry ref. Released via `luaL_unref` after the drop or cancel dispatch (same lifecycle as v1).

---

## Rendering

### Aspect swap (replaces v1 `#`-cascade lookups)

In each draw proc that resolves an aspect, consult drag state once:

```odin
effective_aspect := node.aspect

if active, ok := input.drag.(input.Drag_Active); ok {
    if active.src_idx == idx && active.src_mode == .None && len(active.src_aspect) > 0 {
        effective_aspect = active.src_aspect
    }
    if active.over_drop_idx == idx {
        if a := node_drop_aspect(nodes[idx]); len(a) > 0 do effective_aspect = a
    }
    if active.over_zone_idx == idx {
        if a := node_over_aspect(nodes[idx]); len(a) > 0 do effective_aspect = a
    }
}
```

This replaces both blocks at `render.odin:291-298` and `render.odin:552-565`. Net code reduction; `strings.concatenate` allocations against the temp allocator go away.

### `:animate` activation rules

The `:animate` decorations on drag attributes are gated on drag state, not always-on (unlike the universal `:animate`):

| Field | Dispatched when | Anchored to |
|---|---|---|
| `drag_animate` (`:mode :preview`) | `Drag_Active` and this is the source | Translated clone root rect |
| `drag_animate` (`:mode :none`) | `Drag_Active` and this is the source | Source's normal rect |
| `drop_animate` | `Drag_Active` and `over_drop_idx == this idx` | Drop target's rect |
| `over_animate` | `Drag_Active` and `over_zone_idx == this idx` | Container's rect |

When the gate condition is false, the field is a no-op — no decoration is queued. Decorations queued by these gates ride the same `:animate :above` / `:animate :behind` overlay pipeline as the universal `:animate` attribute.

### Preview-clone overlay pass

Added as a final pass in the main render loop, after `:animate :above`:

```
render normal frame ...
render :animate :behind decorations ...
render :animate :above decorations ...
render drag preview clone ...                    ← new
```

```odin
render_drag_preview :: proc(
    nodes:         []types.Node,
    children_list: []types.Children,
    theme:         map[string]types.Theme,
) {
    active, ok := input.drag.(input.Drag_Active)
    if !ok || active.src_mode != .Preview do return
    if active.src_idx < 0 || active.src_idx >= len(nodes) do return

    src_rect := node_rects[active.src_idx]
    mouse    := rl.GetMousePosition()

    delta := rl.Vector2{
        mouse.x - src_rect.x - DRAG_PREVIEW_OFFSET,
        mouse.y - src_rect.y - DRAG_PREVIEW_OFFSET,
    }

    render_subtree(active.src_idx, delta,
                   override_aspect = active.src_aspect,
                   in_overlay      = true,
                   nodes, children_list, theme)

    if active.src_animate != {} {
        translated_root := rl.Rectangle{
            src_rect.x + delta.x,
            src_rect.y + delta.y,
            src_rect.width,
            src_rect.height,
        }
        dispatch_animate_with_host(translated_root, active.src_animate)
    }
}
```

`render_subtree` walks `children_list[idx]` recursively, drawing each descendant exactly as the normal pass would, with two differences:

1. **All hit-test outputs are skipped.** `node_rects` and `node_content_rects` are NOT written; the clone must not inject hit areas.
2. **Coordinates are offset by `delta`.** The subtree's layout was already computed by the normal pass; we reuse those rects and translate.

The `:animate` attached to the clone reuses the same overlay-pass dispatch as the universal `:animate :above`, anchored to the translated root rect.

### Prerequisite refactor

Some draw procs read `node_rects[idx]` internally rather than receiving a rect parameter. `render_subtree` requires the latter. Two or three procs in `render.odin` need a small refactor as a prerequisite — flagged in the implementation plan.

---

## Parsing & dispatch wiring

### Parsing — `bridge/bridge.odin`

Replace the v1 `lua_get_drag_drop` (positional 3-element vector reader) with three readers, one per attribute:

```odin
lua_read_draggable :: proc(L: ^Lua_State, attrs_idx: c.int, field: cstring) -> Draggable_Parsed
lua_read_dropable  :: proc(L: ^Lua_State, attrs_idx: c.int, field: cstring) -> Dropable_Parsed
lua_read_drag_over :: proc(L: ^Lua_State, attrs_idx: c.int, field: cstring) -> Drag_Over_Parsed
```

Each reader follows the same shape:

1. **Slot 1 (tags):** if it's a string, wrap as a single-element slice; if it's a Lua array of strings, copy each into a `[]string` (cloned, owned by the node).
2. **Slot 2 (options map):** Lua table with keys `:event` (string), `:mode` (`"preview"` | `"none"`, draggable only), `:aspect` (string), `:animate` (parsed via the existing `lua_read_animate` helper into `Animate_Spec`).
3. **Slot 3 (payload):** for `:draggable` / `:dropable` only. Stored via `luaL_ref` into the registry.
4. **Validation:** missing `:event` on `:draggable`/`:dropable` is an error logged to stderr; the attribute is dropped. Unknown `:mode` warns and falls back to `:preview`.

`lua_read_node` calls these for every container node type. The migration error message for v1 callers:

```
[redin] :draggable expected [tags {options} payload], got positional [group event payload].
        Migrate: [:row :event/drag i] -> [:row {:event :event/drag} i]
```

### Listener extraction — `input/input.odin`

`extract_listeners` walks the flat node array and emits `DragListener` / `DropListener` / `DragOverListener` for any node whose `Drag_Attrs` populates the corresponding fields. Same pattern as v1's drag listener extraction; just three listeners instead of two.

### Event delivery — `bridge/bridge.odin`

`deliver_dispatch_events` handles three variants:

| Variant | Lua-side payload pushed |
|---|---|
| `Drag_Event` | `[:dispatch [:event-name {:value <payload>}]]` (unchanged) |
| `Drop_Event` | `[:dispatch [:event-name {:from <src> :to <dst>}]]` (unchanged) |
| `Drag_Over_Event` | `[:dispatch [:event-name {:phase :enter}]]` or `:leave` (new) |

`Drag_Over_Event` carries no payload by design — the container's payload slot doesn't exist.

### Memory cleanup

`clear_frame` must release per-node:

- `drag_tags` / `drop_tags` / `over_tags`: cloned `[]string`, free each element then the slice.
- `drag_event` / `drop_event` / `over_event`: cloned strings.
- `drag_aspect` / `drop_aspect` / `over_aspect`: cloned strings.
- `drag_animate` / `drop_animate` / `over_animate`: cleanup via the existing `Animate_Spec` cleanup helper.
- `drag_ctx` / `drop_ctx`: `luaL_unref`.

A small `Drag_Attrs.cleanup(L: ^Lua_State)` helper keeps the per-node-type teardown a one-liner.

---

## Backwards compatibility

This work is on a `spec/` branch ahead of main; no external users on the v1 API. **Clean break, no deprecation shim.** In-tree consumers (`test/ui/drag_app.fnl`, `examples/kitchen-sink.fnl`) are migrated in the same PR.

---

## Files to modify

| File | Change |
|---|---|
| `src/redin/types/view_tree.odin` | Delete v1 `draggable_*` / `dropable_*` fields on `NodeHbox`/`NodeVbox`. Embed `Drag_Attrs`. |
| `src/redin/types/listener_events.odin` | Add `tags: []string` to `DragListener`/`DropListener`. Add `DragOverListener`. Add `Drag_Over_Event` variant to `Dispatch_Event`. |
| `src/redin/bridge/bridge.odin` | Delete `lua_get_drag_drop`. Add `lua_read_draggable` / `lua_read_dropable` / `lua_read_drag_over`. Wire into `lua_read_node`. Extend `clear_frame` (or call `Drag_Attrs.cleanup`). Deliver `Drag_Over_Event`. |
| `src/redin/input/drag.odin` | Replace flat globals with `Drag_State` union. Implement state-machine flow (§ Drag lifecycle). Add `drag_matches`, `deepest_drag_over_match`, `deepest_dropable_match`. |
| `src/redin/input/input.odin` | Update `extract_listeners` to emit all three listener types with tags. |
| `src/redin/render.odin` | Delete `aspect#drag-start` / `aspect#drag` lookups (lines 291-298, 552-565). Add aspect-swap logic from § Rendering. Refactor draw procs to accept rect parameter. Add `render_drag_preview` overlay pass. |
| `src/redin/runtime.odin` | Wire `render_drag_preview` into post-frame pass after `:animate :above`. |
| `examples/kitchen-sink.fnl` | Already migrated in working tree. Commit alongside implementation. |
| `test/ui/drag_app.fnl` | Migrate to new API; delete `:row#drag` / `:row#drag-start`. |
| `test/ui/test_drag.bb` | Add cases for tag matching, `:drag-over` enter/leave, `:mode :preview` clone visibility, cancel-on-reflatten. Existing reorder cases stay green. |
| `docs/core-api.md` | Replace drag/drop section. |
| `docs/reference/elements.md` | Update per-element attribute reference. |
| `docs/reference/theme.md` | Delete `#drag` / `#drag-start` rows from variant table (lines 155-156). |
| `.claude/skills/redin-dev/SKILL.md` | Update DnD examples. |

---

## UI tests

Following `test/ui/<component>_app.fnl` + `test_<component>.bb`. Existing v1 cases stay green after migration. New cases:

1. **Tag matching.** Source `[:item :sword]` over target `[:weapon]` → match (drop fires). Source `[:item]` over target `[:weapon]` → no match (drop ignored, no `:aspect` swap on target).
2. **Drag-over enter.** Press on a row, move into the zone's bounds → assert `:event/over` fired exactly once with `{:phase :enter}`.
3. **Drag-over leave.** Continue moving out of the zone → assert `:phase :leave` fired exactly once.
4. **Aspect swap visible in frame.** While dragging, `GET /frames` shows the drop-target row carrying the swapped aspect.
5. **Preview clone present.** While dragging in `:mode :preview`, the overlay frame data exposes the clone marker. `:mode :none` → no clone.
6. **Cancel on re-flatten.** Dispatch an event that removes the source row mid-drag → assert state machine returns to `Drag_Idle{}`.

---

## Verification

Per the `redin-maintenance` checklist: build, runtime tests, full UI suite (`bash test/ui/run-all.sh`), and `--track-mem` on the drag suite specifically (registry refs, tag slices, and the new clone path are all new allocation surface area).

---

## Out of scope

Tracked in [#90](https://github.com/sstoehrm/redin/issues/90):

- Cross-container drag preview tracking with parent transforms
- Auto-scroll while a drag sits near scrollable-zone edges
- Keyboard cancel for active drag (Esc)
- Multi-select drag
- Sortable container with auto-reorder
- Drag constraints (axis lock, bounds)

Insertion-line guides between cells are intentionally an app concern — the app draws them from the `:drag-over` event using a canvas provider.
