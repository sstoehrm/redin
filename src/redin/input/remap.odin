package input

import "../types"

// Review C4: carry per-index state across a re-flatten.
//
// focused_idx, active_idx, the scrollbar's container_idx and the drag
// state's src/zone/drop indices (and, in package redin, the scroll-offset
// maps and layout rects) are DFS indices into the flat view tree. A node
// inserted or removed before them — `(when show [:text "banner"])` going
// away — shifts every later index, so the stored index silently names a
// different node: the focused input's editing buffer re-attached to the
// *next* input, a scroll pane inherited its neighbour's offset.
//
// Positional paths don't fix this on their own: the frame flattener
// compacts nil children, so a removed sibling shifts the later siblings'
// path steps exactly like their DFS indices. Instead, on every frame
// change we align the previous tree with the new one, top-down, matching
// each mapped parent's children by a per-node identity hash (kind + the
// node's behavioural attributes: event names, overflow mode). Children
// are matched by common prefix, common suffix, then an LCS over the
// middle, so an insert/remove of a sibling no longer shifts identity.
// State whose node has no counterpart in the new tree is dropped (focus
// left, drag cancelled, scrollbar released).
//
// Limits (no `:id`/key in the flat tree yet): identical siblings — rows
// of a list with the same events — are told apart only by position, so
// an insert *among* them maps by prefix order; a node whose kind or event
// names change is treated as a new node.

@(private = "file")
Tree_Snapshot :: struct {
	hashes:  [dynamic]u64,
	kid_off: [dynamic]i32, // per-node start into kids; len = node count + 1
	kids:    [dynamic]i32,
	valid:   bool,
}

@(private = "file")
g_snapshot: Tree_Snapshot

// Upper bound on the LCS table (old_middle × new_middle cells) per
// parent. Prefix/suffix trimming handles the common single insert /
// remove without it; above the cap the unmatched middle is dropped.
REMAP_LCS_CAP :: 1 << 16

// Identity hash of one node: FNV-1a over its kind plus the attributes
// that say what the node *does*. Deliberately excludes per-frame data
// (input value, text content, labels, aspect — apps swap an input's
// aspect for an error state while the user types).
node_identity_hash :: proc(n: types.Node) -> u64 {
	h: u64 = 0xcbf29ce484222325
	mix_byte :: proc(h: ^u64, b: u8) {
		h^ ~= u64(b)
		h^ *= 0x100000001b3
	}
	mix_str :: proc(h: ^u64, s: string) {
		for i in 0 ..< len(s) do mix_byte(h, s[i])
		mix_byte(h, 0xff)
	}
	box :: proc(h: ^u64, overflow: string, dr: Maybe(types.Draggable_Attrs), dp: Maybe(types.Dropable_Attrs), dov: Maybe(types.Drag_Over_Attrs)) {
		mix_str(h, overflow)
		if d, ok := dr.?; ok do mix_str(h, d.event)
		mix_byte(h, 0xfe)
		if d, ok := dp.?; ok do mix_str(h, d.event)
		mix_byte(h, 0xfe)
		if d, ok := dov.?; ok do mix_str(h, d.event)
	}

	switch v in n {
	case types.NodeStack:
		mix_byte(&h, 1)
	case types.NodeCanvas:
		mix_byte(&h, 2)
		mix_str(&h, v.provider)
	case types.NodeVbox:
		mix_byte(&h, 3)
		box(&h, v.overflow, v.draggable, v.dropable, v.drag_over)
	case types.NodeHbox:
		mix_byte(&h, 4)
		box(&h, v.overflow, v.draggable, v.dropable, v.drag_over)
	case types.NodeInput:
		mix_byte(&h, 5)
		mix_str(&h, v.change)
		mix_str(&h, v.key)
	case types.NodeButton:
		mix_byte(&h, 6)
		mix_str(&h, v.click)
	case types.NodeText:
		mix_byte(&h, 7)
		mix_str(&h, v.overflow)
	case types.NodeImage:
		mix_byte(&h, 8)
	case types.NodePopout:
		mix_byte(&h, 9)
	case types.NodeModal:
		mix_byte(&h, 10)
	case:
		mix_byte(&h, 0)
	}
	return h
}

