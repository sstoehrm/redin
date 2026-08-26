package bridge

// Regression tests for issue #78 finding L3: the canvas command parser
// trusted Lua-side values without bounds-checking. A buggy Fennel
// canvas provider that returned `{255, 256, -1}` for an RGB triple
// would silently truncate via `u8(...)` (256 wraps to 0, -1 to 255),
// painting the wrong colour without surfacing the mistake. Negative or
// NaN sizes propagated into Raylib draw calls and could crash the host.

import "core:math"
import "core:testing"

@(test)
test_clamp_byte_in_range :: proc(t: ^testing.T) {
	testing.expect_value(t, clamp_byte(0),   u8(0))
	testing.expect_value(t, clamp_byte(128), u8(128))
	testing.expect_value(t, clamp_byte(255), u8(255))
}

@(test)
test_clamp_byte_below_range :: proc(t: ^testing.T) {
	// Pre-fix: u8(-1) silently wrapped to 255. After: clamps to 0.
	testing.expect_value(t, clamp_byte(-1),    u8(0))
	testing.expect_value(t, clamp_byte(-1000), u8(0))
}

@(test)
test_clamp_byte_above_range :: proc(t: ^testing.T) {
	// Pre-fix: u8(256) wrapped to 0. After: clamps to 255.
	testing.expect_value(t, clamp_byte(256),  u8(255))
	testing.expect_value(t, clamp_byte(1000), u8(255))
}

@(test)
test_clamp_byte_handles_nan :: proc(t: ^testing.T) {
	// NaN must not produce a garbage colour byte.
	testing.expect_value(t, clamp_byte(math.nan_f64()), u8(0))
}

@(test)
test_sanitize_dim_accepts_normal :: proc(t: ^testing.T) {
	v, ok := sanitize_dim(0)
	testing.expect(t, ok)
	testing.expect_value(t, v, f32(0))

	v2, ok2 := sanitize_dim(100)
	testing.expect(t, ok2)
	testing.expect_value(t, v2, f32(100))

	// Up to the texture-side ceiling.
	v3, ok3 := sanitize_dim(16384)
	testing.expect(t, ok3)
	testing.expect_value(t, v3, f32(16384))
}

@(test)
test_sanitize_dim_rejects_negative :: proc(t: ^testing.T) {
	_, ok := sanitize_dim(-1)
	testing.expect(t, !ok, "negative dimension must be rejected")
}

@(test)
test_sanitize_dim_rejects_nan :: proc(t: ^testing.T) {
	_, ok := sanitize_dim(math.nan_f32())
	testing.expect(t, !ok, "NaN dimension must be rejected")
}

@(test)
test_sanitize_dim_rejects_infinity :: proc(t: ^testing.T) {
	_, ok := sanitize_dim(math.inf_f32(1))
	testing.expect(t, !ok, "+Inf dimension must be rejected")

	_, ok2 := sanitize_dim(math.inf_f32(-1))
	testing.expect(t, !ok2, "-Inf dimension must be rejected")
}

@(test)
test_sanitize_dim_rejects_oversize :: proc(t: ^testing.T) {
	_, ok := sanitize_dim(99999)
	testing.expect(t, !ok, "dimension above the texture-side ceiling must be rejected")
}

// --- sanitize_coord (issue #233 finding M5) ---
// Unlike a dimension, a canvas coordinate may be negative (content extends
// off-screen), but NaN/±Inf must never reach the draw calls.

@(test)
test_sanitize_coord_accepts_negative :: proc(t: ^testing.T) {
	v, ok := sanitize_coord(-250)
	testing.expect(t, ok, "negative coordinate is legal (off-screen content)")
	testing.expect_value(t, v, f32(-250))
}

@(test)
test_sanitize_coord_accepts_normal :: proc(t: ^testing.T) {
	v, ok := sanitize_coord(640)
	testing.expect(t, ok)
	testing.expect_value(t, v, f32(640))
}

@(test)
test_sanitize_coord_rejects_nan :: proc(t: ^testing.T) {
	_, ok := sanitize_coord(math.nan_f32())
	testing.expect(t, !ok, "NaN coordinate must be rejected")
}

@(test)
test_sanitize_coord_rejects_infinity :: proc(t: ^testing.T) {
	_, ok := sanitize_coord(math.inf_f32(1))
	testing.expect(t, !ok, "+Inf coordinate must be rejected")

	_, ok2 := sanitize_coord(math.inf_f32(-1))
	testing.expect(t, !ok2, "-Inf coordinate must be rejected")
}

@(test)
test_sanitize_coord_clamps_huge_finite :: proc(t: ^testing.T) {
	// A finite-but-astronomical value stays finite but is clamped so
	// downstream transform/scissor math can't blow up.
	v, ok := sanitize_coord(1e30)
	testing.expect(t, ok, "huge finite coordinate is clamped, not rejected")
	testing.expect_value(t, v, f32(COORD_MAX))

	v2, ok2 := sanitize_coord(-1e30)
	testing.expect(t, ok2)
	testing.expect_value(t, v2, f32(-COORD_MAX))
}

// --- pixels command validation (spec 2026-08-25-texture-foundation) ---
// data length must equal w*h*4 exactly; dims positive integers, each
// <= PIXELS_DIM_MAX, product <= PIXELS_MAX_PIXELS. Scale in (0, 64], else 1.

@(test)
test_validate_pixels_accepts_exact :: proc(t: ^testing.T) {
	iw, ih, ok := validate_pixels_cmd(2, 3, 2 * 3 * 4)
	testing.expect(t, ok)
	testing.expect_value(t, iw, i32(2))
	testing.expect_value(t, ih, i32(3))
}

@(test)
test_validate_pixels_rejects_length_mismatch :: proc(t: ^testing.T) {
	_, _, ok := validate_pixels_cmd(2, 3, 2 * 3 * 4 - 1)
	testing.expect(t, !ok, "short data must be rejected")
	_, _, ok2 := validate_pixels_cmd(2, 3, 2 * 3 * 4 + 1)
	testing.expect(t, !ok2, "long data must be rejected")
}

@(test)
test_validate_pixels_rejects_bad_dims :: proc(t: ^testing.T) {
	_, _, a := validate_pixels_cmd(0, 3, 0)
	testing.expect(t, !a, "zero width rejected")
	_, _, b := validate_pixels_cmd(-2, 3, 24)
	testing.expect(t, !b, "negative width rejected")
	_, _, c := validate_pixels_cmd(2.5, 3, 30)
	testing.expect(t, !c, "non-integer width rejected")
	_, _, d := validate_pixels_cmd(math.nan_f64(), 3, 12)
	testing.expect(t, !d, "NaN width rejected")
	_, _, e := validate_pixels_cmd(2049, 1, 2049 * 4)
	testing.expect(t, !e, "width above PIXELS_DIM_MAX rejected")
	_, _, f := validate_pixels_cmd(2048, 2048, 2048 * 2048 * 4)
	testing.expect(t, f, "2048x2048 exactly at product cap accepted")
}

@(test)
test_sanitize_pixels_scale :: proc(t: ^testing.T) {
	testing.expect_value(t, sanitize_pixels_scale(3), f32(3))
	testing.expect_value(t, sanitize_pixels_scale(0.5), f32(0.5))
	testing.expect_value(t, sanitize_pixels_scale(0), f32(1))
	testing.expect_value(t, sanitize_pixels_scale(-2), f32(1))
	testing.expect_value(t, sanitize_pixels_scale(65), f32(1))
	testing.expect_value(t, sanitize_pixels_scale(math.nan_f32()), f32(1))
}
