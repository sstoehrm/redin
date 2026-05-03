package markdown

import "core:testing"
import "../types"
import text_pkg "../text"

@(test)
test_lower_single_paragraph :: proc(t: ^testing.T) {
	blocks := parse("hello world", context.temp_allocator)
	tree := lower(blocks, Wrapper_Attrs{}, context.temp_allocator)

	// Wrapper vbox + one text child.
	testing.expect_value(t, len(tree.nodes), 2)
	_, ok := tree.nodes[0].(types.NodeVbox)
	testing.expect(t, ok, "root must be a vbox")
	tn, tok := tree.nodes[1].(types.NodeText)
	testing.expect(t, tok, "child must be a text node")
	testing.expect_value(t, tn.aspect, "md/body")
	testing.expect(t, len(tn.inline_spans) > 0, "inline_spans must be set")
	testing.expect_value(t, tree.parent_indices[0], -1)
	testing.expect_value(t, tree.parent_indices[1], 0)
}

@(test)
test_lower_heading_then_paragraph :: proc(t: ^testing.T) {
	blocks := parse("# Title\n\nA body.", context.temp_allocator)
	tree := lower(blocks, Wrapper_Attrs{}, context.temp_allocator)

	testing.expect_value(t, len(tree.nodes), 3)
	h, hok := tree.nodes[1].(types.NodeText)
	testing.expect(t, hok)
	testing.expect_value(t, h.aspect, "md/h1")
	p, pok := tree.nodes[2].(types.NodeText)
	testing.expect(t, pok)
	testing.expect_value(t, p.aspect, "md/body")
}

@(test)
test_lower_list :: proc(t: ^testing.T) {
	blocks := parse("- one\n- two", context.temp_allocator)
	tree := lower(blocks, Wrapper_Attrs{}, context.temp_allocator)

	// Expected DFS order:
	//   0 wrapper vbox
	//   1 list vbox (:md/list)
	//   2 list-item hbox (:md/list-item)
	//   3 marker text (:md/list-marker)
	//   4 content text (:md/body)
	//   5 list-item hbox
	//   6 marker text
	//   7 content text
	testing.expect_value(t, len(tree.nodes), 8)
	lv, _ := tree.nodes[1].(types.NodeVbox)
	testing.expect_value(t, lv.aspect, "md/list")
	li, _ := tree.nodes[2].(types.NodeHbox)
	testing.expect_value(t, li.aspect, "md/list-item")
	mk, _ := tree.nodes[3].(types.NodeText)
	testing.expect_value(t, mk.aspect, "md/list-marker")
	testing.expect_value(t, mk.content, "•")
	cn, _ := tree.nodes[4].(types.NodeText)
	testing.expect_value(t, cn.aspect, "md/body")
}

@(test)
test_lower_wrapper_attrs_pass_through :: proc(t: ^testing.T) {
	blocks := parse("hello", context.temp_allocator)
	tree := lower(blocks, Wrapper_Attrs{
		aspect = "card",
		id     = "reply",
	}, context.temp_allocator)
	wv, _ := tree.nodes[0].(types.NodeVbox)
	testing.expect_value(t, wv.aspect, "card")
	testing.expect_value(t, tree.ids[0], "reply")
}

@(test)
test_lower_inline_spans_round_trip :: proc(t: ^testing.T) {
	blocks := parse("hi **there**", context.temp_allocator)
	tree := lower(blocks, Wrapper_Attrs{}, context.temp_allocator)
	tn, _ := tree.nodes[1].(types.NodeText)
	testing.expect_value(t, len(tn.inline_spans), 2)
	testing.expect_value(t, tn.inline_spans[0].style, text_pkg.Span_Style.Regular)
	testing.expect_value(t, tn.inline_spans[1].style, text_pkg.Span_Style.Bold)
	testing.expect_value(t, tn.inline_spans[1].text, "there")
}
