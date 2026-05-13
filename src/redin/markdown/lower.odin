package markdown

import "../types"

// Attributes the user wrote on `[:markdown {...} "source"]`.
// Read by the bridge from the Lua table, passed through to lower().
// Empty / zero-value fields mean "not set".
Wrapper_Attrs :: struct {
	aspect:   string,
	id:       string,
	width:    union {types.SizeValue, f16},
	height:   union {types.SizeValue, f16},
	overflow: string,
}

// Synthetic-tree representation of one [:markdown] subtree. Parallel
// arrays in DFS order, mirroring the bridge's flat-array convention so
// flatten_subtree's job is a straight copy with parent-index rebasing.
LoweredTree :: struct {
	nodes:          []types.Node,
	parent_indices: []i32, // -1 for the root, otherwise 0-based local index
}

// Lower a parsed []Block plus the user's wrapper attrs into a synthetic
// tree. Always wraps in a vbox even for a single block — predictable
// shape, no aspect collision between user :aspect and inner :md/*.
//
// `attrs.id` is currently dropped — there is no Odin-side wrapper-id
// storage, and the Fennel-side `/frames` walker still finds the
// markdown wrapper via the original Lua tree's :id attr. If a
// bridge-side id store is added later, propagate id at that time.
//
// Allocations come from `allocator` (typically context.temp_allocator).
lower :: proc(blocks: []Block, attrs: Wrapper_Attrs, allocator := context.allocator) -> LoweredTree {
	context.allocator = allocator

	nodes:   [dynamic]types.Node
	parents: [dynamic]i32

	// Root wrapper vbox.
	wrapper := types.NodeVbox{
		aspect   = attrs.aspect,
		width    = attrs.width,
		height   = attrs.height,
		overflow = attrs.overflow,
	}
	append(&nodes, wrapper)
	append(&parents, i32(-1))

	for blk in blocks {
		emit_block(&nodes, &parents, blk, 0)
	}

	return LoweredTree{
		nodes          = nodes[:],
		parent_indices = parents[:],
	}
}

emit_block :: proc(
	nodes:   ^[dynamic]types.Node,
	parents: ^[dynamic]i32,
	blk:     Block,
	parent:  i32,
) {
	switch blk.kind {
	case .Paragraph:
		emit_text(nodes, parents, "md/body", "", blk.spans, parent)
	case .Heading_1: emit_text(nodes, parents, "md/h1", "", blk.spans, parent)
	case .Heading_2: emit_text(nodes, parents, "md/h2", "", blk.spans, parent)
	case .Heading_3: emit_text(nodes, parents, "md/h3", "", blk.spans, parent)
	case .Heading_4: emit_text(nodes, parents, "md/h4", "", blk.spans, parent)
	case .Heading_5: emit_text(nodes, parents, "md/h5", "", blk.spans, parent)
	case .Heading_6: emit_text(nodes, parents, "md/h6", "", blk.spans, parent)
	case .List_Group:
		list_idx := i32(len(nodes^))
		append(nodes, types.NodeVbox{aspect = "md/list"})
		append(parents, parent)
		for item in blk.items {
			emit_list_item(nodes, parents, item, list_idx)
		}
	case .List_Item:
		// List items are emitted via emit_list_item from List_Group;
		// reaching here means malformed input — emit as paragraph
		// fallback so we don't lose content.
		emit_text(nodes, parents, "md/body", "", blk.spans, parent)
	}
}

// #111: marker gets a fixed column width. Without it, the hbox treats
// both children as fill (no preferred width) and splits the row 50/50,
// pushing the body to the middle. 28px comfortably fits "•" through
// "99." at the default md/body font size.
MARKER_COLUMN_WIDTH :: 28.0

emit_list_item :: proc(
	nodes:   ^[dynamic]types.Node,
	parents: ^[dynamic]i32,
	item:    Block,
	parent:  i32,
) {
	hbox_idx := i32(len(nodes^))
	append(nodes, types.NodeHbox{aspect = "md/list-item"})
	append(parents, parent)

	marker_text := item.marker
	if len(marker_text) == 0 do marker_text = "•"
	append(nodes, types.NodeText{
		aspect  = "md/list-marker",
		content = marker_text,
		width   = f32(MARKER_COLUMN_WIDTH),
	})
	append(parents, hbox_idx)
	emit_text(nodes, parents, "md/body", "", item.spans, hbox_idx)
}

emit_text :: proc(
	nodes:   ^[dynamic]types.Node,
	parents: ^[dynamic]i32,
	aspect:  string,
	plain:   string,
	spans:   []Span,
	parent:  i32,
) {
	t := types.NodeText{
		aspect       = aspect,
		content      = plain,
		inline_spans  = spans,
	}
	// If spans are provided, content stays empty — the renderer reads
	// from inline_spans. If spans is nil and plain is set (markers),
	// content drives a plain render.
	append(nodes, t)
	append(parents, parent)
}
