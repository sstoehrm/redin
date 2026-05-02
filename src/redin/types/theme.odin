package types

Shadow :: struct {
	x:     f32,
	y:     f32,
	blur:  f32,
	color: [4]u8,
}

// Per-style override on a Theme entry. Three independent absence-sentinels:
//   `set`        false → the sub-table itself was not provided.
//   `color`      (0,0,0) inside a present sub-table → :color field absent.
//   `bg`         (0,0,0,0) → :bg field absent (only :code consumes :bg).
// The renderer treats any absent field as "inherit from the host aspect."
Style_Override :: struct {
	color: [3]u8,
	bg:    [4]u8,
	set:   bool,
}

Text_Align :: enum u8 {
	Auto   = 0, // single-line → Center, multi-line → Top
	Top    = 1,
	Center = 2,
	Bottom = 3,
}

Theme :: struct {
	bg:           [3]u8,
	color:        [3]u8,
	padding:      [4]u8,
	border:       [3]u8,
	border_width: u8,
	radius:       u8,
	weight:       u8,      // 0=normal, 1=bold, 2=italic
	text_align:   Text_Align, // vertical alignment for NodeInput text
	font_size:    f16,
	line_height:  f32,     // ratio; 0 = default (font_size + 4)
	font:         string,
	opacity:      f32,
	shadow:       Shadow,
	selection:    [4]u8,   // RGBA; {0,0,0,0} = unset, use render default
	bold:         Style_Override,
	italic:       Style_Override,
	code:         Style_Override,
}
