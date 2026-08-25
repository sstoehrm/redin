// src/redin/texture/texture.odin
//
// One texture-loading foundation (spec 2026-08-25-texture-foundation):
// a content-hash-keyed cache for ctx.pixels RGBA buffers and a
// path-keyed cache for file textures, both frame-stamp LRU'd. All
// rl.Texture2D lifecycle lives here; GPU calls sit behind swappable
// proc variables so the bookkeeping tests run headless.
package texture

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

MAX_AGE_FRAMES :: 120
MAX_BYTES :: 64 * 1024 * 1024

// Test-only cap override; 0 = use MAX_BYTES.
max_bytes_override: int

Entry :: struct {
	tex:       rl.Texture2D,
	bytes:     int,
	last_used: u64,
	failed:    bool, // negative entry (file cache only)
}

pixels_cache: map[u64]Entry
file_cache: map[string]Entry // key heap-owned; freed on eviction/clear
frame_counter: u64
total_bytes: int

// --- GPU seams -------------------------------------------------------------

upload_pixels_proc: proc(w, h: i32, data: rawptr) -> (rl.Texture2D, bool) = default_upload_pixels
load_file_proc: proc(path: cstring) -> (rl.Texture2D, bool) = default_load_file
unload_proc: proc(tex: rl.Texture2D) = default_unload

default_upload_pixels :: proc(w, h: i32, data: rawptr) -> (rl.Texture2D, bool) {
	img := rl.Image {
		data    = data,
		width   = w,
		height  = h,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	tex := rl.LoadTextureFromImage(img) // img.data is borrowed; no UnloadImage
	if tex.id == 0 do return {}, false
	rl.SetTextureFilter(tex, .POINT)
	return tex, true
}

default_load_file :: proc(path: cstring) -> (rl.Texture2D, bool) {
	tex := rl.LoadTexture(path)
	if tex.id == 0 do return {}, false
	rl.SetTextureFilter(tex, .POINT)
	return tex, true
}

default_unload :: proc(tex: rl.Texture2D) {
	rl.UnloadTexture(tex)
}

// --- Hashing ---------------------------------------------------------------

@(private = "file")
FNV_OFFSET: u64 : 0xcbf29ce484222325
@(private = "file")
FNV_PRIME: u64 : 0x100000001b3

// FNV-1a 64 over w, h (little-endian bytes), then the RGBA data.
hash_pixels :: proc(w, h: i32, data: []u8) -> u64 {
	hv := FNV_OFFSET
	dims := [2]i32{w, h}
	for d in dims {
		for i in 0 ..< u32(4) {
			hv = (hv ~ u64(u8(d >> (i * 8)))) * FNV_PRIME
		}
	}
	for b in data {
		hv = (hv ~ u64(b)) * FNV_PRIME
	}
	return hv
}

// --- Public API ------------------------------------------------------------

get_pixels :: proc(w, h: i32, data: []u8) -> (rl.Texture2D, bool) {
	key := hash_pixels(w, h, data)
	if e, ok := &pixels_cache[key]; ok {
		e.last_used = frame_counter
		return e.tex, true
	}
	tex, ok := upload_pixels_proc(w, h, raw_data(data))
	if !ok do return {}, false
	bytes := len(data)
	pixels_cache[key] = Entry{tex = tex, bytes = bytes, last_used = frame_counter}
	total_bytes += bytes
	enforce_byte_cap()
	return tex, true
}

get_file :: proc(path: string) -> (rl.Texture2D, bool) {
	if e, ok := &file_cache[path]; ok {
		e.last_used = frame_counter
		return e.tex, !e.failed
	}
	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)
	tex, ok := load_file_proc(cpath)
	owned := strings.clone(path)
	if !ok {
		fmt.eprintfln("redin: warn: image load failed: %s", path)
		file_cache[owned] = Entry{failed = true, last_used = frame_counter}
		return {}, false
	}
	bytes := int(tex.width) * int(tex.height) * 4
	file_cache[owned] = Entry{tex = tex, bytes = bytes, last_used = frame_counter}
	total_bytes += bytes
	enforce_byte_cap()
	return tex, true
}

clear_files :: proc() {
	for key, e in file_cache {
		if !e.failed do unload_proc(e.tex)
		total_bytes -= e.bytes
		delete(key)
	}
	clear(&file_cache)
}

end_frame :: proc() {
	frame_counter += 1
	sweep()
}

destroy :: proc() {
	for _, e in pixels_cache {
		unload_proc(e.tex)
	}
	clear(&pixels_cache)
	clear_files()
	total_bytes = 0
	frame_counter = 0
}

// --- Eviction --------------------------------------------------------------

// sweep unloads any entry unused for more than MAX_AGE_FRAMES frames.
// Inlined as two plain loops (one per cache) rather than a polymorphic
// helper -- keeps ownership (file_cache keys are heap-owned, pixels_cache
// keys are plain u64) explicit at each call site.
@(private = "file")
sweep :: proc() {
	if frame_counter <= MAX_AGE_FRAMES do return
	cutoff := frame_counter - MAX_AGE_FRAMES

	pixels_evict: [dynamic]u64
	defer delete(pixels_evict)
	for key, e in pixels_cache {
		if e.last_used < cutoff do append(&pixels_evict, key)
	}
	for key in pixels_evict {
		e := pixels_cache[key]
		unload_proc(e.tex)
		total_bytes -= e.bytes
		delete_key(&pixels_cache, key)
	}

	file_evict: [dynamic]string
	defer delete(file_evict)
	for key, e in file_cache {
		if e.last_used < cutoff do append(&file_evict, key)
	}
	for key in file_evict {
		e := file_cache[key]
		if !e.failed do unload_proc(e.tex)
		total_bytes -= e.bytes
		delete_key(&file_cache, key)
		delete(key)
	}
}

@(private = "file")
enforce_byte_cap :: proc() {
	limit := MAX_BYTES if max_bytes_override == 0 else max_bytes_override
	for total_bytes > limit {
		// Find the globally least-recently-used entry across both caches.
		oldest_frame := max(u64)
		oldest_pixels_key: u64
		oldest_file_key: string
		in_pixels := false
		found := false
		for key, e in pixels_cache {
			if e.last_used < oldest_frame {
				oldest_frame = e.last_used
				oldest_pixels_key = key
				in_pixels = true
				found = true
			}
		}
		for key, e in file_cache {
			if e.bytes == 0 do continue // negative entries hold no bytes
			if e.last_used < oldest_frame {
				oldest_frame = e.last_used
				oldest_file_key = key
				in_pixels = false
				found = true
			}
		}
		if !found do return
		if in_pixels {
			e := pixels_cache[oldest_pixels_key]
			unload_proc(e.tex)
			total_bytes -= e.bytes
			delete_key(&pixels_cache, oldest_pixels_key)
		} else {
			e := file_cache[oldest_file_key]
			if !e.failed do unload_proc(e.tex)
			total_bytes -= e.bytes
			delete_key(&file_cache, oldest_file_key)
			delete(oldest_file_key)
		}
	}
}
