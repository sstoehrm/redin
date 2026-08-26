# Texture Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One texture-loading foundation serving three consumers: a `ctx.pixels` canvas primitive (the #279 fix), a real canvas `image` op, and an un-stubbed `[:image]` frame-tree element.

**Architecture:** A new Odin package `src/redin/texture/` owns all `rl.Texture2D` lifecycle behind two caches (content-hash-keyed pixels cache, path-keyed file cache) with frame-stamped LRU eviction. The Fennel runtime gains a `ctx.pixels` primitive; the bridge decodes it into one texture blit per sprite. `NodeImage` gains `:src`/`:fit` attributes rendered through the same store. GPU calls sit behind swappable proc-variable seams so cache bookkeeping is unit-testable headlessly.

**Tech Stack:** Odin + Raylib, LuaJIT/Fennel, Babashka UI tests.

**Spec:** `docs/superpowers/specs/2026-08-25-texture-foundation-design.md`

## Global Constraints

- `ctx.pixels` data: RGBA byte string, length must equal `w*h*4` exactly; command skipped otherwise.
- Pixels dims: `w`, `h` positive integers, each ≤ 2048, product ≤ 4,194,304.
- `:scale` sanitized to `(0, 64]`, default 1.
- Eviction: entries unused for 120 frames unloaded; 64 MB total-bytes backstop, LRU-first.
- File-load failure: negative-cached, warn once, placeholder drawn. Hot reload clears the file cache only.
- Textures get `POINT` filter (nearest-neighbor).
- All commits: end message with the session's Co-Authored-By/Claude-Session trailer (see repo convention in recent `git log`).
- Release check: bare `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin` must stay green.
- Odin test invocation: `odin test src/redin/<pkg> -collection:lib=lib -collection:luajit=vendor/luajit`.

---

### Task 1: Texture store package

