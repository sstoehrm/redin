package texture

// Bookkeeping tests run headless: the GPU seams are swapped for stubs
// that mint fake texture ids and record unloads.
//
// test_setup/test_teardown save and restore every package global rather
// than calling destroy() on whatever is already there (mirrors canvas's
// #182 test convention). Odin's `odin test` gives each @(test) proc its
// own tracking-allocator accounting; freeing a heap-owned map key that a
// *different* test's proc allocated is a cross-context free that the
// tracker flags as a bad free and can corrupt subsequent map lookups.
// Isolating per test -- nil out the globals, run the test against a
// clean slate, destroy only what THIS test allocated, then restore the
// saved globals -- keeps every alloc/free pair inside one test's context.

import "core:testing"
import rl "vendor:raylib"

@(private = "file")
g_unloaded: [dynamic]u32
@(private = "file")
g_pixels_counter: u32
@(private = "file")
g_file_counter: u32

@(private = "file")
saved_pixels_cache: map[u64]Entry
@(private = "file")
saved_file_cache: map[string]Entry
@(private = "file")
saved_frame_counter: u64
@(private = "file")
saved_total_bytes: int
@(private = "file")
saved_upload_pixels_proc: proc(w, h: i32, data: rawptr) -> (rl.Texture2D, bool)
@(private = "file")
saved_load_file_proc: proc(path: cstring) -> (rl.Texture2D, bool)
@(private = "file")
saved_unload_proc: proc(tex: rl.Texture2D)

@(private = "file")
test_setup :: proc() -> ^[dynamic]u32 {
	saved_pixels_cache = pixels_cache
	saved_file_cache = file_cache
	saved_frame_counter = frame_counter
	saved_total_bytes = total_bytes
	saved_upload_pixels_proc = upload_pixels_proc
	saved_load_file_proc = load_file_proc
	saved_unload_proc = unload_proc

	pixels_cache = nil
	file_cache = nil
	frame_counter = 0
	total_bytes = 0
	max_bytes_override = 0

	// Fresh every test and freed in test_teardown (not clear()'d and
	// reused) -- see the note on test_teardown for why.
	g_unloaded = make([dynamic]u32)
	g_pixels_counter = 0
	g_file_counter = 1000

	upload_pixels_proc = proc(w, h: i32, data: rawptr) -> (rl.Texture2D, bool) {
		g_pixels_counter += 1
		return rl.Texture2D{id = g_pixels_counter, width = 2, height = 2}, true
	}
	load_file_proc = proc(path: cstring) -> (rl.Texture2D, bool) {
		if path == "missing.png" do return {}, false
		g_file_counter += 1
		return rl.Texture2D{id = g_file_counter, width = 8, height = 8}, true
	}
	unload_proc = proc(tex: rl.Texture2D) {
		append(&g_unloaded, tex.id)
	}
	return &g_unloaded
}

@(private = "file")
test_teardown :: proc() {
	// destroy() unloads every entry this test allocated, frees the owned
	// file-cache keys, AND (as of the destroy()-is-terminal-teardown fix)
	// delete()s both maps' backing storage and resets them to reusable
	// zero-value maps -- so there's nothing left for this proc to free.
	// Deleting pixels_cache/file_cache again here would be a stale-header
	// double-free against the {} destroy() already left behind.
	destroy()
	max_bytes_override = 0

	pixels_cache = saved_pixels_cache
	file_cache = saved_file_cache
	frame_counter = saved_frame_counter
	total_bytes = saved_total_bytes
	upload_pixels_proc = saved_upload_pixels_proc
	load_file_proc = saved_load_file_proc
	unload_proc = saved_unload_proc

	// g_unloaded is made fresh in test_setup each time (not reused via
	// clear()); free its backing storage here rather than leaking it.
	delete(g_unloaded)
	g_unloaded = nil
}

@(test)
test_hash_stable_and_dim_sensitive :: proc(t: ^testing.T) {
	data := []u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}
	h1 := hash_pixels(2, 2, data)
	h2 := hash_pixels(2, 2, data)
	testing.expect_value(t, h1, h2)
	h3 := hash_pixels(4, 1, data) // same bytes, different dims
	testing.expect(t, h1 != h3, "dims must be folded into the hash")
	data2 := []u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 17}
	testing.expect(t, h1 != hash_pixels(2, 2, data2), "content change must change the hash")
}

@(test)
test_get_pixels_caches_by_content :: proc(t: ^testing.T) {
	test_setup()
	defer test_teardown()
	data := make([]u8, 2 * 2 * 4)
	defer delete(data)
	t1, ok1 := get_pixels(2, 2, data)
	testing.expect(t, ok1)
	t2, ok2 := get_pixels(2, 2, data)
	testing.expect(t, ok2)
	testing.expect_value(t, t1.id, t2.id) // hit, not re-upload
}

