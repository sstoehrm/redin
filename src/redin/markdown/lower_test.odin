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
	// #111: marker must carry a fixed column width so hbox doesn't split
	// the row 50/50 between marker and body.
	mw, mw_ok := mk.width.(f32)
	testing.expect(t, mw_ok, "marker width must be a fixed f32")
	testing.expect_value(t, mw, f32(MARKER_COLUMN_WIDTH))
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
	// Wrapper :id is not propagated to LoweredTree — there is no
	// bridge-side wrapper id store. Fennel-side `/frames` finds the
	// wrapper by reading the original Lua attrs (still carries :id).
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

@(test)
test_lower_copyable_emits_copy_button :: proc(t: ^testing.T) {
	src := "# Title\n\nbody"
	blocks := parse(src, context.temp_allocator)
	tree := lower(blocks, Wrapper_Attrs{copyable = true}, context.temp_allocator, src)
	// local 0 = wrapper vbox, 1 = md/copy-bar hbox, 2 = Copy button.
	bar, bar_ok := tree.nodes[1].(types.NodeHbox)
	testing.expect(t, bar_ok, "node 1 must be the copy-bar hbox")
	testing.expect_value(t, bar.aspect, "md/copy-bar")
	testing.expect_value(t, bar.layout, types.Anchor.CENTER_RIGHT)
	if w, w_ok := bar.width.(types.SizeValue); w_ok {
		testing.expect_value(t, w, types.SizeValue.FULL)
	} else {
		testing.expect(t, false, "copy-bar width must be SizeValue.FULL")
	}
	testing.expect_value(t, tree.parent_indices[1], i32(0))
	btn, btn_ok := tree.nodes[2].(types.NodeButton)
	testing.expect(t, btn_ok, "node 2 must be the Copy button")
	testing.expect_value(t, btn.label, "Copy")
	testing.expect_value(t, btn.aspect, "md/copy-button")
	testing.expect_value(t, btn.copy_text, src)
	testing.expect_value(t, tree.parent_indices[2], i32(1))
}

@(test)
test_lower_not_copyable_has_no_button :: proc(t: ^testing.T) {
	blocks := parse("# Title", context.temp_allocator)
	tree := lower(blocks, Wrapper_Attrs{}, context.temp_allocator)
	for n in tree.nodes {
		_, is_btn := n.(types.NodeButton)
		testing.expect(t, !is_btn, "non-copyable markdown must not emit a button")
	}
}

@(test)
test_lower_text_is_not_selectable :: proc(t: ^testing.T) {
	blocks := parse("# Title\n\nbody\n\n- item", context.temp_allocator)
	tree := lower(blocks, Wrapper_Attrs{}, context.temp_allocator)
	for n in tree.nodes {
		if tn, ok := n.(types.NodeText); ok {
			testing.expectf(t, tn.not_selectable,
				"lowered text node (aspect %q) must be not_selectable", tn.aspect)
		}
	}
}

@(test)
test_lower_copy_button_has_compact_dimensions :: proc(t: ^testing.T) {
	blocks := parse("# Title", context.temp_allocator)
	tree := lower(blocks, Wrapper_Attrs{copyable = true}, context.temp_allocator, "# Title")
	// Explicit sizes are load-bearing: an unset width/height makes a redin node
	// fill its container, so without these the button would expand to fill the
	// whole block instead of a compact, right-aligned chip.
	bar, bar_ok := tree.nodes[1].(types.NodeHbox)
	testing.expect(t, bar_ok, "node 1 must be the copy-bar hbox")
	if bh, ok := bar.height.(f32); ok {
		testing.expect_value(t, bh, f32(COPY_BAR_HEIGHT))
	} else {
		testing.expect(t, false, "copy-bar must have an explicit f32 height")
	}
	btn, btn_ok := tree.nodes[2].(types.NodeButton)
	testing.expect(t, btn_ok, "node 2 must be the Copy button")
	if bw, ok := btn.width.(f32); ok {
		testing.expect_value(t, bw, f32(COPY_BUTTON_WIDTH))
	} else {
		testing.expect(t, false, "copy button must have an explicit f32 width")
	}
	if bhh, ok := btn.height.(f32); ok {
		testing.expect_value(t, bhh, f32(COPY_BUTTON_HEIGHT))
	} else {
		testing.expect(t, false, "copy button must have an explicit f32 height")
	}
}
