package types

SizeValue :: enum {
	FULL,
}

Fraction :: struct {
	num: u8,
	den: u8,
}

ViewportValue :: union {
	f32,
	SizeValue,
	Fraction,
}

Anchor :: enum u8 {
	TOP_LEFT,
	TOP_CENTER,
	TOP_RIGHT,
	CENTER_LEFT,
	CENTER,
	CENTER_RIGHT,
	BOTTOM_LEFT,
	BOTTOM_CENTER,
	BOTTOM_RIGHT,
}

ViewportRect :: struct {
	anchor: Anchor,
	x:      ViewportValue,
	y:      ViewportValue,
	w:      ViewportValue,
	h:      ViewportValue,
}

Animate_Z :: enum u8 {
	Above,
	Behind,
}

Animate_Decoration :: struct {
	provider: string,        // owned, freed by clear_frame
	rect:     ViewportRect,  // resolved against the host node's rect (not window)
	z:        Animate_Z,
}

Drag_Mode :: enum u8 {
	Preview, // default — clone of dragged subtree at cursor
	None,    // no clone — source receives aspect/animate in place
}

// :draggable — declares "what I am" + how I behave while dragged.
Draggable_Attrs :: struct {
	tags:    []string,                  // owned slice of cloned strings
	event:   string,                    // owned, freed by clear_node_strings
	mode:    Drag_Mode,                 // zero = .Preview
	aspect:  string,                    // owned
	animate: Maybe(Animate_Decoration), // owned provider string inside
	ctx:     i32,                       // Lua registry ref (0 = none)
}

// :dropable — declares "what I accept" + how it looks on hover.
Dropable_Attrs :: struct {
	tags:    []string,
	event:   string,
	aspect:  string,
	animate: Maybe(Animate_Decoration),
	ctx:     i32,
}

// :drag-over — container-level zone (no payload).
Drag_Over_Attrs :: struct {
	tags:    []string,
	event:   string,
	aspect:  string,
	animate: Maybe(Animate_Decoration),
}

Path :: struct {
	value:  []u8,
	length: u8,
}

Children :: struct {
	value:  []i32,
	length: i32,
}

NodeStack :: struct {
	viewport:       []ViewportRect,
}

NodeCanvas :: struct {
	provider: string,
	width:    union {
		SizeValue,
		f16,
	},
	height:   union {
		SizeValue,
		f16,
	},
	aspect:   string,
}

NodeVbox :: struct {
	overflow:   string,
	layout:     Anchor,
	aspect:     string,
	width:      union {
		SizeValue,
		f16,
	},
	height:     union {
		SizeValue,
		f16,
	},
	draggable:  Maybe(Draggable_Attrs),
	dropable:   Maybe(Dropable_Attrs),
	drag_over:  Maybe(Drag_Over_Attrs),
}

NodeHbox :: struct {
	overflow:   string,
	layout:     Anchor,
	aspect:     string,
	width:      union {
		SizeValue,
		f32,
	},
	height:     union {
		SizeValue,
		f32,
	},
	draggable:  Maybe(Draggable_Attrs),
	dropable:   Maybe(Dropable_Attrs),
	drag_over:  Maybe(Drag_Over_Attrs),
}

NodeInput :: struct {
	change:      string,
	key:         string,
	aspect:      string,
	width:       union {
		SizeValue,
		f32,
	},
	height:      union {
		SizeValue,
		f32,
	},
	value:       string,
	placeholder: string,
	overflow:    string,
}

NodeButton :: struct {
	click:     string,
	click_ctx: i32, // Lua registry ref for click context (0 = none)
	width:     union {
		SizeValue,
		f32,
	},
	height:    union {
		SizeValue,
		f32,
	},
	label:     string,
	aspect:    string,
}

NodeText :: struct {
	layout:         Anchor,
	content:        string,
	aspect:         string,
	width:          union {
		SizeValue,
		f32,
	},
	height:         union {
		SizeValue,
		f32,
	},
	overflow:       string,
	not_selectable: bool,   // zero-value = selectable (default-on)
}

PopoutMode :: enum {
	MOUSE,
	FIXED,
}

NodePopout :: struct {
	aspect: string,
	x, y:   f32,
	width:  union {
		SizeValue,
		f32,
	},
	height: union {
		SizeValue,
		f32,
	},
	mode:   PopoutMode,
}

ImageHandlingType :: enum {
	stretch,
	stretchX,
	stretchY,
	keep, // default
}

NodeImage :: struct {
	aspect: string,
	width:  union {
		SizeValue,
		f32,
	},
	height: union {
		SizeValue,
		f32,
	},
}

NodeModal :: struct {
	aspect: string,
}

Node :: union {
	NodeStack,
	NodeCanvas,
	NodeVbox,
	NodeHbox,
	NodeInput,
	NodeButton,
	NodeText,
	NodeImage,
	NodePopout,
	NodeModal,
}