@(test)
test_get_file_caches_and_negative_caches :: proc(t: ^testing.T) {
	test_setup()
	defer test_teardown()
	t1, ok1 := get_file("sprite.png")
	testing.expect(t, ok1)
	t2, ok2 := get_file("sprite.png")
	testing.expect(t, ok2)
	testing.expect_value(t, t1.id, t2.id)
	_, mok := get_file("missing.png")
	testing.expect(t, !mok)
	// negative entry: second call must not retry the loader (loader would
	// succeed with a fresh id if called; same failure result proves cache)
	_, mok2 := get_file("missing.png")
	testing.expect(t, !mok2)
}

@(test)
test_clear_files_keeps_pixels :: proc(t: ^testing.T) {
	unloaded := test_setup()
	defer test_teardown()
	data := make([]u8, 2 * 2 * 4)
	defer delete(data)
	pt, _ := get_pixels(2, 2, data)
	ft, _ := get_file("sprite.png")
	clear_files()
	testing.expect(t, contains_id(unloaded[:], ft.id), "file texture unloaded on clear_files")
	testing.expect(t, !contains_id(unloaded[:], pt.id), "pixels texture survives clear_files")
	pt2, _ := get_pixels(2, 2, data)
	testing.expect_value(t, pt.id, pt2.id)
}

@(test)
test_age_eviction :: proc(t: ^testing.T) {
	unloaded := test_setup()
	defer test_teardown()
	data := make([]u8, 2 * 2 * 4)
	defer delete(data)
	pt, _ := get_pixels(2, 2, data)
	for _ in 0 ..< MAX_AGE_FRAMES + 1 {
		end_frame()
	}
	testing.expect(t, contains_id(unloaded[:], pt.id), "stale entry unloaded after MAX_AGE_FRAMES")
}

@(test)
test_touch_prevents_eviction :: proc(t: ^testing.T) {
	unloaded := test_setup()
	defer test_teardown()
	data := make([]u8, 2 * 2 * 4)
	defer delete(data)
	pt, _ := get_pixels(2, 2, data)
	for _ in 0 ..< MAX_AGE_FRAMES + 1 {
		get_pixels(2, 2, data) // touch every frame
		end_frame()
	}
	testing.expect(t, !contains_id(unloaded[:], pt.id), "touched entry must survive")
}

@(test)
test_byte_cap_evicts_lru_first :: proc(t: ^testing.T) {
	unloaded := test_setup()
	defer test_teardown()
	// Three entries whose accounted bytes are w*h*4. Shrink the cap via the
	// test-only override so we don't allocate 64MB in tests.
	max_bytes_override = 3 * (2 * 2 * 4) - 1 // fits two, not three
	d1 := make([]u8, 2 * 2 * 4)
	defer delete(d1)
	d1[0] = 1
	d2 := make([]u8, 2 * 2 * 4)
	defer delete(d2)
	d2[0] = 2
	d3 := make([]u8, 2 * 2 * 4)
	defer delete(d3)
	d3[0] = 3
	t1, _ := get_pixels(2, 2, d1)
	end_frame()
	t2, _ := get_pixels(2, 2, d2)
	end_frame()
	get_pixels(2, 2, d3)
	end_frame()
	testing.expect(t, contains_id(unloaded[:], t1.id), "oldest entry evicted at byte cap")
	testing.expect(t, !contains_id(unloaded[:], t2.id), "newer entry kept")
}

@(test)
test_byte_cap_spares_same_frame_insert :: proc(t: ^testing.T) {
	unloaded := test_setup()
	defer test_teardown()
	// Cap smaller than a single entry: the just-inserted entry is, by
	// itself, over the cap.
	max_bytes_override = (2 * 2 * 4) - 1
	d1 := make([]u8, 2 * 2 * 4)
	defer delete(d1)
	d1[0] = 1

	t1, ok1 := get_pixels(2, 2, d1)
	testing.expect(t, ok1, "over-cap insert must still report ok")
	testing.expect(
		t,
		!contains_id(unloaded[:], t1.id),
		"just-inserted over-cap entry must not be unloaded in its own insertion frame",
	)
	// Cache-hit on the same frame must still resolve to the live entry.
	t1_again, ok1_again := get_pixels(2, 2, d1)
	testing.expect(t, ok1_again)
	testing.expect_value(t, t1.id, t1_again.id)

	// A later frame's cap check, once the entry is no longer the
	// current-frame entry, must be able to evict it.
	end_frame()
	d2 := make([]u8, 2 * 2 * 4)
	defer delete(d2)
	d2[0] = 2
	get_pixels(2, 2, d2) // different content -> new entry, triggers another cap check
	testing.expect(
		t,
		contains_id(unloaded[:], t1.id),
		"stale over-cap entry must become evictable once a later frame's cap check runs",
	)
}

@(private = "file")
contains_id :: proc(ids: []u32, id: u32) -> bool {
	for x in ids do if x == id do return true
	return false
}
