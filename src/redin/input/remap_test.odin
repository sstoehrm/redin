package input

// Review C4: per-index input state (focused_idx, active_idx, scrollbar
// container, drag source/zone/drop) and render's per-index state (scroll
// offsets, rects) are DFS indices into the flat view tree. When a new
// frame is flattened, a node inserted or removed before them shifts every
// later index, so the stored index silently names a different node.
// remap_on_frame_change aligns the previous tree with the new one and
// moves that state along with the node it belonged to.

import "core:sync"
import "core:testing"
import "../types"

@(private = "file")
kids :: proc(v: ..i32) -> types.Children {
	// Variadic args live in the caller's frame; copy so trees built in a
	// helper proc stay valid after it returns.
	out := make([]i32, len(v), context.temp_allocator)
	copy(out, v)
	return types.Children{value = out, length = i32(len(out))}
}

@(private = "file")
input_node :: proc(change: string) -> types.Node {
	return types.NodeInput{change = change}
}

// [vbox [text "banner"] [input :ev/a] [input :ev/b]]
@(private = "file")
banner_tree :: proc() -> ([]types.Node, []types.Children) {
	nodes := make([]types.Node, 4, context.temp_allocator)
	nodes[0] = types.NodeVbox{}
	nodes[1] = types.NodeText{content = "banner"}
	nodes[2] = input_node("ev/a")
	nodes[3] = input_node("ev/b")
	ch := make([]types.Children, 4, context.temp_allocator)
	ch[0] = kids(1, 2, 3)
	return nodes, ch
}

// [vbox [input :ev/a] [input :ev/b]] — the banner hidden.
@(private = "file")
no_banner_tree :: proc() -> ([]types.Node, []types.Children) {
	nodes := make([]types.Node, 3, context.temp_allocator)
	nodes[0] = types.NodeVbox{}
	nodes[1] = input_node("ev/a")
	nodes[2] = input_node("ev/b")
	ch := make([]types.Children, 3, context.temp_allocator)
	ch[0] = kids(1, 2)
	return nodes, ch
}

@(private = "file")
hashes_of :: proc(nodes: []types.Node) -> []u64 {
	out := make([]u64, len(nodes), context.temp_allocator)
	for n, i in nodes do out[i] = node_identity_hash(n)
	return out
}

@(private = "file")
remap_trees :: proc(
	old_nodes: []types.Node, old_ch: []types.Children,
	new_nodes: []types.Node, new_ch: []types.Children,
) -> []int {
	off, flat := flatten_children(old_ch)
	return tree_remap(hashes_of(old_nodes), off, flat, hashes_of(new_nodes), new_ch)
}

@(private = "file")
flatten_children :: proc(ch: []types.Children) -> ([]i32, []i32) {
	off := make([]i32, len(ch) + 1, context.temp_allocator)
	flat: [dynamic]i32
	flat.allocator = context.temp_allocator
	for c, i in ch {
		off[i] = i32(len(flat))
		append(&flat, ..c.value[:c.length])
	}
	off[len(ch)] = i32(len(flat))
	return off, flat[:]
}

@(test)
test_remap_identical_tree_is_identity :: proc(t: ^testing.T) {
	n, c := banner_tree()
	m := remap_trees(n, c, n, c)
	testing.expect_value(t, len(m), 4)
	for v, i in m do testing.expect_value(t, v, i)
}

@(test)
test_remap_removed_sibling_shifts_later_nodes :: proc(t: ^testing.T) {
	// The reviewer's repro: hiding the banner moves input A from idx 2 to
	// idx 1. Index 2 must not be carried over (it now names input B).
	on, oc := banner_tree()
	nn, nc := no_banner_tree()
	m := remap_trees(on, oc, nn, nc)
	testing.expect_value(t, m[0], 0)
	testing.expect_value(t, m[1], -1) // banner gone
	testing.expect_value(t, m[2], 1)  // input A
	testing.expect_value(t, m[3], 2)  // input B
}

