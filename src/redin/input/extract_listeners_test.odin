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

// Free inner allocations of nodes and children arrays.
@(private="file")
free_nodes :: proc(nodes: [dynamic]types.Node) {
	for n in nodes {
		if vb, ok := n.(types.NodeVbox); ok {
			if d, dok := vb.draggable.?; dok {
				delete(d.tags)
			}
		}
		if hb, ok := n.(types.NodeHbox); ok {
			if d, dok := hb.draggable.?; dok {
				delete(d.tags)
			}
		}
	}
}

@(private="file")
free_children :: proc(children: [dynamic]types.Children) {
	for c in children {
		delete(c.value)
	}
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
	defer free_nodes(nodes)
	defer delete(nodes)
	append(&nodes, types.Node(types.NodeVbox{
		draggable = mk_draggable(false /* handle_off */),
	}))

	children: [dynamic]types.Children
	defer free_children(children)
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
	defer free_nodes(nodes)
	defer delete(nodes)
	// idx 0: draggable container with handle_off
	append(&nodes, types.Node(types.NodeVbox{
		draggable = mk_draggable(true),
	}))
	// idx 1: handle vbox
	append(&nodes, types.Node(types.NodeVbox{drag_handle = true}))

	children: [dynamic]types.Children
	defer free_children(children)
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
	defer free_nodes(nodes)
	defer delete(nodes)
	append(&nodes, types.Node(types.NodeVbox{
		draggable = mk_draggable(false),
	}))
	append(&nodes, types.Node(types.NodeVbox{drag_handle = true}))

	children: [dynamic]types.Children
	defer free_children(children)
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
	defer free_nodes(nodes)
	defer delete(nodes)
	append(&nodes, types.Node(types.NodeVbox{
		draggable = mk_draggable(true),
	}))
	append(&nodes, types.Node(types.NodeVbox{drag_handle = true}))
	append(&nodes, types.Node(types.NodeVbox{drag_handle = true}))

	children: [dynamic]types.Children
	defer free_children(children)
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
	handle_indices := []int{1, 2}
	for h in handle_indices {
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
	defer free_nodes(nodes)
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
	defer free_children(children)
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
