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
	overflow:        string,
	layout:          Anchor,
	aspect:          string,
	width:           union {
		SizeValue,
		f16,
	},
	height:          union {
		SizeValue,
		f16,
	},
	draggable_group: string,
	draggable_event: string,
	draggable_ctx:   i32,
	dropable_group:  string,
	dropable_event:  string,
	dropable_ctx:    i32,
}

NodeHbox :: struct {
	overflow:        string,
	layout:          Anchor,
	aspect:          string,
	width:           union {
		SizeValue,
		f32,
	},
	height:          union {
		SizeValue,
		f32,
	},
	draggable_group: string,
	draggable_event: string,
	draggable_ctx:   i32,
	dropable_group:  string,
	dropable_event:  string,
	dropable_ctx:    i32,
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
