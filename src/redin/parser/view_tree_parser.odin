package parser

import "../types"
import "core:fmt"
import "core:os"
import "core:strings"

// Internal tree used during parsing, then flattened to parallel arrays.

_Tree_Node :: struct {
	data:     types.Node,
	children: [dynamic]_Tree_Node,
}

// Free strings cloned by _parse_element on a parsed node. The parser
// only clones a subset of types.Node string fields, so this is a narrow
// mirror of bridge.clear_node_strings — DO NOT add fields the parser
// does not clone (those would be slices into source text and freeing
// them would be a bad free).
_clear_node_strings :: proc(n: types.Node) {
	switch v in n {
	case types.NodeStack:
	case types.NodeCanvas:
		if len(v.provider) > 0 do delete(v.provider)
		if len(v.aspect) > 0 do delete(v.aspect)
	case types.NodeVbox:
		if len(v.overflow) > 0 do delete(v.overflow)
		if len(v.aspect) > 0 do delete(v.aspect)
	case types.NodeHbox:
		if len(v.overflow) > 0 do delete(v.overflow)
		if len(v.aspect) > 0 do delete(v.aspect)
	case types.NodeInput:
		if len(v.aspect) > 0 do delete(v.aspect)
		if len(v.change) > 0 do delete(v.change)
		if len(v.key) > 0 do delete(v.key)
	case types.NodeButton:
		if len(v.label) > 0 do delete(v.label)
		if len(v.aspect) > 0 do delete(v.aspect)
		if len(v.click) > 0 do delete(v.click)
	case types.NodeText:
		if len(v.content) > 0 do delete(v.content)
		if len(v.aspect) > 0 do delete(v.aspect)
	case types.NodeImage:
		if len(v.aspect) > 0 do delete(v.aspect)
	case types.NodePopout:
		if len(v.aspect) > 0 do delete(v.aspect)
	case types.NodeModal:
		if len(v.aspect) > 0 do delete(v.aspect)
	}
}

// Tear down a parsed _Tree_Node that still owns its strings (i.e. the
// node has not been flattened). Frees children recursively, the children
// array itself, and the cloned strings on this node.
_tree_node_destroy :: proc(n: ^_Tree_Node) {
	for &child in n.children {
		_tree_node_destroy(&child)
	}
	delete(n.children)
	_clear_node_strings(n.data)
}

// Tear down a _Tree_Node after _flatten has copied n.data into the flat
// nodes array. _flatten transfers string ownership by shallow-copying the
// node value, so callers must NOT also free strings on the tree side —
// the flat nodes array is now responsible (free with _clear_node_strings).
_tree_node_destroy_after_flatten :: proc(n: ^_Tree_Node) {
	for &child in n.children {
		_tree_node_destroy_after_flatten(&child)
	}
	delete(n.children)
}

// -- Parser for [:tag {props}? "text"? children...] format --

// Maximum element-nesting depth accepted by the parser. A `.fnl` file
// nested deeper than this is refused outright (ok=false) rather than
// allowed to recurse into a stack overflow. Issue #136 (M1).
MAX_NESTING :: 256

_Parser :: struct {
	text:  string,
	pos:   int,
	depth: int,
}

_skip_ws :: proc(p: ^_Parser) {
	for p.pos < len(p.text) {
		c := p.text[p.pos]
		if c == ' ' || c == '\n' || c == '\r' || c == '\t' {
			p.pos += 1
		} else {
			break
		}
	}
}

_peek :: proc(p: ^_Parser) -> u8 {
	_skip_ws(p)
	if p.pos >= len(p.text) do return 0
	return p.text[p.pos]
}

_read_keyword :: proc(p: ^_Parser) -> string {
	p.pos += 1 // skip ':'
	start := p.pos
	for p.pos < len(p.text) {
		c := p.text[p.pos]
		if c == ' ' ||
		   c == '\n' ||
		   c == '\r' ||
		   c == '\t' ||
		   c == ']' ||
		   c == '}' ||
		   c == '{' ||
		   c == '[' {
			break
		}
		p.pos += 1
	}
	return p.text[start:p.pos]
}

_read_number :: proc(p: ^_Parser) -> f32 {
	neg: f32 = 1
	if p.pos < len(p.text) && p.text[p.pos] == '-' {
		neg = -1
		p.pos += 1
	}

	result: f32 = 0
	for p.pos < len(p.text) {
		c := p.text[p.pos]
		if c >= '0' && c <= '9' {
			result = result * 10 + f32(c - '0')
			p.pos += 1
		} else {
			break
		}
	}

	// Decimal part
	if p.pos < len(p.text) && p.text[p.pos] == '.' {
		p.pos += 1
		frac: f32 = 0.1
		for p.pos < len(p.text) {
			c := p.text[p.pos]
			if c >= '0' && c <= '9' {
				result += f32(c - '0') * frac
				frac *= 0.1
				p.pos += 1
			} else {
				break
			}
		}
	}

	return result * neg
}

