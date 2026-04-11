package types

LayoutX :: enum {
	CENTER,
	LEFT, // default
	RIGHT,
}

LayoutY :: enum {
	CENTER, // default
	TOP,
	BOTTOM,
}

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

ViewportRect :: [4]ViewportValue

MAX_VIEWPORT_RECTS :: 16

Path :: struct {
	value:  []u8,
	length: u8,
}

Children :: struct {
	value:  []i32,
	length: i32,
}

NodeStack :: struct {
	viewport:       [MAX_VIEWPORT_RECTS]ViewportRect,
	viewport_count: u8,
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
	overflow: string,
	layoutX:  LayoutX,
	layoutY:  LayoutY,
	aspect:   string,
	width:    union {
		SizeValue,
		f16,
	},
	height:   union {
		SizeValue,
		f16,
	},
}

NodeHbox :: struct {
	overflow: string,
	layoutX:  LayoutX,
	layoutY:  LayoutY,
	aspect:   string,
	width:    union {
		SizeValue,
		f32,
	},
	height:   union {
		SizeValue,
		f32,
	},
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
	layoutX: LayoutX,
	layoutY: LayoutY,
	content: string,
	aspect:  string,
	width:   union {
		SizeValue,
		f32,
	},
	height:  union {
		SizeValue,
		f32,
	},
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
