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

Listener :: union {
	HoverListener,
	FocusListener,
	ClickListener,
	KeyListener,
	ChangeListener,
}
