package types

Shadow :: struct {
	x:     f32,
	y:     f32,
	blur:  f32,
	color: [4]u8,
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
}

// Field-by-field "non-zero wins" overlay: every field of `src` that is set
// (non-zero / non-empty / non-Auto) replaces the one in `out`. This is the
// single merge rule for theme resolution — state variants over their base
// (`button` < `button#hover`) and composed aspects (`[:a :b]`: `a` < `b`).
// Note: `font` is copied by reference; callers that store the result in
// an owning map must clone it.
overlay_theme :: proc(out: ^Theme, src: Theme) {
	if src.bg != {}            do out.bg = src.bg
	if src.color != {}         do out.color = src.color
	if src.border != {}        do out.border = src.border
	if src.border_width > 0    do out.border_width = src.border_width
	if src.radius > 0          do out.radius = src.radius
	if src.padding != {}       do out.padding = src.padding
	if src.font_size > 0       do out.font_size = src.font_size
	if len(src.font) > 0       do out.font = src.font
	if src.weight > 0          do out.weight = src.weight
	if src.line_height > 0     do out.line_height = src.line_height
	if src.opacity > 0         do out.opacity = src.opacity
	if src.shadow != {}        do out.shadow = src.shadow
	if src.selection != {}     do out.selection = src.selection
	if src.text_align != .Auto do out.text_align = src.text_align
}
