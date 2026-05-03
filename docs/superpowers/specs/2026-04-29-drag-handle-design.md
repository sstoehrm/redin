# Drag handle attribute — design

**Status:** approved 2026-04-29
**Resolves:** issue #94 ("Draggable container with text child is hard to drag")
**Builds on:** drag-and-drop v2 (issue #90 / PR #91, design 2026-04-28)

## Problem

In a draggable container with a `:text` child, the text fills the layout
and its `Text_Select_Listener` wins the click against the parent's
`DragListener` (the text node sits at a deeper DFS index than the
container). The user can only start a drag by clicking in padding gaps,
with no visual hint that the padding is the only grab surface.

Previous attempts (PR #92's `73ee02a`) tried to make drag/drop win over
text-select in the listener resolver. That regressed drag in unidentified
ways and was reverted.

## Solution

Add an explicit drag-handle pattern, matching the established UX of
Notion blocks / macOS Reminders / Linear: the app marks a small
descendant element as the grab surface, and optionally opts the
container itself out of being a grab surface.

This is a workaround, not a fix to the underlying click-conflict.
Apps that genuinely want "drag the whole row" still hit the text-select
gap-click limitation. That case is left unaddressed; #94 closes once
this lands plus a docs note recommending handles for rows that contain
selectable text.

## Public API

```fennel
[:hbox {:draggable [:row-drag {:handle false   ;; default: true
                               :event :event/drag
                               ...} payload]}
  [:text {} item.text]
  [:vbox {:drag-handle true                    ;; marks this node a grab surface
          :width 24 :aspect :drag-handle}]]
```

Two new pieces:

| Where | Attribute | Type | Default | Meaning |
|---|---|---|---|---|
| `:draggable` options map | `:handle` | bool | `true` | `false` = container itself is NOT a grab surface |
| Any node | `:drag-handle` | bool | `false` | `true` = this node is a grab surface for the **nearest `:draggable` ancestor** |

`:drag-handle` is allowed on `:vbox`, `:hbox`, and `:button` in this
pass — these are the node types that get a parser-level `drag_handle`
field. Other node types can be added later if real apps need it.
(Note: the descendant walk in extract_listeners traverses all node
types via `children_list`, so a button used as a handle inside a
draggable vbox is supported automatically once the field exists on
NodeButton.)

Tag matching is implicit by ancestry — the handle never repeats the
draggable's tag.

### Mutual exclusion

`:click` and `:drag-handle true` on the same node are mutually exclusive.
At parse time, if both are present, stderr warns and the **`:click`** is
dropped (drag-handle is the more deliberate, narrower opt-in).

### Validation

After frame parse, walk the tree once: for every `:draggable` with
`:handle false`, confirm at least one descendant carries `:drag-handle
true`. If none, stderr warn (the draggable is silently ungrabbable
otherwise). Validation runs in all modes; cost is negligible and matches
the existing precedent of `:rect`/`:event` warnings.

Note: existing parser warnings fire on every frame parse without
deduplication (see `bridge.odin` `eprintln` sites for `:draggable`,
`:dropable`, animate `:rect`, etc.). The new warning matches that
convention. If global parse-warning dedupe is desired, that's a
separate change covering all warnings uniformly.

### Nested draggables

A handle belongs to its **nearest** `:draggable` ancestor. A handle
inside an inner draggable cannot "skip up" to an outer one. The
descendant-walk in extract_listeners stops at nested-draggable
boundaries.

## Implementation

### Data model

`types/view_tree.odin`:

```odin
Draggable_Attrs :: struct {
    tags:       []string,
    event:      string,
    mode:       Drag_Mode,
    aspect:     string,
    animate:    Maybe(Animate_Decoration),
    ctx:        i32,
    handle_off: bool,   // NEW. zero-value = container is a grab surface.
}

NodeVbox   :: struct { ...; drag_handle: bool }   // NEW
NodeHbox   :: struct { ...; drag_handle: bool }   // NEW
NodeButton :: struct { ...; drag_handle: bool }   // NEW
```

Inverted-bool encoding (`handle_off` rather than `handle`) preserves
"zero-init does the right thing" — same precedent as
`NodeText.not_selectable`.

`types/listener_events.odin`:

```odin
DragListener :: struct {
    node_idx:   int,    // hit-test surface (handle if present, else container)
    source_idx: int,    // the draggable container; equals node_idx for container-grabs
    tags:       []string,
}
```

This keeps `deepest_listener_idx` returning the handle (so click
resolution stays correct) while drag.odin reads draggable attrs from
`source_idx`.

### Parser (`bridge/bridge.odin`)

`lua_read_draggable`: read optional `:handle` boolean from the options
map. If present and `false`, set `handle_off = true`.

`lua_read_node` per-type:
- For `:button`: read `:drag-handle`. If `true` AND `:click` is non-empty,
  stderr warn (`"node :drag-handle conflicts with :click — dropping
  :click"`) and clear the click string. Then set `drag_handle = true`.
- For `:vbox` / `:hbox`: just read `:drag-handle` and set the field.

New helper called once after frame parse, before listener extraction:

```odin
validate_drag_handles :: proc(nodes: []Node, children_list: []Children, paths: []Path)
```

For each node with `draggable.handle_off == true`, walk descendants via
`children_list`; if no descendant has `drag_handle == true`, stderr warn
(`"draggable at <path> has :handle false but no descendant :drag-handle
true — ungrabbable"`).

### Listener extraction (`input/input.odin`)

Replace the current "one DragListener per draggable container" emission:

```
for each NodeVbox/NodeHbox with draggable:
    handles := walk_descendants_collect_drag_handles(idx, children_list, nodes)
        # walk stops at nested :draggable boundaries
    if !d.handle_off:
        emit DragListener{node_idx: idx, source_idx: idx, tags: d.tags}
    for h in handles:
        emit DragListener{node_idx: h, source_idx: idx, tags: d.tags}
    # if handle_off and len(handles) == 0: nothing emitted
    #   (validate_drag_handles already warned)
```

The descendant walk is O(subtree size); for typical lists this is
negligible per draggable.

### Drag capture (`input/drag.odin`)

The `Drag_Idle → Drag_Pending` transition currently does:

```odin
cap := Drag_Captured{ src_idx = winner, ... }
switch n in nodes[winner] { ... read attrs ... }
```

Change `winner` to the listener's `source_idx`:

```odin
cap := Drag_Captured{ src_idx = dl.source_idx, ... }
switch n in nodes[dl.source_idx] { ... read attrs ... }
```

Everything downstream (clone-from-source, aspect/animate read,
re-flatten safety check) already keys off `src_idx`. No further changes.

### Cursor (`input/input.odin:set_hover_cursor`)

Extend the existing per-frame proc with this precedence:

1. `Drag_Active` or `Drag_Pending` → `.RESIZE_ALL` (raylib has no
   "grabbing" cursor; this is the closest analogue).
2. Else if mouse is over a `DragListener` (handle or container,
   doesn't matter) → `.POINTING_HAND`.
3. Else if mouse is over a `Text_Select_Listener` → `.IBEAM` (existing).
4. Else `.DEFAULT`.

Drag state is read from `input/drag.odin`'s package-level `drag` var
(same package, direct access).

## Test plan

UI integration — extend `test/ui/drag_app.fnl` + `test/ui/test_drag.bb`:

1. **Handle grab works.** POST `/click` on the handle, mouse-move +
   release on a drop target; assert drop fires with correct
   `:from`/`:to`.
2. **Container body does NOT grab when `:handle false`.** Click on the
   row's text area, mouse-move past threshold; assert no drag-start
   dispatched (text-select wins, drag stays Idle).
3. **Container body DOES grab when `:handle true` (default) even with
   handle present.** Sub-case verifying the additive default.
4. **Multiple handles.** Two `:drag-handle true` children on one
   draggable; assert both grab.
5. **Click+handle conflict warning.** Separate app
   `test/ui/drag_handle_warn_app.fnl` with a `:button` carrying both
   `:click` and `:drag-handle true`. Assert stderr contains the
   warning. (Requires a small redin-test extension to capture stderr
   from the spawned binary; if too painful, drop and verify manually.)
6. **`:handle false` + no descendant handle warning.** Same caveat as
   #5.

Cursor changes are visual; no automated assertion. Verify by hand under
windowed `bash test/ui/run-all.sh`.

No Fennel runtime tests needed — pure host-side parser/listener logic.

`--track-mem` run on the extended `drag_app.fnl` to confirm the
descendant walk doesn't leak (listeners borrow tags; no new
allocations expected).

## Docs / skills sweep

- `docs/core-api.md` — drag attribute table: add `:handle` to the
  `:draggable` options table; add `:drag-handle` row to the per-element
  attribute reference for vbox/hbox/button.
- `docs/reference/elements.md` — same per-element addition.
- `.claude/skills/redin-dev/SKILL.md` — extend the drag-and-drop section
  with the handle pattern and a kitchen-sink-style example.
- `examples/kitchen-sink.fnl` — replace the WIP `:drag-handle :tag`
  proposal in the user's working tree with the final form: `:handle
  false` on the row's `:draggable` plus an empty `:vbox` child carrying
  `:drag-handle true`. Demonstrates the resolution of #94: clicking the
  text starts a text-select, clicking the handle starts a drag.

Closes #94 once landed.

## Out of scope

- Selectable inheritance (text inside draggable defaults to
  non-selectable). Could complement this for the handle-less case but
  is a separate change.
- Custom textured cursors (would need an asset path).
- Press-and-hold time-threshold drag.
- `:drag-handle` on `:text` / `:image` / `:canvas` — extend later if
  real apps need it.
