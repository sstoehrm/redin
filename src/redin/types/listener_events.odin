package types

import rl "vendor:raylib"

HoverListener :: struct {
	node_idx: int,
}

FocusListener :: struct {
	node_idx: int,
}

ClickListener :: struct {
	node_idx: int,
}

KeyListener :: struct {
	node_idx: int,
	key:      rl.KeyboardKey,
}

ChangeListener :: struct {
	node_idx: int,
}

DragListener :: struct {
	node_idx:   int,    // hit-test surface (handle if present, else container)
	source_idx: int,    // the draggable container; equals node_idx for container-grabs
	tags:       []string, // borrowed from node; lives until next clear_frame
}

DropListener :: struct {
	node_idx: int,
	tags:     []string,
}

DragOverListener :: struct {
	node_idx: int,
	tags:     []string,
}

// Emitted for every NodeText whose :selectable attribute is not false.
// Consumed by the text-selection gesture module (input/text_select.odin,
// added in a follow-up commit).
Text_Select_Listener :: struct {
	node_idx: int,
}

Listener :: union {
	HoverListener,
	FocusListener,
	ClickListener,
	KeyListener,
	ChangeListener,
	DragListener,
	DropListener,
	DragOverListener,
	Text_Select_Listener,
}