// Map every old node index to its new index (-1 = no counterpart).
// Pure; the result is allocated with `allocator` (temp by default).
tree_remap :: proc(
	old_hashes:   []u64,
	old_kid_off:  []i32,
	old_kids:     []i32,
	new_hashes:   []u64,
	new_children: []types.Children,
	allocator := context.temp_allocator,
) -> []int {
	o2n := make([]int, len(old_hashes), allocator)
	for &v in o2n do v = -1
	if len(old_hashes) == 0 || len(new_hashes) == 0 do return o2n
	if len(old_kid_off) != len(old_hashes) + 1 do return o2n
	if old_hashes[0] != new_hashes[0] do return o2n

	work: [dynamic][2]int
	work.allocator = context.temp_allocator
	append(&work, [2]int{0, 0})
	for len(work) > 0 {
		pr := pop(&work)
		o, n := pr[0], pr[1]
		o2n[o] = n

		lo, hi := int(old_kid_off[o]), int(old_kid_off[o + 1])
		if lo < 0 || hi > len(old_kids) || lo > hi do continue
		oc := old_kids[lo:hi]
		nc: []i32
		if n < len(new_children) {
			c := new_children[n]
			if c.length > 0 && int(c.length) <= len(c.value) do nc = c.value[:c.length]
		}
		align_children(oc, nc, old_hashes, new_hashes, &work)
	}
	return o2n
}

@(private = "file")
align_children :: proc(
	oc, nc: []i32,
	oh, nh: []u64,
	out: ^[dynamic][2]int,
) {
	ok_o :: proc(i: i32, h: []u64) -> bool { return i >= 0 && int(i) < len(h) }
	eq :: proc(a, b: i32, oh, nh: []u64) -> bool {
		return ok_o(a, oh) && ok_o(b, nh) && oh[a] == nh[b]
	}

	lo := 0
	for lo < len(oc) && lo < len(nc) && eq(oc[lo], nc[lo], oh, nh) {
		append(out, [2]int{int(oc[lo]), int(nc[lo])})
		lo += 1
	}
	ho, hn := len(oc), len(nc)
	for ho > lo && hn > lo && eq(oc[ho - 1], nc[hn - 1], oh, nh) {
		ho -= 1
		hn -= 1
		append(out, [2]int{int(oc[ho]), int(nc[hn])})
	}

	om := oc[lo:ho]
	nm := nc[lo:hn]
	m, k := len(om), len(nm)
	if m == 0 || k == 0 || m * k > REMAP_LCS_CAP do return

	// dp[i*(k+1)+j] = LCS length of om[i:] and nm[j:].
	w := k + 1
	dp := make([]i32, (m + 1) * w, context.temp_allocator)
	for i := m - 1; i >= 0; i -= 1 {
		for j := k - 1; j >= 0; j -= 1 {
			if eq(om[i], nm[j], oh, nh) {
				dp[i * w + j] = dp[(i + 1) * w + j + 1] + 1
			} else {
				dp[i * w + j] = max(dp[(i + 1) * w + j], dp[i * w + j + 1])
			}
		}
	}
	i, j := 0, 0
	for i < m && j < k {
		if eq(om[i], nm[j], oh, nh) {
			append(out, [2]int{int(om[i]), int(nm[j])})
			i += 1
			j += 1
		} else if dp[(i + 1) * w + j] >= dp[i * w + j + 1] {
			i += 1
		} else {
			j += 1
		}
	}
}

@(private = "file")
remap_one :: proc(m: []int, idx: int) -> int {
	if idx < 0 || idx >= len(m) do return -1
	return m[idx]
}