_read_string :: proc(p: ^_Parser) -> string {
	p.pos += 1 // skip '"'
	start := p.pos
	for p.pos < len(p.text) && p.text[p.pos] != '"' {
		p.pos += 1
	}
	result := p.text[start:p.pos]
	if p.pos < len(p.text) do p.pos += 1 // skip closing '"'
	return result
}

_Prop_Kind :: enum {
	Keyword,
	Number,
	String_Lit,
}

_Prop :: struct {
	kind:    _Prop_Kind,
	str_val: string,
	num_val: f32,
}

_read_prop_value :: proc(p: ^_Parser) -> _Prop {
	c := _peek(p)
	if c == ':' {
		return _Prop{kind = .Keyword, str_val = _read_keyword(p)}
	} else if c >= '0' && c <= '9' {
		return _Prop{kind = .Number, num_val = _read_number(p)}
	} else if c == '"' {
		return _Prop{kind = .String_Lit, str_val = _read_string(p)}
	} else if c == '[' {
		// Vector value like [:test/add] — extract keyword inside
		p.pos += 1
		_skip_ws(p)
		result_str: string
		if p.pos < len(p.text) && p.text[p.pos] == ':' {
			result_str = _read_keyword(p)
		}
		_skip_ws(p)
		if p.pos < len(p.text) && p.text[p.pos] == ']' do p.pos += 1
		return _Prop{kind = .Keyword, str_val = result_str}
	}
	p.pos += 1
	return {}
}

_parse_props :: proc(p: ^_Parser) -> map[string]_Prop {
	p.pos += 1 // skip '{'
	props: map[string]_Prop
	for {
		c := _peek(p)
		if c == '}' {
			p.pos += 1
			break
		}
		if c == 0 do break
		if c == ':' {
			key := _read_keyword(p)
			val := _read_prop_value(p)
			props[key] = val
		} else {
			p.pos += 1
		}
	}
	return props
}

_parse_anchor :: proc(s: string) -> types.Anchor {
	switch s {
	case "top_left":      return .TOP_LEFT
	case "top_center":    return .TOP_CENTER
	case "top_right":     return .TOP_RIGHT
	case "center_left":   return .CENTER_LEFT
	case "center":        return .CENTER
	case "center_right":  return .CENTER_RIGHT
	case "bottom_left":   return .BOTTOM_LEFT
	case "bottom_center": return .BOTTOM_CENTER
	case "bottom_right":  return .BOTTOM_RIGHT
	case:                 return .TOP_LEFT
	}
}

_parse_size_f32 :: proc(v: _Prop) -> union {types.SizeValue, f32} {
	switch v.kind {
	case .Keyword:
		if v.str_val == "full" do return types.SizeValue.FULL
	case .Number:
		return v.num_val
	case .String_Lit:
		if v.str_val == "full" do return types.SizeValue.FULL
	}
	return nil
}

