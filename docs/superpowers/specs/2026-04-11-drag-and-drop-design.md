# Drag-and-Drop Design

Framework-level drag-and-drop support. The host manages all transient drag state (like it does for focus/hover/active). Apps declare draggable sources and drop targets, receive high-level events, and get automatic theme variant application for visual feedback.

## App-facing API

### Node attributes

Any node can be a drag source, drop target, or both:

```fennel
:draggable [:group :event payload]
:dropable  [:group :event payload]
```

- **group** (keyword): Scoping channel. Only draggables and dropables with the same group interact.
- **event** (keyword): Event name dispatched to the app when the interaction fires.
- **payload** (any): Arbitrary value passed through to the event handler. Stored as a Lua registry ref.

Example:

```fennel
[:hbox {:aspect :row :height 42
        :draggable [:row :drag i]
        :dropable  [:row :drop i]}
  [:text {:aspect :body} item.text]]
```

### Events dispatched

**On drag start** (mouse down + move beyond 4px threshold on a draggable node):
```fennel
;; Dispatches the draggable's :event with payload
[:drag {:value <drag-payload>}]
```

**On drop** (mouse release over a matching dropable):
```fennel
;; Dispatches the dropable's :event with both payloads
[:drop {:from <drag-payload> :to <drop-payload>}]
```

**On drag cancel** (mouse release over no valid target): no event dispatched, state resets silently.

### Theme variants

Applied automatically by the host based on drag state:

| Variant | Applied to | When |
|---------|-----------|------|
| `aspect#drag-start` | The node being dragged | While dragging |
| `aspect#drag` | The drop target being hovered | While a compatible drag hovers over it |

Theme example:

```fennel
:row#drag-start {:bg [136 46 106]}   ;; purple highlight on source
:row#drag       {:bg [76 86 106]}    ;; subtle highlight on hover target
```

Variant listeners are created during `extract_listeners` when `aspect#drag-start` or `aspect#drag` keys exist in the theme, same pattern as `#hover` and `#focus`.

## Host implementation

### State (input/input.odin)

New global state alongside `focused_idx`:

```odin
dragging_idx:   int = -1       // Node index being dragged
drag_over_idx:  int = -1       // Drop target currently hovered
drag_start_pos: rl.Vector2     // Mouse position at drag initiation (for threshold)
drag_pending:   bool = false   // Mouse down on draggable, threshold not yet reached

Drag_Source :: struct {
    group:       string,
    event:       string,
    context_ref: i32,          // Lua registry ref to payload
}
drag_source: Drag_Source
```

### Listener types (types/listener_events.odin)

```odin
DragListener :: struct {
    node_idx: int,
}

DropListener :: struct {
    node_idx: int,
    group:    string,          // For matching against drag source
}
```

Added to the `Listener` union.

### Node fields (types/view_tree.odin)

Add to NodeHbox, NodeVbox (and any other node types that should support drag-and-drop):

```odin
draggable_group: string,
draggable_event: string,
draggable_ctx:   i32,         // Lua registry ref to payload
dropable_group:  string,
dropable_event:  string,
dropable_ctx:    i32,         // Lua registry ref to payload
```

### Parsing (bridge/bridge.odin)

New helper to read the 3-element vector `[:group :event payload]`:

```odin
lua_get_drag_drop_field :: proc(L: ^lua_State, idx: c.int, field: cstring) -> (group: string, event: string, ctx: i32)
```

- Position 1: group keyword (string)
- Position 2: event keyword (string)
- Position 3: payload (stored as Lua registry ref via `luaL_ref`)

Called in `lua_read_node()` for each node type that supports draggable/dropable.

### Drag detection flow (input package)