@(test)
test_remap_inserted_sibling_shifts_later_nodes :: proc(t: ^testing.T) {
	on, oc := no_banner_tree()
	nn, nc := banner_tree()
	m := remap_trees(on, oc, nn, nc)
	testing.expect_value(t, m[0], 0)
	testing.expect_value(t, m[1], 2)
	testing.expect_value(t, m[2], 3)
}

@(test)
test_remap_scroll_panes_keep_identity :: proc(t: ^testing.T) {
	// [vbox [text] [vbox scroll-y] [vbox scroll-y]] -> banner removed.
	// Two indistinguishable panes still map pane-to-pane (suffix align),
	// never pane-1 -> pane-2.
	on := []types.Node{types.NodeVbox{}, types.NodeText{}, types.NodeVbox{overflow = "scroll-y"}, types.NodeVbox{overflow = "scroll-y"}}
	oc := []types.Children{kids(1, 2, 3), {}, {}, {}}
	nn := []types.Node{types.NodeVbox{}, types.NodeVbox{overflow = "scroll-y"}, types.NodeVbox{overflow = "scroll-y"}}
	nc := []types.Children{kids(1, 2), {}, {}}
	m := remap_trees(on, oc, nn, nc)
	testing.expect_value(t, m[2], 1)
	testing.expect_value(t, m[3], 2)
}

@(test)
test_remap_middle_edit_uses_lcs :: proc(t: ^testing.T) {
	// old [a t b]  new [a b btn]: prefix a, no suffix match, middle
	// [t b] vs [b btn] -> LCS pairs b with b.
	on := []types.Node{types.NodeVbox{}, input_node("a"), types.NodeText{}, input_node("b")}
	oc := []types.Children{kids(1, 2, 3), {}, {}, {}}
	nn := []types.Node{types.NodeVbox{}, input_node("a"), input_node("b"), types.NodeButton{click = "x"}}
	nc := []types.Children{kids(1, 2, 3), {}, {}, {}}
	m := remap_trees(on, oc, nn, nc)
	testing.expect_value(t, m[1], 1)
	testing.expect_value(t, m[2], -1)
	testing.expect_value(t, m[3], 2)
}

@(test)
test_remap_kind_change_at_same_position_drops :: proc(t: ^testing.T) {
	// A node replaced by a different kind (or an input with a different
	// :change) at the same position is a different node.
	on := []types.Node{types.NodeVbox{}, input_node("a")}
	oc := []types.Children{kids(1), {}}
	nn := []types.Node{types.NodeVbox{}, input_node("b")}
	nc := []types.Children{kids(1), {}}
	m := remap_trees(on, oc, nn, nc)
	testing.expect_value(t, m[0], 0)
	testing.expect_value(t, m[1], -1)
}

@(test)
test_remap_root_kind_change_drops_all :: proc(t: ^testing.T) {
	on := []types.Node{types.NodeVbox{}, input_node("a")}
	oc := []types.Children{kids(1), {}}
	nn := []types.Node{types.NodeHbox{}, input_node("a")}
	nc := []types.Children{kids(1), {}}
	m := remap_trees(on, oc, nn, nc)
	for v in m do testing.expect_value(t, v, -1)
}

@(test)
test_remap_dynamic_attrs_do_not_break_identity :: proc(t: ^testing.T) {
	// Value, aspect and content are per-frame data, not identity: an
	// input switching to an error aspect while the user types must keep
	// its focus.
	on := []types.Node{types.NodeVbox{}, types.NodeInput{change = "a", aspect = "input", value = "x"}}
	oc := []types.Children{kids(1), {}}
	nn := []types.Node{types.NodeVbox{}, types.NodeInput{change = "a", aspect = "input-error", value = "xy"}}
	nc := []types.Children{kids(1), {}}
	m := remap_trees(on, oc, nn, nc)
	testing.expect_value(t, m[1], 1)
}