_parse_element :: proc(p: ^_Parser) -> (_Tree_Node, bool) {
	if p.depth >= MAX_NESTING {
		fmt.eprintfln(
			"view-tree parser: refusing input nested deeper than MAX_NESTING (%d)",
			MAX_NESTING,
		)
		return {}, false
	}
	p.depth += 1
	defer p.depth -= 1

	if _peek(p) != '[' do return {}, false
	p.pos += 1

	if _peek(p) != ':' do return {}, false
	tag := _read_keyword(p)

	props: map[string]_Prop
	defer delete(props)
	if _peek(p) == '{' {
		props = _parse_props(p)
	}

	text_content: string
	if _peek(p) == '"' {
		text_content = _read_string(p)
	}

	children: [dynamic]_Tree_Node
	// Bail out of the child loop on parse failure rather than silently
	// retrying — without this, a depth-limit refusal (MAX_NESTING) on
	// the next `[` would never consume the character and the parent
	// would loop forever. Propagate the failure to our caller so the
	// top-level parse reports ok=false. Issue #136 (M1).
	child_parse_failed := false
	for _peek(p) == '[' {
		child, ok := _parse_element(p)
		if !ok {
			child_parse_failed = true
			break
		}
		append(&children, child)
	}

	if child_parse_failed {
		for &c in children do _tree_node_destroy(&c)
		delete(children)
		return {}, false
	}

	if _peek(p) == ']' do p.pos += 1

	result: _Tree_Node
	result.children = children

	switch tag {
	case "stack":
		result.data = types.NodeStack{}
	case "canvas":
		c: types.NodeCanvas
		if v, ok := props["provider"]; ok {
			c.provider = strings.clone(v.str_val)
		}
		if v, ok := props["width"]; ok {
			switch v.kind {
			case .Keyword:
				if v.str_val == "full" do c.width = types.SizeValue.FULL
			case .Number:
				c.width = f16(v.num_val)
			case .String_Lit:
				if v.str_val == "full" do c.width = types.SizeValue.FULL
			}
		}
		if v, ok := props["height"]; ok {
			switch v.kind {
			case .Keyword:
				if v.str_val == "full" do c.height = types.SizeValue.FULL
			case .Number:
				c.height = f16(v.num_val)
			case .String_Lit:
				if v.str_val == "full" do c.height = types.SizeValue.FULL
			}
		}
		if a, ok := props["aspect"]; ok do c.aspect = strings.clone(a.str_val)
		result.data = c
	case "vbox":
		v: types.NodeVbox
		if ov, ok := props["overflow"]; ok {
			v.overflow = strings.clone(ov.str_val)
		}
		if l, ok := props["layout"]; ok {
			v.layout = _parse_anchor(l.str_val)
		}
		if a, ok := props["aspect"]; ok do v.aspect = strings.clone(a.str_val)
		if w, ok := props["width"]; ok {
			switch w.kind {
			case .Keyword:
				if w.str_val == "full" do v.width = types.SizeValue.FULL
			case .Number:
				v.width = f16(w.num_val)
			case .String_Lit:
				if w.str_val == "full" do v.width = types.SizeValue.FULL
			}
		}
		if h, ok := props["height"]; ok {
			switch h.kind {
			case .Keyword:
				if h.str_val == "full" do v.height = types.SizeValue.FULL
			case .Number:
				v.height = f16(h.num_val)
			case .String_Lit:
				if h.str_val == "full" do v.height = types.SizeValue.FULL
			}
		}
		result.data = v
	case "hbox":
		h: types.NodeHbox
		if ov, ok := props["overflow"]; ok do h.overflow = strings.clone(ov.str_val)
		if l, ok := props["layout"]; ok {
			h.layout = _parse_anchor(l.str_val)
		}
		if a, ok := props["aspect"]; ok do h.aspect = strings.clone(a.str_val)
		if w, ok := props["width"]; ok do h.width = _parse_size_f32(w)
		if ht, ok := props["height"]; ok do h.height = _parse_size_f32(ht)
		result.data = h
	case "input":
		inp: types.NodeInput
		if w, ok := props["width"]; ok do inp.width = _parse_size_f32(w)
		if h, ok := props["height"]; ok do inp.height = _parse_size_f32(h)
		if a, ok := props["aspect"]; ok do inp.aspect = strings.clone(a.str_val)
		if c, ok := props["change"]; ok do inp.change = strings.clone(c.str_val)
		if k, ok := props["key"]; ok do inp.key = strings.clone(k.str_val)
		result.data = inp
	case "button":
		btn: types.NodeButton
		if w, ok := props["width"]; ok do btn.width = _parse_size_f32(w)
		if h, ok := props["height"]; ok do btn.height = _parse_size_f32(h)
		if len(text_content) > 0 do btn.label = strings.clone(text_content)
		if a, ok := props["aspect"]; ok do btn.aspect = strings.clone(a.str_val)
		if c, ok := props["click"]; ok do btn.click = strings.clone(c.str_val)
		result.data = btn
	case "text":
		t: types.NodeText
		if len(text_content) > 0 do t.content = strings.clone(text_content)
		if a, ok := props["aspect"]; ok do t.aspect = strings.clone(a.str_val)
		if w, ok := props["width"]; ok do t.width = _parse_size_f32(w)
		if h, ok := props["height"]; ok do t.height = _parse_size_f32(h)
		if l, ok := props["layout"]; ok {
			t.layout = _parse_anchor(l.str_val)
		}
		result.data = t
	case "image":
		img: types.NodeImage
		if a, ok := props["aspect"]; ok do img.aspect = strings.clone(a.str_val)
		if w, ok := props["width"]; ok do img.width = _parse_size_f32(w)
		if h, ok := props["height"]; ok do img.height = _parse_size_f32(h)
		result.data = img
	case "popout":
		pop: types.NodePopout
		if a, ok := props["aspect"]; ok do pop.aspect = strings.clone(a.str_val)
		if w, ok := props["width"]; ok do pop.width = _parse_size_f32(w)
		if h, ok := props["height"]; ok do pop.height = _parse_size_f32(h)
		if x, ok := props["x"]; ok do pop.x = x.num_val
		if y, ok := props["y"]; ok do pop.y = y.num_val
		if m, ok := props["mode"]; ok {
			switch m.str_val {
			case "mouse":
				pop.mode = .MOUSE
			case "fixed":
				pop.mode = .FIXED
			}
		}
		result.data = pop
	case "modal":
		mod: types.NodeModal
		if a, ok := props["aspect"]; ok do mod.aspect = strings.clone(a.str_val)
		result.data = mod
	case:
		fmt.eprintfln("Unknown tag: %s", tag)
		return result, false
	}

	return result, true
}