1. **Mouse down** on a DragListener node: set `drag_pending = true`, record `drag_start_pos`.
2. **Mouse move** while `drag_pending`: if distance from `drag_start_pos` exceeds 4px threshold, transition to dragging:
   - Set `dragging_idx` to the node index
   - Store `drag_source` (group, event, ctx from the node's draggable fields)
   - Dispatch the drag event to Lua
   - Set `drag_pending = false`
3. **Each frame while dragging**: hit-test mouse against DropListeners whose `group` matches `drag_source.group`. Update `drag_over_idx`.
4. **Mouse release while dragging**:
   - If `drag_over_idx != -1`: dispatch drop event with `{:from drag_source.ctx :to dropable.ctx}`
   - Reset all drag state (`dragging_idx = -1`, `drag_over_idx = -1`, `drag_pending = false`)
5. **Mouse release while pending** (no threshold crossed): reset `drag_pending`, treat as normal click.

### Dispatch events (types/listener_events.odin)

```odin
Drag_Event :: struct {
    event_name:  string,
    context_ref: i32,          // Payload Lua ref
}

Drop_Event :: struct {
    event_name:  string,
    from_ref:    i32,          // Drag source payload Lua ref
    to_ref:      i32,          // Drop target payload Lua ref
}
```

Added to the `Dispatch_Event` union.

### Event delivery (bridge/bridge.odin)

In `deliver_dispatch_events()`:

**Drag_Event** pushes to Lua as:
```
[:dispatch [:event-name {:value payload}]]
```

**Drop_Event** pushes to Lua as:
```
[:dispatch [:event-name {:from drag-payload :to drop-payload}]]
```

### Theme variant rendering (render.odin)

In each draw procedure that supports aspects (draw_box for hbox/vbox, and others as needed):

```odin
// After loading base aspect properties:
if input.dragging_idx == idx {
    drag_start_key := strings.concatenate({aspect, "#drag-start"}, context.temp_allocator)
    if dt, ok := theme[drag_start_key]; ok {
        // Override properties from variant
    }
}
if input.drag_over_idx == idx {
    drag_key := strings.concatenate({aspect, "#drag"}, context.temp_allocator)
    if dt, ok := theme[drag_key]; ok {
        // Override properties from variant
    }
}
```

## Files to modify

| File | Change |
|------|--------|
| `src/host/types/view_tree.odin` | Add draggable/dropable fields to NodeHbox, NodeVbox |
| `src/host/types/listener_events.odin` | Add DragListener, DropListener, Drag_Event, Drop_Event |
| `src/host/bridge/bridge.odin` | Add `lua_get_drag_drop_field` helper, parse new attrs, deliver new events |
| `src/host/input/input.odin` | Add drag state, drag detection logic, extract DragListener/DropListener |
| `src/host/input/user_events.odin` | Add drag/drop user event generation |
| `src/host/render.odin` | Apply `#drag-start` and `#drag` theme variants |
| `src/host/main.odin` | Wire drag state updates into the main loop |
| `src/runtime/theme.fnl` | No changes needed (variant resolution already handles arbitrary `#suffix` keys) |
| `test/ui/drag_app.fnl` | New: minimal drag-and-drop test app |
| `test/ui/test_drag.bb` | New: drag-and-drop UI tests |

## UI test

Following existing convention (`test/ui/<component>_app.fnl` + `test/ui/test_<component>.bb`):

### Test app: `test/ui/drag_app.fnl`

Minimal app with a list of items that have `:draggable` and `:dropable` attrs. Handlers:
- `:event/drag` — stores the drag payload in state (for verifying drag-start fired)
- `:event/drop` — reorders items using `from`/`to` payloads
- `:event/reset` — resets state

State shape: `{:items [{:text "A"} {:text "B"} {:text "C"} {:text "D"}] :last-drag nil :last-drop nil}`

### Test file: `test/ui/test_drag.bb`

Tests via `POST /events` (dispatching handlers directly):
- **Frame structure**: draggable/dropable attrs present on list items
- **Drop reorders state**: dispatch `[:event/drop {:from 1 :to 3}]`, verify items reordered
- **Drag event fires**: dispatch `[:event/drag {:value 2}]`, verify `last-drag` updated
- **Reset**: verify state returns to initial values

## Not in scope

- Ghost/preview rendering of dragged item
- Cross-window drag
- Sortable (auto-reorder) container
- Drag constraints (axis locking, bounds)
