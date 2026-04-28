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
	node_idx: int,
	tags:     []string, // borrowed from node; lives until next clear_frame
}

DropListener :: struct {
	node_idx: int,
	group:    string,   // v1 — deleted in task 17
	tags:     []string, // v2 — borrowed from node, freed by clear_node_strings
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
