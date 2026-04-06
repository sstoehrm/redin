package types

UserEventTypes :: enum {
	CLICK,
	KEY,
	HOVER,
	FOCUS,
	CHANGE,
}

UserEvent :: struct {
	event:    UserEventTypes,
	node_idx: int,
}
