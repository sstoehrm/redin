package types

Theme :: struct {
	bg:           [3]u8,
	color:        [3]u8,
	padding:      [4]u8,
	border:       [3]u8,
	border_width: u8,
	radius:       u8,
	weight:       u8,      // 0=normal, 1=bold, 2=italic
	font_size:    f16,
	font:         string,
	opacity:      f32,
}
