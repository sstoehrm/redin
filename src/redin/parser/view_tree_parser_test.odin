package parser

import "core:testing"
import "../types"

@(test)
test_parse_simple_stack :: proc(t: ^testing.T) {
	input := `[:stack]`
	p := _Parser{text = input, pos = 0}
	tree, ok := _parse_element(&p)
	defer _tree_node_destroy(&tree)
	testing.expect(t, ok, "parse should succeed")
	_, is_stack := tree.data.(types.NodeStack)
	testing.expect(t, is_stack, "root should be NodeStack")
}

@(test)
test_parse_text_with_content :: proc(t: ^testing.T) {
	input := `[:text {} "hello world"]`
	p := _Parser{text = input, pos = 0}
	tree, ok := _parse_element(&p)
	defer _tree_node_destroy(&tree)
	testing.expect(t, ok, "parse should succeed")
	txt, is_text := tree.data.(types.NodeText)
	testing.expect(t, is_text, "should be NodeText")
	testing.expect_value(t, txt.content, "hello world")
}

@(test)
test_parse_button_with_label :: proc(t: ^testing.T) {
	input := `[:button {:width 200 :height 40} "Click me"]`
	p := _Parser{text = input, pos = 0}
	tree, ok := _parse_element(&p)
	defer _tree_node_destroy(&tree)
	testing.expect(t, ok, "parse should succeed")
	btn, is_btn := tree.data.(types.NodeButton)
	testing.expect(t, is_btn, "should be NodeButton")
	testing.expect_value(t, btn.label, "Click me")
	w, w_ok := btn.width.(f32)
	testing.expect(t, w_ok, "button width should be f32")
	if w_ok do testing.expect_value(t, w, 200)
}

@(test)
test_parse_vbox_with_aspect :: proc(t: ^testing.T) {
	input := `[:vbox {:aspect :surface :layout :center}]`
	p := _Parser{text = input, pos = 0}
	tree, ok := _parse_element(&p)
	defer _tree_node_destroy(&tree)
	testing.expect(t, ok, "parse should succeed")
	vb, is_vb := tree.data.(types.NodeVbox)
	testing.expect(t, is_vb, "should be NodeVbox")
	testing.expect_value(t, vb.aspect, "surface")
	testing.expect_value(t, vb.layout, types.Anchor.CENTER)
}

@(test)
test_parse_input_with_handlers :: proc(t: ^testing.T) {
	input := `[:input {:width 250 :height 42 :aspect :input :change [:test/change] :key [:test/key]}]`
	p := _Parser{text = input, pos = 0}
	tree, ok := _parse_element(&p)
	defer _tree_node_destroy(&tree)
	testing.expect(t, ok, "parse should succeed")
	inp, is_inp := tree.data.(types.NodeInput)
	testing.expect(t, is_inp, "should be NodeInput")
	testing.expect_value(t, inp.aspect, "input")
	testing.expect_value(t, inp.change, "test/change")
	testing.expect_value(t, inp.key, "test/key")
}

@(test)
test_parse_nested_tree :: proc(t: ^testing.T) {
	input := `[:vbox {} [:text {} "a"] [:text {} "b"]]`
	p := _Parser{text = input, pos = 0}
	tree, ok := _parse_element(&p)
	defer _tree_node_destroy(&tree)
	testing.expect(t, ok, "parse should succeed")
	testing.expect_value(t, len(tree.children), 2)
	t1, is_t1 := tree.children[0].data.(types.NodeText)
	testing.expect(t, is_t1, "child 0 should be NodeText")
	testing.expect_value(t, t1.content, "a")
	t2, is_t2 := tree.children[1].data.(types.NodeText)
	testing.expect(t, is_t2, "child 1 should be NodeText")
	testing.expect_value(t, t2.content, "b")
}

@(test)
test_parse_canvas_full_size :: proc(t: ^testing.T) {
	input := `[:canvas {:provider :chart :width :full :height :full}]`
	p := _Parser{text = input, pos = 0}
	tree, ok := _parse_element(&p)
	defer _tree_node_destroy(&tree)
	testing.expect(t, ok, "parse should succeed")
	c, is_c := tree.data.(types.NodeCanvas)
	testing.expect(t, is_c, "should be NodeCanvas")
	testing.expect_value(t, c.provider, "chart")
	_, w_full := c.width.(types.SizeValue)
	testing.expect(t, w_full, "width should be SizeValue.FULL")
}

