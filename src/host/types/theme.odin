package types

FontWeight :: enum {
	NORMAL,
	BOLD,
	ITALIC,
}

Theme :: struct {
	bg:           [3]u8,
	color:        [3]u8,
	padding:      [4]u8,
	border:       [3]u8,
	border_width: u8,
	radius:       u8,
	weight:       FontWeight,
	font_size:    u8,
	opacity:      f32,
}
