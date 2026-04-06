package types

ApplyFocus :: struct {
	idx: int,
}

ApplyActive :: struct {
	idx: int,
}

ApplyEvents :: union {
	ApplyFocus,
	ApplyActive,
}
