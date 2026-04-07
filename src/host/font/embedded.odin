package font

import rl "vendor:raylib"

inter_regular      := #load("Inter-Regular.ttf")
inter_bold         := #load("Inter-Bold.ttf")
fira_code_regular  := #load("FiraCode-Regular.ttf")
fira_code_bold     := #load("FiraCode-Bold.ttf")
noto_serif_regular := #load("NotoSerif-Regular.ttf")
noto_serif_bold    := #load("NotoSerif-Bold.ttf")

DEFAULT_FONT_SIZE :: 32

load_embedded :: proc() {
	register("sans", .Regular, rl.LoadFontFromMemory(".ttf", raw_data(inter_regular), i32(len(inter_regular)), DEFAULT_FONT_SIZE, nil, 0))
	register("sans", .Bold, rl.LoadFontFromMemory(".ttf", raw_data(inter_bold), i32(len(inter_bold)), DEFAULT_FONT_SIZE, nil, 0))
	register("mono", .Regular, rl.LoadFontFromMemory(".ttf", raw_data(fira_code_regular), i32(len(fira_code_regular)), DEFAULT_FONT_SIZE, nil, 0))
	register("mono", .Bold, rl.LoadFontFromMemory(".ttf", raw_data(fira_code_bold), i32(len(fira_code_bold)), DEFAULT_FONT_SIZE, nil, 0))
	register("serif", .Regular, rl.LoadFontFromMemory(".ttf", raw_data(noto_serif_regular), i32(len(noto_serif_regular)), DEFAULT_FONT_SIZE, nil, 0))
	register("serif", .Bold, rl.LoadFontFromMemory(".ttf", raw_data(noto_serif_bold), i32(len(noto_serif_bold)), DEFAULT_FONT_SIZE, nil, 0))
}