// Call once whenever the flat tree may have been re-flattened (the
// runtime's `frame_changed` blocks). Aligns the previous tree with
// `nodes` / `children_list`, moves the input package's per-index state
// to the new indices, then records the new tree as the baseline.
//
// Returns the old→new map (temp-allocated) so the caller can remap its
// own per-index state; ok = false on the first call (no previous tree),
// in which case per-index state is left untouched.
remap_on_frame_change :: proc(
	nodes: []types.Node,
	children_list: []types.Children,
) -> (old_to_new: []int, ok: bool) {
	new_hashes := make([]u64, len(nodes), context.temp_allocator)
	for n, i in nodes do new_hashes[i] = node_identity_hash(n)

	if g_snapshot.valid {
		old_to_new = tree_remap(
			g_snapshot.hashes[:], g_snapshot.kid_off[:], g_snapshot.kids[:],
			new_hashes, children_list,
		)
		ok = true
		remap_input_state(old_to_new)
	}

	clear(&g_snapshot.hashes)
	clear(&g_snapshot.kid_off)
	clear(&g_snapshot.kids)
	append(&g_snapshot.hashes, ..new_hashes)
	for i in 0 ..< len(nodes) {
		append(&g_snapshot.kid_off, i32(len(g_snapshot.kids)))
		if i < len(children_list) {
			c := children_list[i]
			if c.length > 0 && int(c.length) <= len(c.value) {
				append(&g_snapshot.kids, ..c.value[:c.length])
			}
		}
	}
	append(&g_snapshot.kid_off, i32(len(g_snapshot.kids)))
	g_snapshot.valid = true
	return
}

@(private = "file")
remap_input_state :: proc(m: []int) {
	if focused_idx >= 0 {
		focused_idx = remap_one(m, focused_idx)
		// The focused node has no counterpart: leave editing so the
		// buffer can't attach to whatever node now holds the index.
		if focused_idx < 0 do focus_leave()
	}
	if active_idx >= 0 do active_idx = remap_one(m, active_idx)

	// Copy the variant out, update it, and store the whole union back.
	// Odin dev-2026-10 miscompiles in-place writes through
	// `switch &s in <package global>` (or `&global.(T)`) when the switch
	// is in a different file from the global's declaration and the build
	// uses separate modules (the default for -o:none/-o:minimal, i.e.
	// `odin build`, `build-dev.sh`, `odin test`): `&s` binds a stack copy
	// and the write is dropped. -o:speed / -use-single-module are fine.
	// process_drag (drag.odin) and apply_scrollbar (scrollbar.odin) only
	// write in place from the global's own file, which is unaffected.
	switch s in scrollbar {
	case Scrollbar_Hovering:
		v := s
		v.container_idx = remap_one(m, v.container_idx)
		scrollbar = v if v.container_idx >= 0 else nil
	case Scrollbar_Dragging:
		v := s
		v.container_idx = remap_one(m, v.container_idx)
		scrollbar = v if v.container_idx >= 0 else nil
	}

	switch s in drag {
	case nil, Drag_Idle:
	case Drag_Pending:
		v := s
		v.src_idx = remap_one(m, v.src_idx)
		if v.src_idx < 0 {
			free_captured(v.captured)
			drag = nil
		} else {
			drag = v
		}
	case Drag_Active:
		v := s
		v.src_idx = remap_one(m, v.src_idx)
		if v.src_idx < 0 {
			free_captured(v.captured)
			drag = nil
		} else {
			if v.over_zone_idx >= 0 do v.over_zone_idx = remap_one(m, v.over_zone_idx)
			if v.over_drop_idx >= 0 do v.over_drop_idx = remap_one(m, v.over_drop_idx)
			drag = v
		}
	}
}

// Free the snapshot and forget the baseline tree. Called from
// state_destroy (and tests).
remap_reset :: proc() {
	delete(g_snapshot.hashes)
	delete(g_snapshot.kid_off)
	delete(g_snapshot.kids)
	g_snapshot = {}
}