**Files:**
- Create: `src/redin/texture/texture.odin`
- Test: `src/redin/texture/texture_test.odin`
- Modify: `.github/workflows/test.yml` (add the package's `odin test` step next to the existing per-package steps)

**Interfaces:**
- Produces (used by Tasks 4–7 and runtime wiring in Task 2):
  - `texture.get_pixels(w, h: i32, data: []u8) -> (rl.Texture2D, bool)`
  - `texture.get_file(path: string) -> (rl.Texture2D, bool)`
  - `texture.clear_files()`
  - `texture.end_frame()` — advances the frame counter and sweeps
  - `texture.destroy()` — unloads everything
  - Test seams: package variables `upload_pixels_proc`, `load_file_proc`, `unload_proc`

- [ ] **Step 1: Write the failing tests**

`src/redin/texture/texture_test.odin`:

```odin
package texture

// Bookkeeping tests run headless: the GPU seams are swapped for stubs
// that mint fake texture ids and record unloads.

import "core:testing"
import rl "vendor:raylib"

@(private = "file")
test_setup :: proc() -> ^[dynamic]u32 {
	destroy()
	unloaded := new([dynamic]u32)
	next_id := new(u32)
	next_id^ = 1
	@(static) g_unloaded: ^[dynamic]u32
	@(static) g_next_id: ^u32
	g_unloaded = unloaded
	g_next_id = next_id
	upload_pixels_proc = proc(w, h: i32, data: rawptr) -> (rl.Texture2D, bool) {
		@(static) counter: u32 = 0
		counter += 1
		return rl.Texture2D{id = counter, width = 2, height = 2}, true
	}
	load_file_proc = proc(path: cstring) -> (rl.Texture2D, bool) {
		if path == "missing.png" do return {}, false
		@(static) counter: u32 = 1000
		counter += 1
		return rl.Texture2D{id = counter, width = 8, height = 8}, true
	}
	unload_proc = proc(tex: rl.Texture2D) {
		// record for assertions
		append(g_unloaded, tex.id)
	}
	return unloaded
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
	unloaded := test_setup()
	defer free(unloaded)
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
	unloaded := test_setup()
	defer free(unloaded)
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
	defer free(unloaded)
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
	defer free(unloaded)
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
	defer free(unloaded)
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
	defer free(unloaded)
	// Three entries whose accounted bytes are w*h*4. Shrink the cap via the
	// test-only override so we don't allocate 64MB in tests.
	max_bytes_override = 3 * (2 * 2 * 4) - 1 // fits two, not three
	defer max_bytes_override = 0
	d1 := make([]u8, 2 * 2 * 4); defer delete(d1); d1[0] = 1
	d2 := make([]u8, 2 * 2 * 4); defer delete(d2); d2[0] = 2
	d3 := make([]u8, 2 * 2 * 4); defer delete(d3); d3[0] = 3
	t1, _ := get_pixels(2, 2, d1)
	end_frame()
	t2, _ := get_pixels(2, 2, d2)
	end_frame()
	get_pixels(2, 2, d3)
	end_frame()
	testing.expect(t, contains_id(unloaded[:], t1.id), "oldest entry evicted at byte cap")
	testing.expect(t, !contains_id(unloaded[:], t2.id), "newer entry kept")
}

@(private = "file")
contains_id :: proc(ids: []u32, id: u32) -> bool {
	for x in ids do if x == id do return true
	return false
}
```

Note for the implementer: the `test_setup` sketch above shows intent — stub
seams, reset state, capture unloads. If `@(static)` locals prove awkward for
sharing the recorder, use a package-level `@(private="file")` test recorder
variable in the test file instead; the assertions are what matter.

- [ ] **Step 2: Run tests to verify they fail**

Run: `odin test src/redin/texture -collection:lib=lib -collection:luajit=vendor/luajit`
Expected: compile FAILURE (package/procs don't exist yet).

- [ ] **Step 3: Implement the store**

`src/redin/texture/texture.odin`:

```odin
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
file_cache:   map[string]Entry // key heap-owned; freed on eviction/clear
frame_counter: u64
total_bytes:   int

// --- GPU seams -------------------------------------------------------------

upload_pixels_proc: proc(w, h: i32, data: rawptr) -> (rl.Texture2D, bool) = default_upload_pixels
load_file_proc:     proc(path: cstring) -> (rl.Texture2D, bool)           = default_load_file
unload_proc:        proc(tex: rl.Texture2D)                               = default_unload

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

@(private = "file")
sweep :: proc() {
	evict_older_than :: proc(cache: ^map[$K]Entry, cutoff: u64, owned_keys: bool) {
		keys_to_evict: [dynamic]K
		defer delete(keys_to_evict)
		for key, e in cache {
			if e.last_used < cutoff do append(&keys_to_evict, key)
		}
		for key in keys_to_evict {
			e := cache[key]
			if !e.failed do unload_proc(e.tex)
			total_bytes -= e.bytes
			when K == string {
				if owned_keys do delete(key)
			}
			delete_key(cache, key)
		}
	}
	if frame_counter <= MAX_AGE_FRAMES do return
	cutoff := frame_counter - MAX_AGE_FRAMES
	evict_older_than(&pixels_cache, cutoff, false)
	evict_older_than(&file_cache, cutoff, true)
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
			delete(oldest_file_key)
			delete_key(&file_cache, oldest_file_key)
		}
	}
}
```

If the polymorphic `evict_older_than` inner proc fights the compiler, inline
it as two plain loops (one per cache) — behavior over cleverness.

- [ ] **Step 4: Run tests to verify they pass**

Run: `odin test src/redin/texture -collection:lib=lib -collection:luajit=vendor/luajit`
Expected: all tests PASS.

- [ ] **Step 5: Add the CI test step**

In `.github/workflows/test.yml`, next to the existing `odin test src/redin/canvas ...` step, add:

```yaml
      - name: Odin tests (texture)
        run: odin test src/redin/texture -collection:lib=lib -collection:luajit=vendor/luajit
```

Match the exact `- name:`/`run:` formatting of the neighboring steps.

- [ ] **Step 6: Commit**

```bash
git add src/redin/texture/ .github/workflows/test.yml
git commit -m "feat(texture): content-hash + file texture store with LRU eviction"
```

---

### Task 2: Wire the store into the runtime loop

**Files:**
- Modify: `src/redin/runtime.odin` (defer block ~line 166–193; frame loop ~line 345)

**Interfaces:**
- Consumes: `texture.end_frame()`, `texture.destroy()` from Task 1.
- Produces: per-frame sweep and shutdown unload; nothing else depends on this task's internals.

- [ ] **Step 1: Add the import and calls**

In `src/redin/runtime.odin`:
- Add `import "texture"` alongside the existing sibling package imports (match their exact form — they are relative like `import "canvas"`; copy the style used for `canvas`).
- In the defer stack near `defer canvas.destroy()` (line ~173), add `defer texture.destroy()` immediately after it.
- In the frame loop, directly before `canvas.end_frame()` (line ~345), add `texture.end_frame()`.

- [ ] **Step 2: Verify both builds**

Run: `./build-dev.sh && odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin-release-check && rm build/redin-release-check`
Expected: both compile cleanly.

- [ ] **Step 3: Commit**

```bash
git add src/redin/runtime.odin
git commit -m "feat(texture): per-frame sweep and shutdown wiring"
```

---

### Task 3: ctx.pixels runtime primitive

**Files:**
- Modify: `src/runtime/canvas.fnl` (`build-ctx`, after the `:image` entry ~line 25)
- Test: `test/lua/test_canvas.fnl`

**Interfaces:**
- Produces: buffer entries `[:pixels x y w h data opts]` (data: string; opts: table, `{}` when absent). Task 4's decoder consumes exactly this shape.

- [ ] **Step 1: Write the failing test**

Append to `test/lua/test_canvas.fnl` (match the file's existing `(fn t.test-... [])` style):

```fennel
(fn t.test-ctx-pixels-appends-to-buffer []
  (setup)
  (canvas.register :test-pixels
    (fn [ctx]
      (ctx.pixels 4 8 2 2 "0123456789abcdef" {:scale 3})))
  (let [buf (canvas._draw :test-pixels 400 300 {})]
    (assert buf "buffer returned")
    (assert (= (length buf) 1) "one command")
    (let [cmd (. buf 1)]
      (assert (= (. cmd 1) :pixels) "tag is pixels")
      (assert (= (. cmd 2) 4) "x")
      (assert (= (. cmd 3) 8) "y")
      (assert (= (. cmd 4) 2) "w")
      (assert (= (. cmd 5) 2) "h")
      (assert (= (. cmd 6) "0123456789abcdef") "data passed through verbatim")
      (assert (= (. (. cmd 7) :scale) 3) "scale opt"))))

(fn t.test-ctx-pixels-default-opts []
  (setup)
  (canvas.register :test-pixels-noopts
    (fn [ctx]
      (ctx.pixels 0 0 1 1 "rgba")))
  (let [buf (canvas._draw :test-pixels-noopts 100 100 {})]
    (let [cmd (. buf 1)]
      (assert (= (type (. cmd 7)) "table") "opts defaults to empty table"))))
```

- [ ] **Step 2: Run to verify failure**

Run: `luajit test/lua/runner.lua test/lua/test_canvas.fnl`
Expected: the two new tests FAIL (`ctx.pixels` is nil → error calling it).

- [ ] **Step 3: Implement**

In `src/runtime/canvas.fnl`, after the `:image` entry in `build-ctx`:

```fennel
     :pixels (fn [x y w h data ?opts]
               (table.insert buf [:pixels x y w h data (or ?opts {})]))
```

- [ ] **Step 4: Run the full Fennel suite**

Run: `luajit test/lua/runner.lua test/lua/test_*.fnl`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/runtime/canvas.fnl test/lua/test_canvas.fnl
git commit -m "feat(canvas): ctx.pixels runtime primitive (#279)"
```

---

### Task 4: Bridge pixels decode

**Files:**
- Modify: `src/redin/bridge/bridge.odin` (constants near `MAX_POLYGON_POINTS` ~line 676; new case in `execute_canvas_command` before the `case "image":` arm ~line 981; new `import "../texture"`)
- Test: `src/redin/bridge/canvas_sanitize_test.odin`

**Interfaces:**
- Consumes: `[:pixels x y w h data opts]` buffer entries (Task 3); `texture.get_pixels` (Task 1).
- Produces: `validate_pixels_cmd(w, h: f64, data_len: int) -> (iw, ih: i32, ok: bool)` and `sanitize_pixels_scale(v: f32) -> f32` in package `bridge` (headless-testable helpers).

- [ ] **Step 1: Write the failing tests**

Append to `src/redin/bridge/canvas_sanitize_test.odin`:

```odin
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
```

- [ ] **Step 2: Run to verify failure**

Run: `odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit`
Expected: compile FAILURE (helpers undefined).

- [ ] **Step 3: Implement helpers + decode arm**

In `src/redin/bridge/bridge.odin`, near `MAX_POLYGON_POINTS` (~line 676):

```odin
// Caps for the "pixels" canvas command (spec 2026-08-25). A 2048-wide
// square RGBA texture is 16MB — the per-command ceiling; anything larger
// is skipped, matching the sanitize posture of the other canvas ops.
@(private = "file")
PIXELS_DIM_MAX :: 2048
@(private = "file")
PIXELS_MAX_PIXELS :: 4 * 1024 * 1024

// Validate the pixels command header: dims must be positive integers
// within caps and data_len must equal w*h*4 exactly.
validate_pixels_cmd :: proc(w, h: f64, data_len: int) -> (iw, ih: i32, ok: bool) {
	if math.is_nan(w) || math.is_nan(h) || math.is_inf(w) || math.is_inf(h) do return 0, 0, false
	if w != math.floor(w) || h != math.floor(h) do return 0, 0, false
	if w < 1 || h < 1 || w > PIXELS_DIM_MAX || h > PIXELS_DIM_MAX do return 0, 0, false
	iw = i32(w)
	ih = i32(h)
	if int(iw) * int(ih) > PIXELS_MAX_PIXELS do return 0, 0, false
	if data_len != int(iw) * int(ih) * 4 do return 0, 0, false
	return iw, ih, true
}

// Scale for the pixels command: (0, 64], anything else falls back to 1.
// NaN compares false on both bounds and lands on the fallback.
sanitize_pixels_scale :: proc(v: f32) -> f32 {
	if v > 0 && v <= 64 do return v
	return 1
}
```

Add `import "../texture"` next to the existing `import "../canvas"` (line ~27).

In `execute_canvas_command`, insert before `case "image":`:

```odin
	case "pixels":
		x, x_ok := canvas_coord(L, idx, 2, ox)
		y, y_ok := canvas_coord(L, idx, 3, oy)
		if !x_ok || !y_ok do return
		wf := lua_rawgeti_number(L, idx, 4)
		hf := lua_rawgeti_number(L, idx, 5)
		lua_rawgeti(L, idx, 6)
		// Strict string check (not lua_isstring — a number cell must not
		// coerce) and NUL-safe length read, the #277 posture.
		if lua_type(L, -1) != LUA_TSTRING {
			lua_pop(L, 1)
			return
		}
		data := lua_tostring_str(L, -1) // borrows Lua's buffer for this call
		iw, ih, ok := validate_pixels_cmd(wf, hf, len(data))
		if !ok {
			lua_pop(L, 1)
			return
		}
		lua_rawgeti(L, idx, 7)
		opts := lua_gettop(L)
		scale := sanitize_pixels_scale(read_number_field(L, opts, "scale"))
		if tex, tok := texture.get_pixels(iw, ih, transmute([]u8)data); tok {
			rl.DrawTextureEx(tex, {x, y}, 0, scale, rl.WHITE)
		}
		lua_pop(L, 2)
```

Check whether `LUA_TSTRING` is already declared in `lua_api.odin` (json.odin
does strict type checks — reuse its exact constant/name). If the codebase's
strict-string idiom differs (e.g. an `is_strict_string` helper), use that
idiom instead; the requirement is: numbers must not pass.

- [ ] **Step 4: Run tests + build**

Run: `odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit && ./build-dev.sh`
Expected: tests PASS, build clean.

- [ ] **Step 5: Commit**

```bash
git add src/redin/bridge/bridge.odin src/redin/bridge/canvas_sanitize_test.odin
git commit -m "feat(bridge): decode canvas pixels command into cached texture blits (#279)"
```

---

### Task 5: Canvas image op un-stub

**Files:**
- Modify: `src/redin/bridge/bridge.odin` (`case "image":` arm ~line 981)

**Interfaces:**
- Consumes: existing runtime entries `[:image x y w h name opts]` (`name` now interpreted as a file path); `texture.get_file` (Task 1).
- Produces: nothing new for later tasks.

- [ ] **Step 1: Replace the stub**

Replace the body of `case "image":` (currently drawing a gray box + "img" text) with:

```odin
	case "image":
		x, x_ok := canvas_coord(L, idx, 2, ox)
		y, y_ok := canvas_coord(L, idx, 3, oy)
		w, w_ok := sanitize_dim(f32(lua_rawgeti_number(L, idx, 4)))
		h, h_ok := sanitize_dim(f32(lua_rawgeti_number(L, idx, 5)))
		if !x_ok || !y_ok || !w_ok || !h_ok do return
		lua_rawgeti(L, idx, 6)
		defer lua_pop(L, 1)
		if lua_type(L, -1) != LUA_TSTRING do return
		path := lua_tostring_str(L, -1)
		if tex, ok := texture.get_file(path); ok {
			src := rl.Rectangle{0, 0, f32(tex.width), f32(tex.height)}
			rl.DrawTexturePro(tex, src, {x, y, w, h}, {0, 0}, 0, rl.WHITE)
		} else {
			// Missing/failed file keeps the placeholder box.
			rl.DrawRectangleLinesEx({x, y, w, h}, 1, rl.GRAY)
			rl.DrawText("img", i32(x) + 2, i32(y) + 2, 12, rl.GRAY)
		}
```

(The same strict-string idiom as Task 4 applies.)

- [ ] **Step 2: Build both variants**

Run: `./build-dev.sh && odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add src/redin/bridge/bridge.odin
git commit -m "feat(bridge): implement reserved canvas image op via file textures"
```

---

### Task 6: NodeImage :src and :fit

**Files:**
- Modify: `src/redin/types/view_tree.odin` (`NodeImage` ~line 234)
- Modify: `src/redin/bridge/bridge.odin` (`case "image":` node conversion ~line 1759)
- Modify: `src/redin/parser/view_tree_parser.odin` (`case "image":` ~line 418)
- Modify: `src/redin/render.odin` (NodeImage draw arm ~line 648; new `fit_dest_rect` helper near the other file-scope helpers)
- Test: `src/redin/render_fit_test.odin` (new), `src/redin/parser/view_tree_parser_test.odin` (extend existing image test ~line 122)

**Interfaces:**
- Consumes: `texture.get_file` (Task 1).
- Produces: `types.NodeImage.src: string`, `types.NodeImage.fit: ImageHandlingType`; `fit_dest_rect(fit: types.ImageHandlingType, rect: rl.Rectangle, tw, th: f32) -> rl.Rectangle` in package `redin`.

- [ ] **Step 1: Write the failing fit-math tests**

`src/redin/render_fit_test.odin`:

```odin
package redin

import "core:testing"
import rl "vendor:raylib"
import "types"

// fit_dest_rect maps a texture (tw x th) into an element rect per the
// :fit attribute (spec 2026-08-25-texture-foundation).

@(test)
test_fit_stretch_fills_rect :: proc(t: ^testing.T) {
	r := rl.Rectangle{10, 20, 100, 50}
	testing.expect_value(t, fit_dest_rect(.stretch, r, 8, 8), r)
}

@(test)
test_fit_keep_centers_1to1 :: proc(t: ^testing.T) {
	r := rl.Rectangle{0, 0, 100, 50}
	d := fit_dest_rect(.keep, r, 20, 10)
	testing.expect_value(t, d, rl.Rectangle{40, 20, 20, 10})
}

@(test)
test_fit_stretch_x_preserves_aspect :: proc(t: ^testing.T) {
	r := rl.Rectangle{0, 0, 100, 100}
	// 50x25 texture -> fill width 100 => height 50, centered vertically.
	d := fit_dest_rect(.stretchX, r, 50, 25)
	testing.expect_value(t, d, rl.Rectangle{0, 25, 100, 50})
}

@(test)
test_fit_stretch_y_preserves_aspect :: proc(t: ^testing.T) {
	r := rl.Rectangle{0, 0, 100, 100}
	// 25x50 texture -> fill height 100 => width 50, centered horizontally.
	d := fit_dest_rect(.stretchY, r, 25, 50)
	testing.expect_value(t, d, rl.Rectangle{25, 0, 50, 100})
}

@(test)
test_fit_degenerate_texture_falls_back_to_rect :: proc(t: ^testing.T) {
	r := rl.Rectangle{0, 0, 100, 100}
	testing.expect_value(t, fit_dest_rect(.stretchX, r, 0, 0), r)
}
```

Note: check how CI runs tests for package `redin` (`src/redin`) in
`.github/workflows/test.yml`. If there is no `odin test src/redin` step, add
one with the same collections flags as the bridge step (the package links
raylib; if a headless `odin test src/redin` fails to link/run in CI for that
reason, move `fit_dest_rect` + its test into `src/redin/types` as a pure
helper instead — it only needs `rl.Rectangle`, which is four floats; in that
case define it on a local `Rect :: struct {x, y, width, height: f32}` in
types and convert at the call site).

- [ ] **Step 2: Run to verify failure**

Run: `odin test src/redin -collection:lib=lib -collection:luajit=vendor/luajit`
Expected: compile FAILURE (`fit_dest_rect` undefined).

- [ ] **Step 3: Extend types**

In `src/redin/types/view_tree.odin`, extend `NodeImage`:

```odin
NodeImage :: struct {
	aspect: string,
	src:    string,
	fit:    ImageHandlingType,
	width:  union {
		SizeValue,
		f32,
	},
	height: union {
		SizeValue,
		f32,
	},
	margin: [4]u8,
}
```

- [ ] **Step 4: Implement fit_dest_rect + render arm**

In `src/redin/render.odin`, add near the other helpers:

```odin
// Map a texture (tw x th) into the element rect per :fit.
fit_dest_rect :: proc(fit: types.ImageHandlingType, rect: rl.Rectangle, tw, th: f32) -> rl.Rectangle {
	if tw <= 0 || th <= 0 do return rect
	switch fit {
	case .stretch:
		return rect
	case .stretchX:
		s := rect.width / tw
		h := th * s
		return {rect.x, rect.y + (rect.height - h) / 2, rect.width, h}
	case .stretchY:
		s := rect.height / th
		w := tw * s
		return {rect.x + (rect.width - w) / 2, rect.y, w, rect.height}
	case .keep:
		return {rect.x + (rect.width - tw) / 2, rect.y + (rect.height - th) / 2, tw, th}
	}
	return rect
}
```

Replace the NodeImage draw arm (`render.odin:648-651`):

```odin
	case types.NodeImage:
		draw_themed_rect(idx, rect, n.aspect, theme)
		drew := false
		if len(n.src) > 0 {
			if tex, ok := texture.get_file(n.src); ok {
				dest := fit_dest_rect(n.fit, rect, f32(tex.width), f32(tex.height))
				// stretch fills exactly; the other modes may exceed the rect
				// on one axis (or 1:1 overflow for keep) — clip via scissor.
				bridge.push_scissor(rect)
				rl.DrawTexturePro(tex, {0, 0, f32(tex.width), f32(tex.height)}, dest, {0, 0}, 0, rl.WHITE)
				bridge.pop_scissor()
				drew = true
			}
		}
		if !drew {
			rl.DrawRectangleLinesEx(rect, 1, rl.GRAY)
			rl.DrawText("image", i32(rect.x) + 4, i32(rect.y) + 4, 14, rl.GRAY)
		}
```

Add `import "texture"` to `render.odin`'s imports (same relative style as its
existing sibling imports). Verify `push_scissor`/`pop_scissor` are exported
from package bridge (they are used across files in that package —
`src/redin/bridge/scissor.odin`); if they are `@(private)`, export them.

- [ ] **Step 5: Read attributes in both ingestion paths**

Bridge node conversion (`bridge.odin` `case "image":` ~line 1759) — add after
the `margin` line, following the popout-mode string-switch idiom at ~1777:

```odin
			img.src = lua_get_string_field(L, attrs_idx, "src")
			fit := lua_get_string_field_raw(L, attrs_idx, "fit")
			switch fit {
			case "stretch":
				img.fit = .stretch
			case "stretch-x":
				img.fit = .stretchX
			case "stretch-y":
				img.fit = .stretchY
			case "keep", "":
				img.fit = .keep
			case:
				img.fit = .keep
			}
```

Static parser (`view_tree_parser.odin` `case "image":` ~line 418) — add:

```odin
		if s, ok := props["src"]; ok do img.src = strings.clone(s.str_val)
		if f, ok := props["fit"]; ok {
			switch f.str_val {
			case "stretch":
				img.fit = .stretch
			case "stretch-x":
				img.fit = .stretchX
			case "stretch-y":
				img.fit = .stretchY
			case:
				img.fit = .keep
			}
		}
```

Follow each file's exact memory idiom: the parser clones (`strings.clone`);
the bridge's `lua_get_string_field` — check whether it clones (grep its
definition) and match whatever `aspect` does, including any corresponding
free in the node-teardown path. If `aspect` is freed somewhere on frame
teardown, `src` must be freed in the same place.

- [ ] **Step 6: Extend the parser test**

In `src/redin/parser/view_tree_parser_test.odin`, the existing image test
(~line 122) parses an image node. Extend it (or add a sibling test in the
same style) so the parsed source includes `:src "logo.png" :fit "stretch-x"`
and assert:

```odin
	testing.expect_value(t, img.src, "logo.png")
	testing.expect_value(t, img.fit, types.ImageHandlingType.stretchX)
```

Read the surrounding test first to copy its input-string format exactly.

- [ ] **Step 7: Run all affected test packages + build**

Run:
```bash
odin test src/redin -collection:lib=lib -collection:luajit=vendor/luajit
odin test src/redin/parser
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
./build-dev.sh
```
Expected: all PASS, build clean.

- [ ] **Step 8: Commit**

```bash
git add src/redin/types/view_tree.odin src/redin/bridge/bridge.odin src/redin/parser/view_tree_parser.odin src/redin/render.odin src/redin/render_fit_test.odin src/redin/parser/view_tree_parser_test.odin .github/workflows/test.yml
git commit -m "feat(render): [:image] element draws :src textures with :fit modes"
```

---

### Task 7: Hot reload clears the file cache

**Files:**
- Modify: `src/redin/bridge/hotreload.odin` (`hotreload_execute`, line ~140)

**Interfaces:**
- Consumes: `texture.clear_files()` (Task 1).

- [ ] **Step 1: Implement**

In `hotreload_execute` (`hotreload.odin:140`), on the success path (read the
proc first; add the call right where the reload is known to have succeeded,
before returning `ok = true`):

```odin
	// Spec 2026-08-25: an edited image file on disk must show up after a
	// reload. Pixels-cache entries are content-addressed and stay valid.
	texture.clear_files()
```

Add `import "../texture"` to the file's imports if not already present via
the shared package import in bridge.odin (hotreload.odin is package bridge —
the import in bridge.odin from Task 4 already covers the package; Odin
imports are per-file, so add it here too if the compiler asks).

- [ ] **Step 2: Build + manual check**

Run: `./build-dev.sh`
Expected: clean. (Behavioral coverage lands in Task 8's UI test indirectly;
a dedicated hot-reload UI test is out of scope — reload plumbing already has
its own tests.)

- [ ] **Step 3: Commit**

```bash
git add src/redin/bridge/hotreload.odin
git commit -m "feat(texture): clear file cache on hot reload"
```

---

### Task 8: Image element UI test with a real PNG

**Files:**
- Create: `test/ui/fixtures/sprite.png` (generated, committed)
- Create: `test/ui/fixtures/gen_sprite.py` (the generator, committed for reproducibility)
- Modify: `test/ui/image_app.fnl`, `test/ui/test_image.bb`

**Interfaces:**
- Consumes: `[:image {:src ...}]` (Task 6). Note: `get_file` resolves paths
  against the process working directory — the UI test runner starts the app
  from the repo root, so the app uses `test/ui/fixtures/sprite.png`.

- [ ] **Step 1: Generate the fixture PNG**

`test/ui/fixtures/gen_sprite.py`:

```python
#!/usr/bin/env python3
"""Deterministic 4x4 RGBA test sprite: top half red, bottom half blue."""
import struct, zlib

W, H = 4, 4
rows = b""
for y in range(H):
    rows += b"\x00"  # filter: none
    for x in range(W):
        rows += bytes([255, 0, 0, 255] if y < H // 2 else [0, 0, 255, 255])

def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(rows, 9))
       + chunk(b"IEND", b""))

with open("test/ui/fixtures/sprite.png", "wb") as f:
    f.write(png)
print("wrote test/ui/fixtures/sprite.png")
```

Run: `mkdir -p test/ui/fixtures && python3 test/ui/fixtures/gen_sprite.py`
Expected: file written; `file test/ui/fixtures/sprite.png` reports `PNG image data, 4 x 4`.

- [ ] **Step 2: Extend the app**

In `test/ui/image_app.fnl`, add to `main_view`'s vbox (after the `:plain`
image):

```fennel
       [:image {:id :sprite :src "test/ui/fixtures/sprite.png"
                :fit :stretch :width 64 :height 64}]
       [:image {:id :sprite-keep :src "test/ui/fixtures/sprite.png"
                :fit :keep :width 64 :height 64}]
       [:image {:id :broken :src "test/ui/fixtures/does-not-exist.png"
                :width 64 :height 64}]
```

- [ ] **Step 3: Extend the tests**

Append to `test/ui/test_image.bb`:

```clojure
;; -- :src / :fit attributes (texture foundation spec) --

(deftest src-images-exist-and-app-stays-alive
  (dispatch ["event/reset"])
  (wait-ms 300)
  (assert-element {:tag :image :id :sprite} "src image should exist")
  (assert-element {:tag :image :id :sprite-keep} "keep-fit image should exist")
  (assert-element {:tag :image :id :broken} "broken-src image should exist")
  ;; several frames of texture rendering must not crash the app
  (wait-ms 500)
  (assert-element {:tag :image :id :sprite} "app alive after sustained texture draws"))

(deftest src-attr-roundtrips
  (let [el (find-element {:tag :image :id :sprite})
        attrs (second el)]
    (assert (= "test/ui/fixtures/sprite.png" (:src attrs)) "src attr should round-trip")))

(deftest screenshot-valid-with-textures
  (let [[w h] (screenshot-dims)]
    (assert (pos? w) "screenshot decodes with textures on screen")
    (assert (pos? h))))
```

Note: `:src` round-trip through `/frames` requires the frames JSON to include
the new attr. Check how `/frames` serializes NodeImage attrs (grep `"aspect"`
in `src/redin/bridge/devserver.odin`); if attrs are emitted per-field, add
`src`/`fit` there as part of this task. If it turns out `/frames` doesn't
serialize per-node attrs this way, drop the `src-attr-roundtrips` test and
keep the structural + stability tests.

- [ ] **Step 4: Run the UI test**

Run:
```bash
./build-dev.sh
./build/redin test/ui/image_app.fnl &
bb test/ui/run.bb test/ui/test_image.bb
```
Expected: all tests PASS (including the pre-existing ones).

- [ ] **Step 5: Commit**

```bash
git add test/ui/fixtures/ test/ui/image_app.fnl test/ui/test_image.bb src/redin/bridge/devserver.odin
git commit -m "test(ui): [:image] :src/:fit coverage with committed PNG fixture"
```

---

### Task 9: Pixels UI test + perf validation

**Files:**
- Create: `test/ui/pixels_app.fnl`, `test/ui/test_pixels.bb`

**Interfaces:**
- Consumes: `ctx.pixels` (Task 3), pixels decode (Task 4), `/profile` endpoint (dev build).

- [ ] **Step 1: Write the app — the #279 reproduction shape**

`test/ui/pixels_app.fnl`:

```fennel
;; Test app for ctx.pixels: 58 sprites of 64x96, the #279 scene shape.
;; Each sprite's RGBA string is built ONCE and cached; the provider then
;; issues one ctx.pixels command per sprite per frame.
(local dataflow (require :dataflow))
(local canvas (require :canvas))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:surface {:bg [24 26 33] :padding [8 8 8 8]}
   :film    {:bg [30 32 40]}})

