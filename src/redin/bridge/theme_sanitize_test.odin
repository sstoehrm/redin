package bridge

import "core:math"
import "core:sync"
import "core:testing"

// #225 M1: `PUT /aspects` stores the theme verbatim and never runs the
// Fennel validator, so non-finite / absurdly large numerics reach the
// host reader. Unclamped, font_size * line_height, total-height, and
// shadow blur overflow to +Inf/NaN and flow into Raylib rectangle,
// scissor, and DrawRectangleRounded math — a session-DoS on the render
// loop. lua_to_theme must clamp every numeric to a finite, sane range.

@(test)
test_clamp_theme_finite_and_bounded :: proc(t: ^testing.T) {
	inf := math.inf_f32(1)
	nan := math.nan_f32()
	testing.expect_value(t, clamp_theme(5, 0, 16), 5)      // in range, untouched
	testing.expect_value(t, clamp_theme(inf, 0, 16), 16)   // +Inf saturates to hi
	testing.expect_value(t, clamp_theme(-inf, 0, 16), 0)   // -Inf saturates to lo
	testing.expect_value(t, clamp_theme(1e30, 0, 1024), 1024)
	testing.expect_value(t, clamp_theme(-5, 0, 255), 0)    // negative -> lo
	testing.expect_value(t, clamp_theme(-inf, -4096, 4096), -4096) // signed range
	// NaN must not slip through — a bare clamp would return NaN.
	got := clamp_theme(nan, 0, 16)
	testing.expect(t, got == got, "NaN must be mapped to a finite value")
	testing.expect_value(t, got, 0)
}

@(test)
test_lua_to_theme_clamps_hostile_numerics :: proc(t: ^testing.T) {
	sync.lock(&g_test_bridge_global_mutex)
	defer sync.unlock(&g_test_bridge_global_mutex)

	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	// A theme like the PUT /aspects repro in #225: huge line-height and an
	// infinite shadow blur, plus a NaN font-size.
	code: cstring = `return {
		text = {["line-height"] = 1e30, ["font-size"] = 0/0},
		button = {shadow = {0, 0, math.huge, {0, 0, 0, 128}}},
	}`
	rc := luaL_dostring(L, code)
	testing.expectf(t, rc == 0, "failed to build theme table (rc=%d)", rc)

	theme := lua_to_theme(L, lua_gettop(L))
	defer {
		// Themes own heap key + font strings (see bridge destroy).
		for k, v in theme {
			delete(k)
			if len(v.font) > 0 do delete(v.font)
		}
		delete(theme)
	}

	txt := theme["text"]
	lh := f32(txt.line_height)
	testing.expect(t, lh == lh, "line-height must be finite (not NaN)")
	testing.expect(t, lh <= 16, "line-height must be clamped to <= 16")
	fs := f32(txt.font_size)
	testing.expect(t, fs == fs, "font-size must be finite (not NaN)")
	testing.expect(t, fs >= 0 && fs <= 1024, "font-size must be clamped into [0,1024]")

	btn := theme["button"]
	blur := btn.shadow.blur
	testing.expect(t, blur == blur, "shadow blur must be finite (not NaN)")
	testing.expect(t, blur <= 256, "shadow blur must be clamped to <= 256")
}

// #277 L3: color components skipped the clamp every other theme numeric
// gets — a bare u8() cast of NaN/±Inf/1e300 (reachable via PUT /aspects)
// is implementation-defined at the LLVM level. clamp_byte must saturate.
@(test)
test_lua_to_theme_clamps_hostile_colors :: proc(t: ^testing.T) {
	sync.lock(&g_test_bridge_global_mutex)
	defer sync.unlock(&g_test_bridge_global_mutex)

	L := luaL_newstate()
	luaL_openlibs(L)
	defer lua_close(L)

	code: cstring = `return {
		text = {color = {1e300, -5, 0/0}, weight = 1e300,
		        selection = {1e300, -5, 0/0, math.huge}},
		button = {shadow = {0, 0, 1, {math.huge, -math.huge, 0/0, 300}}},
	}`
	rc := luaL_dostring(L, code)
	testing.expectf(t, rc == 0, "failed to build theme table (rc=%d)", rc)

	theme := lua_to_theme(L, lua_gettop(L))
	defer {
		for k, v in theme {
			delete(k)
			if len(v.font) > 0 do delete(v.font)
		}
		delete(theme)
	}

	txt := theme["text"]
	testing.expect_value(t, txt.color[0], 255) // 1e300 saturates hi
	testing.expect_value(t, txt.color[1], 0)   // negative -> 0
	testing.expect_value(t, txt.color[2], 0)   // NaN -> 0
	testing.expect_value(t, txt.selection[0], 255)
	testing.expect_value(t, txt.selection[1], 0)
	testing.expect_value(t, txt.selection[2], 0)
	testing.expect_value(t, txt.selection[3], 255) // +Inf saturates hi
	testing.expect_value(t, txt.weight, 255)

	btn := theme["button"]
	testing.expect_value(t, btn.shadow.color[0], 255)
	testing.expect_value(t, btn.shadow.color[1], 0)
	testing.expect_value(t, btn.shadow.color[2], 0)
	testing.expect_value(t, btn.shadow.color[3], 255) // 300 saturates hi
}