@(test)
test_remap_on_frame_change_moves_focus :: proc(t: ^testing.T) {
	sync.lock(&g_input_test_state_mutex)
	defer sync.unlock(&g_input_test_state_mutex)
	state_init()
	defer state_destroy()
	defer remap_reset()
	defer focused_idx = -1

	on, oc := banner_tree()
	_, had := remap_on_frame_change(on, oc)
	testing.expect(t, !had, "first frame has no previous tree to map from")

	focused_idx = 2 // input A
	focus_enter("alpha")

	nn, nc := no_banner_tree()
	m, ok := remap_on_frame_change(nn, nc)
	testing.expect(t, ok)
	testing.expect_value(t, len(m), 4)
	testing.expect_value(t, focused_idx, 1)
	testing.expect(t, state.active, "focus follows input A; editing stays active")
}

@(test)
test_remap_on_frame_change_drops_focus_of_removed_node :: proc(t: ^testing.T) {
	sync.lock(&g_input_test_state_mutex)
	defer sync.unlock(&g_input_test_state_mutex)
	state_init()
	defer state_destroy()
	defer remap_reset()
	defer focused_idx = -1

	on, oc := no_banner_tree()
	remap_on_frame_change(on, oc)
	focused_idx = 1 // input A
	focus_enter("alpha")

	// Input A removed: [vbox [input :ev/b]].
	nn := []types.Node{types.NodeVbox{}, input_node("ev/b")}
	nc := []types.Children{kids(1), {}}
	remap_on_frame_change(nn, nc)
	testing.expect_value(t, focused_idx, -1)
	testing.expect(t, !state.active, "editing buffer must not attach to input B")
}

@(test)
test_remap_on_frame_change_moves_active_and_scrollbar :: proc(t: ^testing.T) {
	sync.lock(&g_input_test_state_mutex)
	defer sync.unlock(&g_input_test_state_mutex)
	state_init()
	defer state_destroy()
	defer remap_reset()
	defer active_idx = -1

	on, oc := banner_tree()
	remap_on_frame_change(on, oc)
	active_idx = 3
	scrollbar = Scrollbar_Dragging{hovering = {container_idx = 2, axis = .Y}, grab_offset_in_thumb = 5}

	nn, nc := no_banner_tree()
	remap_on_frame_change(nn, nc)
	testing.expect_value(t, active_idx, 2)
	d, is_drag := scrollbar.(Scrollbar_Dragging)
	testing.expect(t, is_drag)
	testing.expect_value(t, d.container_idx, 1)
	testing.expect_value(t, d.grab_offset_in_thumb, f32(5))

	// Container removed entirely → scrollbar state cleared.
	remap_on_frame_change([]types.Node{types.NodeVbox{}}, []types.Children{{}})
	testing.expect(t, scrollbar == nil)
	testing.expect_value(t, active_idx, -1)
}

@(test)
test_remap_on_frame_change_cancels_drag_of_removed_source :: proc(t: ^testing.T) {
	sync.lock(&g_input_test_state_mutex)
	defer sync.unlock(&g_input_test_state_mutex)
	state_init()
	defer state_destroy()
	defer remap_reset()

	on, oc := banner_tree()
	remap_on_frame_change(on, oc)
	drag = Drag_Active{
		captured      = Drag_Captured{src_idx = 3, src_tags = clone_string_slice([]string{"t"})},
		over_zone_idx = 2,
		over_drop_idx = -1,
	}

	nn, nc := no_banner_tree()
	remap_on_frame_change(nn, nc)
	a, is_active := drag.(Drag_Active)
	testing.expect(t, is_active)
	testing.expect_value(t, a.src_idx, 2)
	testing.expect_value(t, a.over_zone_idx, 1)

	remap_on_frame_change([]types.Node{types.NodeVbox{}}, []types.Children{{}})
	testing.expect(t, drag == nil, "drag whose source vanished is cancelled")
}