@(test)
test_parse_hbox :: proc(t: ^testing.T) {
	input := `[:hbox {:aspect :toolbar :layout :left}]`
	p := _Parser{text = input, pos = 0}
	tree, ok := _parse_element(&p)
	defer _tree_node_destroy(&tree)
	testing.expect(t, ok, "parse should succeed")
	h, is_h := tree.data.(types.NodeHbox)
	testing.expect(t, is_h, "should be NodeHbox")
	testing.expect_value(t, h.aspect, "toolbar")
	testing.expect_value(t, h.layout, types.Anchor.TOP_LEFT)
}

@(test)
test_parse_image :: proc(t: ^testing.T) {
	input := `[:image {:aspect :logo :width 100 :height 50}]`
	p := _Parser{text = input, pos = 0}
	tree, ok := _parse_element(&p)
	defer _tree_node_destroy(&tree)
	testing.expect(t, ok, "parse should succeed")
	img, is_img := tree.data.(types.NodeImage)
	testing.expect(t, is_img, "should be NodeImage")
	testing.expect_value(t, img.aspect, "logo")
}

@(test)
test_parse_modal :: proc(t: ^testing.T) {
	input := `[:modal {:aspect :overlay}]`
	p := _Parser{text = input, pos = 0}
	tree, ok := _parse_element(&p)
	defer _tree_node_destroy(&tree)
	testing.expect(t, ok, "parse should succeed")
	m, is_m := tree.data.(types.NodeModal)
	testing.expect(t, is_m, "should be NodeModal")
	testing.expect_value(t, m.aspect, "overlay")
}

@(test)
test_parse_unknown_tag_fails :: proc(t: ^testing.T) {
	input := `[:bogus {}]`
	p := _Parser{text = input, pos = 0}
	_, ok := _parse_element(&p)
	testing.expect(t, !ok, "unknown tag should fail")
}

@(test)
test_flatten_produces_correct_count :: proc(t: ^testing.T) {
	input := `[:vbox {} [:text {} "a"] [:text {} "b"] [:text {} "c"]]`
	p := _Parser{text = input, pos = 0}
	tree, ok := _parse_element(&p)
	testing.expect(t, ok, "parse should succeed")
	defer _tree_node_destroy(&tree)

	paths: [dynamic]types.Path
	nodes: [dynamic]types.Node
	parent_indices: [dynamic]int
	children_list: [dynamic]types.Children
	cur: [dynamic]u8
	defer delete(cur)

	_flatten(&tree, &cur, &paths, &nodes, &parent_indices, &children_list, -1)
	defer {
		for &pa in paths do delete(pa.value)
		delete(paths)
		delete(nodes)
		delete(parent_indices)
		for &ch in children_list do delete(ch.value)
		delete(children_list)
	}

	testing.expect_value(t, len(nodes), 4) // vbox + 3 text
	testing.expect_value(t, children_list[0].length, 3) // vbox has 3 children
	testing.expect_value(t, parent_indices[0], -1) // root has no parent
	testing.expect_value(t, parent_indices[1], 0) // first child's parent is root
}

@(test)
test_read_number_decimal :: proc(t: ^testing.T) {
	input := "3.14"
	p := _Parser{text = input, pos = 0}
	val := _read_number(&p)
	testing.expect(t, val > 3.13 && val < 3.15, "should parse 3.14")
}

@(test)
test_read_number_negative :: proc(t: ^testing.T) {
	input := "-42"
	p := _Parser{text = input, pos = 0}
	val := _read_number(&p)
	testing.expect_value(t, val, -42.0)
}

@(test)
test_vector_prop_value :: proc(t: ^testing.T) {
	input := `[:test/add]`
	p := _Parser{text = input, pos = 0}
	prop := _read_prop_value(&p)
	testing.expect_value(t, prop.kind, _Prop_Kind.Keyword)
	testing.expect_value(t, prop.str_val, "test/add")
}
