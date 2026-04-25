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

	empty_paths: []types.Path
	empty_nodes: []types.Node
	resolve_text_selection(empty_paths, empty_nodes)
	testing.expect_value(t, state.selection_kind, Selection_Kind.None)
}

@(test)
test_resolve_clears_when_content_shrinks :: proc(t: ^testing.T) {
	state_init()
	defer state_destroy()

	p := [1]u8{0x01}
	paths := []types.Path{{value = p[:], length = 1}}
	nodes := []types.Node{types.NodeText{content = "hi"}}
	set_text_selection([]u8{0x01}, 0, 5) // 5 > len("hi") → stale
	resolve_text_selection(paths, nodes)
	testing.expect_value(t, state.selection_kind, Selection_Kind.None)
}