// Flatten tree into parallel path/node arrays (depth-first).
// Shallow-copies n.data into the flat nodes array, transferring ownership
// of any cloned strings to the flat nodes. Callers must release strings on
// each flat node via _clear_node_strings, and must use
// _tree_node_destroy_after_flatten (not _tree_node_destroy) to tear down
// the source tree to avoid double-free.

_flatten :: proc(
	n: ^_Tree_Node,
	cur: ^[dynamic]u8,
	paths: ^[dynamic]types.Path,
	nodes: ^[dynamic]types.Node,
	parent_indices: ^[dynamic]int,
	children_list: ^[dynamic]types.Children,
	parent_idx: int,
) {
	my_idx := len(paths)

	p := make([]u8, len(cur))
	copy(p, cur[:])
	append(paths, types.Path{value = p, length = u8(len(p))})
	append(nodes, n.data)
	append(parent_indices, parent_idx)
	append(children_list, types.Children{}) // placeholder

	if len(n.children) > 0 {
		child_values := make([]i32, len(n.children))
		for &child, i in n.children {
			child_values[i] = i32(len(paths))
			append(cur, u8(i))
			_flatten(&child, cur, paths, nodes, parent_indices, children_list, my_idx)
			pop(cur)
		}
		children_list[my_idx] = types.Children {
			value  = child_values,
			length = i32(len(n.children)),
		}
	}
}

// -- Public API --

load_view_tree :: proc(
	filepath: string,
) -> (
	paths: [dynamic]types.Path,
	nodes: [dynamic]types.Node,
	parent_indices: [dynamic]int,
	children_list: [dynamic]types.Children,
	ok: bool,
) {
	data, err := os.read_entire_file(filepath, context.allocator)
	if err != nil {
		fmt.eprintfln("Failed to read %s", filepath)
		return {}, {}, {}, {}, false
	}
	defer delete(data)

	p := _Parser {
		text = string(data),
		pos  = 0,
	}
	tree, parse_ok := _parse_element(&p)
	if !parse_ok {
		fmt.eprintfln("Failed to parse %s", filepath)
		return {}, {}, {}, {}, false
	}
	defer _tree_node_destroy_after_flatten(&tree)

	cur: [dynamic]u8
	defer delete(cur)

	_flatten(&tree, &cur, &paths, &nodes, &parent_indices, &children_list, -1)
	return paths, nodes, parent_indices, children_list, true
}

print_flat_tree :: proc(paths: []types.Path, nodes: []types.Node) {
	for i in 0 ..< len(paths) {
		// Print path
		fmt.printf("[")
		for j in 0 ..< int(paths[i].length) {
			if j > 0 do fmt.printf(" ")
			fmt.printf("%v", paths[i].value[j])
		}
		fmt.printf("] ")

		// Print node
		switch d in nodes[i] {
		case types.NodeStack:
			fmt.println("stack")
		case types.NodeCanvas:
			fmt.printfln("canvas provider=%s", d.provider)
		case types.NodeVbox:
			if len(d.overflow) > 0 {
				fmt.printfln("vbox overflow=%s", d.overflow)
			} else {
				fmt.println("vbox")
			}
		case types.NodeInput:
			fmt.printfln("input %vx%v", d.width, d.height)
		case types.NodeButton:
			fmt.printfln("button %vx%v \"%s\"", d.width, d.height, d.label)
		case types.NodeText:
			fmt.println("text")
		case types.NodeHbox:
			fmt.println("hbox")
		case types.NodeImage:
			fmt.println("image")
		case types.NodePopout:
			fmt.println("popout")
		case types.NodeModal:
			fmt.println("modal")
		}
	}
}