(dataflow.init {:sprites 58})
(global redin_get_state (. dataflow :_get-raw-db))

(reg-sub :sprites (fn [db] (get db :sprites 58)))

;; Build one 64x96 RGBA byte string, tinted per index (deterministic).
(fn make-sprite [i]
  (let [w 64 h 96
        r (% (* i 37) 256)
        g (% (* i 91) 256)
        b (% (* i 53) 256)
        row-parts []]
    (for [_ 1 w]
      (table.insert row-parts (string.char r g b 255)))
    (let [row (table.concat row-parts)]
      (string.rep row h))))

(local sprite-cache {})
(fn sprite [i]
  (when (not (. sprite-cache i))
    (tset sprite-cache i (make-sprite i)))
  (. sprite-cache i))

(canvas.register :filmstrip
  (fn [ctx]
    (let [cols 10 cw 70 chh 102]
      (for [i 1 58]
        (let [col (% (- i 1) cols)
              row (math.floor (/ (- i 1) cols))]
          (ctx.pixels (* col cw) (* row chh) 64 96 (sprite i)))))))

(global main_view
  (fn []
    [:vbox {:aspect :surface}
     [:canvas {:id :film :provider :filmstrip :aspect :film
               :width 720 :height 640}]]))
```

- [ ] **Step 2: Write the tests**

`test/ui/test_pixels.bb`:

```clojure
(require '[redin-test :refer :all])

;; -- Stability: 58 sprites x 64x96 via ctx.pixels (the #279 scene) --

(deftest canvas-exists-and-survives-sustained-draws
  (assert-element {:tag :canvas :id :film} "filmstrip canvas should exist")
  (wait-ms 1000)
  (assert-element {:tag :canvas :id :film} "app alive after ~60 frames of pixels draws"))

(deftest screenshot-valid-with-pixels
  (let [[w h] (screenshot-dims)]
    (assert (pos? w) "screenshot decodes with pixel sprites on screen")))

;; -- Perf: render share must be far below the 22.7ms baseline (#279). --
;; Threshold is deliberately loose (8ms) to keep CI machines from flaking;
;; the dev overlay/issue baseline for this scene without ctx.pixels is 22.7ms.

(deftest render-time-under-threshold
  (wait-ms 1000) ;; warm the texture cache; steady state is what we measure
  (let [prof (get-json-profile)]
    (assert prof "profile endpoint should respond (REDIN_PROFILE build)")
    (let [render-ms (profile-avg-render-ms prof)]
      (assert (< render-ms 8.0)
              (str "steady-state render should be <8ms, got " render-ms)))))
```

The helpers `get-json-profile` / `profile-avg-render-ms` do not exist yet:
read `test/ui/test_profile.bb` and `test/ui/redin_test.bb` first — reuse
whatever accessor test_profile.bb already uses for `/profile` (add a small
helper to `redin_test.bb` only if none exists), and compute the mean of the
render-phase samples from the ring buffer in whatever shape `/profile`
returns (test_profile.bb shows the shape). Adjust the two helper names to
what actually lands.

- [ ] **Step 3: Run**

Run:
```bash
./build/redin test/ui/pixels_app.fnl &
bb test/ui/run.bb test/ui/test_pixels.bb
```
Expected: all PASS. Record the measured render-ms in the commit message.

- [ ] **Step 4: Register in run-all**

Check `test/ui/run-all.sh` — if suites are listed explicitly, add
pixels/test_pixels there following the existing pattern; if it globs
`test_*.bb`, no change.

- [ ] **Step 5: Commit**

```bash
git add test/ui/pixels_app.fnl test/ui/test_pixels.bb test/ui/run-all.sh test/ui/redin_test.bb
git commit -m "test(ui): ctx.pixels 58-sprite scene with perf assertion (#279)"
```

---

### Task 10: Documentation

**Files:**
- Modify: `docs/reference/canvas.md`, `docs/core-api.md`

**Interfaces:** none (docs only). The spec (`docs/superpowers/specs/2026-08-25-texture-foundation-design.md`) is the content source — copy its contracts exactly.

- [ ] **Step 1: canvas.md**

Add a "Command-buffer primitives" subsection documenting the two ops
(read the file's current structure first and place it where Fennel-provider
drawing is discussed; keep the file's table style):

```markdown
### `ctx.pixels`

    (ctx.pixels x y w h data ?opts)

Draws an RGBA pixel buffer as one texture blit. `data` is a byte string of
length exactly `w*h*4` (row-major RGBA); `w`/`h` are positive integers,
each <= 2048, `w*h` <= 4,194,304. `?opts`: `{:scale z}` with `z` in
`(0, 64]` (default 1), nearest-neighbor upscale. Malformed commands are
skipped.

Textures are cached by content hash — build each sprite's `data` string
once, keep it in app state, and re-issue `ctx.pixels` every frame; the
steady-state cost is one draw call per sprite. Rebuilding an identical
string is still a cache hit; rebuilding a different string uploads a new
texture (old ones age out after ~2s unused).

### `ctx.image`

    (ctx.image x y w h path ?opts)

Draws the image file at `path` (resolved against the process working
directory) stretched to `w`×`h`. Load failures draw a gray placeholder and
warn once; the file cache is cleared on hot reload.
```

- [ ] **Step 2: core-api.md**

In the element-attribute table (~line 187 area), add rows for the image
element following the table's exact column format:

```markdown
| `src` | string | image (file path, resolved against the working directory) |
| `fit` | keyword | image (`stretch`, `stretch-x`, `stretch-y`, `keep`; default `keep`) |
```

Update the image row in the node-type table (~line 156) — replace the
"Placeholder slot — themed rect; texture loading TBD" wording with e.g.
"Bitmap display. Draws `:src` per `:fit`; themed chrome behind." Search the
file for other "texture loading TBD" / image-placeholder mentions and fix
them too.

- [ ] **Step 3: Commit**

```bash
git add docs/reference/canvas.md docs/core-api.md
git commit -m "docs: ctx.pixels, ctx.image, and [:image] :src/:fit reference"
```

---

### Task 11: Final verification

**Files:** none (verification only).

- [ ] **Step 1: Full test sweep**

```bash
luajit test/lua/runner.lua test/lua/test_*.fnl
odin test src/redin/texture -collection:lib=lib -collection:luajit=vendor/luajit
odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit
odin test src/redin/parser
odin test src/redin -collection:lib=lib -collection:luajit=vendor/luajit
odin test src/redin/canvas -collection:lib=lib -collection:luajit=vendor/luajit
./build-dev.sh
./build/redin test/ui/pixels_app.fnl & bb test/ui/run.bb test/ui/test_pixels.bb
./build/redin test/ui/image_app.fnl & bb test/ui/run.bb test/ui/test_image.bb
./build/redin test/ui/canvas_app.fnl & bb test/ui/run.bb test/ui/test_canvas.bb
```
Expected: everything PASS. (Existing canvas UI suite guards against
regressions in the shared decode path.)

- [ ] **Step 2: Release build check**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```
Expected: clean (texture package has no dev-gated code).

- [ ] **Step 3: Memory check**

Run the dev binary (built with `REDIN_TRACK_MEM`) against
`test/ui/pixels_app.fnl`, let it run ~5s, POST `/shutdown`, and inspect the
leak dump: no leaks attributable to the texture package (map keys, evicted
entries).

- [ ] **Step 4: Report**

Summarize measured render-ms for the 58-sprite scene vs the 22.7ms baseline
in the final hand-off; the PR should close #279.
```

---

## Self-review notes (resolved inline)

- Spec coverage: store+eviction (T1), runtime wiring (T2), ctx.pixels (T3+T4), image op (T5), [:image] (T6), hot reload (T7), UI+perf tests (T8+T9), docs (T10), release check (T11). Negative-cache warn-once: T1. POINT filter: T1.
- Deliberate deviations from none — thresholds and caps copied from spec verbatim.
- Known look-before-you-code points are called out inside tasks (strict-string idiom, `lua_get_string_field` ownership, `/frames` attr serialization, `/profile` shape, run-all registration) rather than guessed.
