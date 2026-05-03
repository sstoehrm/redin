# Mouse Takeover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an explicit mouse-takeover mechanism to the redin dev server so UI tests can drive the real input pipeline through full drag-and-drop sequences (press → threshold-cross → drop) and inject keys mid-drag.

**Architecture:** A new `input.override` package state replaces direct raylib calls behind helper procs (`mouse_pos`, `is_mouse_button_down/pressed/released`). When `override.active` is true, dev-server endpoints feed the override state and the input pipeline reads from there instead of raylib. `/frames` JSON embeds layout `:rect` for each node so tests can resolve element coordinates.

**Tech Stack:** Odin (host + bridge), Lua/LuaJIT (runtime FFI), Fennel (app code), Babashka (test framework).

**Spec:** `docs/superpowers/specs/2026-05-01-mouse-takeover-design.md`.

---

## File Structure

**Created:**
- `src/redin/input/override.odin` — override state, helper procs
- `src/redin/input/override_test.odin` — unit tests for helpers + edge clearing

**Modified:**
- `src/redin/input/input.odin` — `poll()` and `set_hover_cursor()` use new helpers
- `src/redin/input/drag.odin` — `process_drag()` uses new helpers
- `src/redin/input/text_select.odin` — selection gesture uses new helpers
- `src/redin/input/user_events.odin` — mouse-pos read uses helper
- `src/redin/bridge/devserver.odin` — six new endpoints + frames-with-rect walker
- `src/redin/bridge/bridge.odin` — `poll_devserver` signature gains `node_rects`
- `src/redin/runtime.odin` — pass `node_rects[:]` to `poll_devserver`
- `test/ui/redin_test.bb` — input/* helpers, `rect-of`
- `test/ui/test_drag.bb` — new `drag-preview-pops-out` + `drag-esc-cancels` tests
- `.gitignore` — add `test/ui/artifacts/`
- `CLAUDE.md` — dev-server endpoint table
- `docs/core-api.md` — dev-server section, frame-format note
- `docs/reference/dev-server.md` — new endpoints
- `.claude/skills/redin-dev/SKILL.md` — dev-server table
- `.claude/skills/redin-maintenance/SKILL.md` — testing-section note

---

## Task 1: Override module + helpers

**Files:**
- Create: `src/redin/input/override.odin`
- Create: `src/redin/input/override_test.odin`

- [ ] **Step 1: Write the failing test**

Create `src/redin/input/override_test.odin`:

```odin
package input

import "core:testing"
import rl "vendor:raylib"

@(test)
test_mouse_pos_falls_back_to_raylib_when_inactive :: proc(t: ^testing.T) {
	override = Mouse_Override{}
	// Cannot easily mock rl.GetMousePosition; just assert active=false path
	// returns the raylib value (whatever it is) by reading both.
	got := mouse_pos()
	want := rl.GetMousePosition()
	testing.expect_value(t, got, want)
}

@(test)
test_mouse_pos_uses_override_when_active :: proc(t: ^testing.T) {
	override = Mouse_Override{active = true, pos = {123, 456}}
	got := mouse_pos()
	testing.expect_value(t, got.x, f32(123))
	testing.expect_value(t, got.y, f32(456))
	override = Mouse_Override{}
}

@(test)
test_is_mouse_button_down_uses_override :: proc(t: ^testing.T) {
	override = Mouse_Override{active = true, button_left = true}
	testing.expect(t, is_mouse_button_down(.LEFT))
	testing.expect(t, !is_mouse_button_down(.RIGHT))
	override = Mouse_Override{}
}

@(test)
test_pressed_clears_pending_flag :: proc(t: ^testing.T) {
	override = Mouse_Override{active = true, pending_press_left = true}
	testing.expect(t, is_mouse_button_pressed(.LEFT))
	testing.expect(t, !override.pending_press_left,
		"pending_press_left should clear after read")
	testing.expect(t, !is_mouse_button_pressed(.LEFT),
		"second read returns false")
	override = Mouse_Override{}
}

@(test)
test_released_clears_pending_flag :: proc(t: ^testing.T) {
	override = Mouse_Override{active = true, pending_release_left = true}
	testing.expect(t, is_mouse_button_released(.LEFT))
	testing.expect(t, !override.pending_release_left)
	override = Mouse_Override{}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `odin test src/redin/input -collection:lib=lib -collection:luajit=vendor/luajit`
Expected: FAIL — `Mouse_Override` / `mouse_pos` / `override` not defined.

- [ ] **Step 3: Implement the override module**

Create `src/redin/input/override.odin`:

```odin
package input

import rl "vendor:raylib"

// Test-only override of raylib mouse polling. Driven by the dev server's
// /input/* endpoints; off in normal runs.
//
// Position-only changes do not synthesise events (matches real input).
// Button transitions go through `pending_press_*` / `pending_release_*`
// which act as one-shot edges: set when the dev server flips a button,
// consumed (and cleared) by `is_mouse_button_pressed/released` exactly
// once. `is_mouse_button_down` reflects the held state continuously.
Mouse_Override :: struct {
	active:        bool,
	pos:           rl.Vector2,
	button_left:   bool,
	button_right:  bool,
	button_middle: bool,

	pending_press_left,    pending_release_left:    bool,
	pending_press_right,   pending_release_right:   bool,
	pending_press_middle,  pending_release_middle:  bool,
}

override: Mouse_Override

mouse_pos :: proc() -> rl.Vector2 {
	if override.active do return override.pos
	return rl.GetMousePosition()
}

is_mouse_button_down :: proc(btn: rl.MouseButton) -> bool {
	if override.active {
		switch btn {
		case .LEFT:    return override.button_left
		case .RIGHT:   return override.button_right
		case .MIDDLE:  return override.button_middle
		case .SIDE, .EXTRA, .FORWARD, .BACK: return false
		}
		return false
	}
	return rl.IsMouseButtonDown(btn)
}

is_mouse_button_pressed :: proc(btn: rl.MouseButton) -> bool {
	if override.active {
		switch btn {
		case .LEFT:
			r := override.pending_press_left
			override.pending_press_left = false
			return r
		case .RIGHT:
			r := override.pending_press_right
			override.pending_press_right = false
			return r
		case .MIDDLE:
			r := override.pending_press_middle
			override.pending_press_middle = false
			return r
		case .SIDE, .EXTRA, .FORWARD, .BACK: return false
		}
		return false
	}
	return rl.IsMouseButtonPressed(btn)
}

is_mouse_button_released :: proc(btn: rl.MouseButton) -> bool {
	if override.active {
		switch btn {
		case .LEFT:
			r := override.pending_release_left
			override.pending_release_left = false
			return r
		case .RIGHT:
			r := override.pending_release_right
			override.pending_release_right = false
			return r
		case .MIDDLE:
			r := override.pending_release_middle
			override.pending_release_middle = false
			return r
		case .SIDE, .EXTRA, .FORWARD, .BACK: return false
		}
		return false
	}
	return rl.IsMouseButtonReleased(btn)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `odin test src/redin/input -collection:lib=lib -collection:luajit=vendor/luajit`
Expected: PASS for the 5 new tests (and existing input package tests).

- [ ] **Step 5: Commit**

```bash
git add src/redin/input/override.odin src/redin/input/override_test.odin
git commit -m "$(cat <<'EOF'
feat(input): add mouse override state and helpers

Introduces input.override and helper procs (mouse_pos, is_mouse_button_*)
that fall back to raylib unless override.active. Foundation for
dev-server-driven input takeover.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Replace direct raylib calls

**Files:**
- Modify: `src/redin/input/input.odin:148`, `:184`, `:452`
- Modify: `src/redin/input/drag.odin:131`, `:224`, `:283`
- Modify: `src/redin/input/text_select.odin` (4 sites)
- Modify: `src/redin/input/user_events.odin:17`

- [ ] **Step 1: Replace in `input.odin`**

In `poll()` at line 148:
```odin
mouse := rl.GetMousePosition()
```
Replace with:
```odin
mouse := mouse_pos()
```

In `poll()` at line 184 (the `IsMouseButtonPressed` loop):
```odin
if rl.IsMouseButtonPressed(btn) {
```
Replace with:
```odin
if is_mouse_button_pressed(btn) {
```

In `set_hover_cursor()` at line 452:
```odin
mouse := rl.GetMousePosition()
```
Replace with:
```odin
mouse := mouse_pos()
```

- [ ] **Step 2: Replace in `drag.odin`**

Line 131:
```odin
mouse := rl.GetMousePosition()
```
→
```odin
mouse := mouse_pos()
```

Line 224 (`Drag_Pending` branch):
```odin
if rl.IsMouseButtonDown(.LEFT) {
```
→
```odin
if is_mouse_button_down(.LEFT) {
```

Line 283 (`Drag_Active` branch):
```odin
if !rl.IsMouseButtonDown(.LEFT) {
```
→
```odin
if !is_mouse_button_down(.LEFT) {
```

- [ ] **Step 3: Replace in `text_select.odin`**

Audit all `rl.GetMousePosition()` and `rl.IsMouseButton*` calls in that file and swap to the new helpers. Run:
```bash
grep -n "rl.GetMousePosition\|rl.IsMouseButton" src/redin/input/text_select.odin
```
For each hit:
- `rl.GetMousePosition()` → `mouse_pos()`
- `rl.IsMouseButtonDown(btn)` → `is_mouse_button_down(btn)`
- `rl.IsMouseButtonPressed(btn)` → `is_mouse_button_pressed(btn)`
- `rl.IsMouseButtonReleased(btn)` → `is_mouse_button_released(btn)`

- [ ] **Step 4: Replace in `user_events.odin:17`**

```odin
mouse := rl.GetMousePosition()
```
→
```odin
mouse := mouse_pos()
```

- [ ] **Step 5: Verify no direct raylib mouse calls remain in input package**

Run:
```bash
grep -n "rl.GetMousePosition\|rl.IsMouseButtonDown\|rl.IsMouseButtonPressed\|rl.IsMouseButtonReleased" src/redin/input/
```
Expected: only matches inside `override.odin` (the fallback path).

- [ ] **Step 6: Build**

Run:
```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```
Expected: success, no warnings about unused imports of `rl`. (`rl` is still used for `Vector2`, `MouseButton`, etc. — keep the import.)

- [ ] **Step 7: Commit**

```bash
git add src/redin/input/
git commit -m "$(cat <<'EOF'
refactor(input): route mouse polling through override-aware helpers

All direct raylib mouse reads in input.odin, drag.odin, text_select.odin,
and user_events.odin now go through mouse_pos / is_mouse_button_*. No
behavior change — override.active stays false in normal runs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Verify existing tests still pass

- [ ] **Step 1: Run Fennel runtime tests**

Run: `luajit test/lua/runner.lua test/lua/test_*.fnl`
Expected: all 122 tests pass.

- [ ] **Step 2: Run Odin parser tests**

Run: `odin test src/redin/parser`
Expected: all pass.

- [ ] **Step 3: Run input package tests**

Run: `odin test src/redin/input -collection:lib=lib -collection:luajit=vendor/luajit`
Expected: all pass (including the 5 from Task 1).

- [ ] **Step 4: Run UI integration tests**

Run: `bash test/ui/run-all.sh --headless`
Expected: all UI tests pass. The drag tests still rely on direct dispatch — no behavior change yet.

- [ ] **Step 5: No commit (verification only)**

If any test fails, fix before proceeding to Task 4.

---

## Task 4: Dev-server takeover/release endpoints

**Files:**
- Modify: `src/redin/bridge/devserver.odin`

- [ ] **Step 1: Add route handlers**

Append to `devserver.odin` (after the existing `handle_post_*` handlers, around line 1016):

```odin
handle_post_input_takeover :: proc(ds: ^Dev_Server, ch: ^Response_Channel) {
	if input.override.active {
		respond_json_error(ch, 409, `{"error":"takeover already active"}`)
		return
	}
	input.override = input.Mouse_Override{active = true}
	respond_json_ok(ch)
}

handle_post_input_release :: proc(ds: ^Dev_Server, ch: ^Response_Channel) {
	if !input.override.active {
		respond_json_error(ch, 409, `{"error":"takeover not active"}`)
		return
	}
	input.override = input.Mouse_Override{}
	respond_json_ok(ch)
}
```

- [ ] **Step 2: Wire routes in `process_request`**

In the `case "POST":` block (around line 590), after the `/click` arm and before `/shutdown`, add:

```odin
} else if req.path == "/input/takeover" {
	handle_post_input_takeover(ds, ch)
} else if req.path == "/input/release" {
	handle_post_input_release(ds, ch)
```

- [ ] **Step 3: Build**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: success.

- [ ] **Step 4: Smoke test by hand**

Run:
```bash
./build/redin --dev test/ui/drag_app.fnl &
sleep 1
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -sH "Authorization: Bearer $TOKEN" -X POST http://localhost:$PORT/input/takeover
curl -sH "Authorization: Bearer $TOKEN" -X POST http://localhost:$PORT/input/takeover  # 409 expected
curl -sH "Authorization: Bearer $TOKEN" -X POST http://localhost:$PORT/input/release
curl -sH "Authorization: Bearer $TOKEN" -X POST http://localhost:$PORT/input/release   # 409 expected
curl -sH "Authorization: Bearer $TOKEN" -X POST http://localhost:$PORT/shutdown
wait
```
Expected: takeover = `{"ok":true}`, second takeover = `{"error":"takeover already active"}`, release = ok, second release = error.

- [ ] **Step 5: Commit**

```bash
git add src/redin/bridge/devserver.odin
git commit -m "$(cat <<'EOF'
feat(devserver): /input/takeover and /input/release endpoints

Explicit lifecycle: takeover sets input.override.active, release clears it.
Double-acquire / double-release returns 409 to surface bugs in test code.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Mouse move/down/up endpoints

**Files:**
- Modify: `src/redin/bridge/devserver.odin`

- [ ] **Step 1: Add helpers + handlers**

Append to `devserver.odin`:

```odin
// Decode {"button":"left|right|middle"} from a Lua-staged table at -1.
read_mouse_button :: proc(L: ^Lua_State) -> (rl.MouseButton, bool) {
	lua_getfield(L, -1, "button")
	defer lua_pop(L, 1)
	if !lua_isstring(L, -1) do return .LEFT, false
	s := string(lua_tostring_raw(L, -1))
	switch s {
	case "left":   return .LEFT,   true
	case "right":  return .RIGHT,  true
	case "middle": return .MIDDLE, true
	}
	return .LEFT, false
}

handle_post_input_mouse_move :: proc(ds: ^Dev_Server, ch: ^Response_Channel, body: string) {
	if !input.override.active {
		respond_json_error(ch, 409, `{"error":"takeover not active"}`)
		return
	}
	L := ds.bridge.L
	pos := 0
	if !json_decode_value(L, body, &pos) {
		respond_json_error(ch, 400, `{"error":"invalid JSON"}`)
		return
	}
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) {
		respond_json_error(ch, 400, `{"error":"body must be an object"}`)
		return
	}
	lua_getfield(L, -1, "x")
	x := f32(lua_tonumber(L, -1))
	lua_pop(L, 1)
	lua_getfield(L, -1, "y")
	y := f32(lua_tonumber(L, -1))
	lua_pop(L, 1)
	if math.is_nan(x) || math.is_nan(y) || math.is_inf(x) || math.is_inf(y) {
		respond_json_error(ch, 400, `{"error":"x,y must be finite"}`)
		return
	}
	input.override.pos = rl.Vector2{x, y}
	respond_json_ok(ch)
}

handle_post_input_mouse_down :: proc(ds: ^Dev_Server, ch: ^Response_Channel, body: string) {
	if !input.override.active {
		respond_json_error(ch, 409, `{"error":"takeover not active"}`)
		return
	}
	L := ds.bridge.L
	pos := 0
	if !json_decode_value(L, body, &pos) {
		respond_json_error(ch, 400, `{"error":"invalid JSON"}`)
		return
	}
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) {
		respond_json_error(ch, 400, `{"error":"body must be an object"}`)
		return
	}
	btn, ok := read_mouse_button(L)
	if !ok {
		respond_json_error(ch, 400, `{"error":"button must be left|right|middle"}`)
		return
	}
	already_down := false
	switch btn {
	case .LEFT:
		already_down = input.override.button_left
		if !already_down {
			input.override.button_left = true
			input.override.pending_press_left = true
		}
	case .RIGHT:
		already_down = input.override.button_right
		if !already_down {
			input.override.button_right = true
			input.override.pending_press_right = true
		}
	case .MIDDLE:
		already_down = input.override.button_middle
		if !already_down {
			input.override.button_middle = true
			input.override.pending_press_middle = true
		}
	case .SIDE, .EXTRA, .FORWARD, .BACK:
	}
	if already_down {
		respond_json_error(ch, 409, `{"error":"button already down"}`)
		return
	}
	respond_json_ok(ch)
}

handle_post_input_mouse_up :: proc(ds: ^Dev_Server, ch: ^Response_Channel, body: string) {
	if !input.override.active {
		respond_json_error(ch, 409, `{"error":"takeover not active"}`)
		return
	}
	L := ds.bridge.L
	pos := 0
	if !json_decode_value(L, body, &pos) {
		respond_json_error(ch, 400, `{"error":"invalid JSON"}`)
		return
	}
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) {
		respond_json_error(ch, 400, `{"error":"body must be an object"}`)
		return
	}
	btn, ok := read_mouse_button(L)
	if !ok {
		respond_json_error(ch, 400, `{"error":"button must be left|right|middle"}`)
		return
	}
	already_up := false
	switch btn {
	case .LEFT:
		already_up = !input.override.button_left
		if !already_up {
			input.override.button_left = false
			input.override.pending_release_left = true
		}
	case .RIGHT:
		already_up = !input.override.button_right
		if !already_up {
			input.override.button_right = false
			input.override.pending_release_right = true
		}
	case .MIDDLE:
		already_up = !input.override.button_middle
		if !already_up {
			input.override.button_middle = false
			input.override.pending_release_middle = true
		}
	case .SIDE, .EXTRA, .FORWARD, .BACK:
	}
	if already_up {
		respond_json_error(ch, 409, `{"error":"button already up"}`)
		return
	}
	respond_json_ok(ch)
}
```

- [ ] **Step 2: Wire routes**

In `process_request` `case "POST":`, after `/input/release`:

```odin
} else if req.path == "/input/mouse/move" {
	handle_post_input_mouse_move(ds, ch, req.body)
} else if req.path == "/input/mouse/down" {
	handle_post_input_mouse_down(ds, ch, req.body)
} else if req.path == "/input/mouse/up" {
	handle_post_input_mouse_up(ds, ch, req.body)
```

- [ ] **Step 3: Build**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: success.

- [ ] **Step 4: Smoke-test from shell**

```bash
./build/redin --dev test/ui/drag_app.fnl &
sleep 1
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
H="Authorization: Bearer $TOKEN"
curl -sH "$H" -X POST http://localhost:$PORT/input/takeover
curl -sH "$H" -X POST -d '{"x":100,"y":80}' http://localhost:$PORT/input/mouse/move
curl -sH "$H" -X POST -d '{"button":"left"}' http://localhost:$PORT/input/mouse/down
curl -sH "$H" -X POST -d '{"button":"left"}' http://localhost:$PORT/input/mouse/down  # 409
curl -sH "$H" -X POST -d '{"x":140,"y":80}' http://localhost:$PORT/input/mouse/move
curl -sH "$H" -X POST -d '{"button":"left"}' http://localhost:$PORT/input/mouse/up
curl -sH "$H" -X POST http://localhost:$PORT/input/release
curl -sH "$H" -X POST http://localhost:$PORT/shutdown
wait
```
Expected: each ok except the second `down` which returns 409. The app receives a real drag-press / move / release sequence; nothing crashes.

- [ ] **Step 5: Commit**

```bash
git add src/redin/bridge/devserver.odin
git commit -m "$(cat <<'EOF'
feat(devserver): /input/mouse/{move,down,up} endpoints

Drives input.override position and per-button held state. Pending
press/release flags act as one-shot edges, consumed by the input
package's pressed/released helpers.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: `/input/key` endpoint

**Files:**
- Modify: `src/redin/bridge/devserver.odin`

- [ ] **Step 1: Add a string→raylib KeyboardKey mapper**

Append to `devserver.odin`:

```odin
// Maps the same string names the framework uses for key events
// (key_to_string_input in input.odin). Keep them in sync.
key_string_to_raylib :: proc(s: string) -> (rl.KeyboardKey, bool) {
	switch s {
	case "enter":     return .ENTER,     true
	case "escape":    return .ESCAPE,    true
	case "backspace": return .BACKSPACE, true
	case "tab":       return .TAB,       true
	case "space":     return .SPACE,     true
	case "up":        return .UP,        true
	case "down":      return .DOWN,      true
	case "left":      return .LEFT,      true
	case "right":     return .RIGHT,     true
	case "delete":    return .DELETE,    true
	case "home":      return .HOME,      true
	case "end":       return .END,       true
	case "pageup":    return .PAGE_UP,   true
	case "pagedown":  return .PAGE_DOWN, true
	}
	// Single character → KEY_A..KEY_Z, KEY_ZERO..KEY_NINE
	if len(s) == 1 {
		c := s[0]
		if c >= 'a' && c <= 'z' do return rl.KeyboardKey(int(rl.KeyboardKey.A) + int(c - 'a')), true
		if c >= 'A' && c <= 'Z' do return rl.KeyboardKey(int(rl.KeyboardKey.A) + int(c - 'A')), true
		if c >= '0' && c <= '9' do return rl.KeyboardKey(int(rl.KeyboardKey.ZERO) + int(c - '0')), true
	}
	return .KEY_NULL, false
}

handle_post_input_key :: proc(ds: ^Dev_Server, ch: ^Response_Channel, body: string) {
	L := ds.bridge.L
	pos := 0
	if !json_decode_value(L, body, &pos) {
		respond_json_error(ch, 400, `{"error":"invalid JSON"}`)
		return
	}
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) {
		respond_json_error(ch, 400, `{"error":"body must be an object"}`)
		return
	}
	lua_getfield(L, -1, "key")
	key_str := ""
	if lua_isstring(L, -1) do key_str = string(lua_tostring_raw(L, -1))
	lua_pop(L, 1)
	key, ok := key_string_to_raylib(key_str)
	if !ok {
		respond_json_error(ch, 400, `{"error":"unknown key"}`)
		return
	}
	mods := types.KeyMods{}
	lua_getfield(L, -1, "mods")
	if lua_istable(L, -1) {
		read_bool :: proc(L: ^Lua_State, key: cstring) -> bool {
			lua_getfield(L, -1, key)
			defer lua_pop(L, 1)
			return lua_toboolean(L, -1) != 0
		}
		mods.shift = read_bool(L, "shift")
		mods.ctrl  = read_bool(L, "ctrl")
		mods.alt   = read_bool(L, "alt")
		mods.super = read_bool(L, "super")
	}
	lua_pop(L, 1)
	pos2 := input.mouse_pos()
	append(&ds.event_queue, types.InputEvent(types.KeyEvent{
		x = pos2.x, y = pos2.y, key = key, mods = mods,
	}))
	respond_json_ok(ch)
}
```

- [ ] **Step 2: Wire route**

In `process_request` `case "POST":`, after the mouse routes:

```odin
} else if req.path == "/input/key" {
	handle_post_input_key(ds, ch, req.body)
```

- [ ] **Step 3: Build**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: success.

- [ ] **Step 4: Smoke-test**

```bash
./build/redin --dev test/ui/drag_app.fnl &
sleep 1
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -sH "Authorization: Bearer $TOKEN" -X POST -d '{"key":"escape"}' \
  http://localhost:$PORT/input/key
curl -sH "Authorization: Bearer $TOKEN" -X POST http://localhost:$PORT/shutdown
wait
```
Expected: `{"ok":true}`; app receives one ESC KeyEvent.

- [ ] **Step 5: Commit**

```bash
git add src/redin/bridge/devserver.odin
git commit -m "$(cat <<'EOF'
feat(devserver): /input/key endpoint

One-shot KeyEvent synthesis. Does not require takeover — keys are
event-driven, not continuous polling.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Embed `:rect` into `/frames` JSON

**Files:**
- Modify: `src/redin/bridge/bridge.odin` (`poll_devserver` signature)
- Modify: `src/redin/runtime.odin` (call site)
- Modify: `src/redin/bridge/devserver.odin` (Dev_Server struct + handler)

- [ ] **Step 1: Extend `poll_devserver` signature**

In `src/redin/bridge/bridge.odin` line 103, change:
```odin
poll_devserver :: proc(b: ^Bridge, events: ^[dynamic]types.InputEvent) {
	if !b.dev_mode do return
	devserver_poll(&b.dev_server)
	devserver_drain_events(&b.dev_server, events)
}
```
to:
```odin
poll_devserver :: proc(b: ^Bridge, events: ^[dynamic]types.InputEvent, node_rects: []rl.Rectangle) {
	if !b.dev_mode do return
	b.dev_server.current_rects = node_rects
	devserver_poll(&b.dev_server)
	devserver_drain_events(&b.dev_server, events)
	b.dev_server.current_rects = nil
}
```

(`rl` already imported at top of bridge.odin? Check — if not, add `import rl "vendor:raylib"`.)

- [ ] **Step 2: Add `current_rects` field to `Dev_Server`**

In `src/redin/bridge/devserver.odin` around line 43, in the `Dev_Server :: struct { ... }`, add:
```odin
current_rects: []rl.Rectangle, // borrowed during a poll cycle, nil otherwise
```

- [ ] **Step 3: Update runtime call site**

In `src/redin/runtime.odin:207`:
```odin
bridge.poll_devserver(&b, &input_events)
```
→
```odin
bridge.poll_devserver(&b, &input_events, node_rects[:])
```

- [ ] **Step 4: Replace `handle_get_frames` with rect-embedding walker**

Replace the body of `handle_get_frames` in `devserver.odin`:

```odin
handle_get_frames :: proc(ds: ^Dev_Server, ch: ^Response_Channel) {
	L := ds.bridge.L
	lua_getglobal(L, "require")
	lua_pushstring(L, "view")
	if lua_pcall(L, 1, 1, 0) != 0 {
		lua_pop(L, 1)
		respond_json_error(ch, 500, `{"error":"lua error"}`)
		return
	}
	lua_getfield(L, -1, "get-last-push")
	lua_remove(L, -2)
	if lua_pcall(L, 0, 1, 0) != 0 {
		lua_pop(L, 1)
		respond_json_error(ch, 500, `{"error":"lua error"}`)
		return
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	dfs_idx := 0
	frame_value_to_json(&b, L, -1, ds.current_rects, &dfs_idx)
	lua_pop(L, 1)
	respond_json(ch, strings.to_string(b))
}

// Walks a Fennel-shaped frame value [tag attrs ...children] DFS, emitting
// JSON. For each node table, injects "rect":[x,y,w,h] into the attrs
// object using `dfs_idx` as the lookup into node_rects.
//
// For non-frame values (numbers, strings, primitive children inside
// e.g. canvas attribute tables), defers to lua_value_to_json.
//
// Mirrors lua_read_node's flattening order. dfs_idx must be incremented
// exactly once per node (vector with a tag at slot 1).
frame_value_to_json :: proc(
	b: ^strings.Builder, L: ^Lua_State, index: i32,
	rects: []rl.Rectangle, dfs_idx: ^int,
) {
	// Normalise to absolute so the index stays valid as we push values.
	idx := index < 0 ? lua_gettop(L) + index + 1 : index
	if !lua_istable(L, idx) {
		lua_value_to_json(b, L, idx)
		return
	}
	// Detect a frame node: table whose [1] is a string starting with ':'.
	lua_rawgeti(L, idx, 1)
	is_node := lua_isstring(L, -1)
	tag := ""
	if is_node {
		tag = string(lua_tostring_raw(L, -1))
		// Heuristic: frame tags start with ':' (Fennel keyword).
		if len(tag) == 0 || tag[0] != ':' do is_node = false
	}
	lua_pop(L, 1)
	if !is_node {
		lua_value_to_json(b, L, idx)
		return
	}

	// Capture rect now (before recursing into children, which would advance dfs_idx).
	my_idx := dfs_idx^
	dfs_idx^ += 1
	rect_str := ""
	if my_idx >= 0 && my_idx < len(rects) {
		r := rects[my_idx]
		rect_str = fmt.tprintf(`,"rect":[%g,%g,%g,%g]`, r.x, r.y, r.width, r.height)
	} else {
		rect_str = `,"rect":null`
	}

	// Emit ["tag", attrs-with-rect, ...children-recursed]
	strings.write_string(b, "[")
	// tag
	strings.write_string(b, `"`)
	strings.write_string(b, tag)
	strings.write_string(b, `"`)
	// attrs at slot [2]
	lua_rawgeti(L, idx, 2)
	strings.write_string(b, ",")
	if lua_istable(L, -1) {
		// Re-emit attrs as object, then splice in the rect.
		// Simpler: emit existing attrs via lua_value_to_json into a temp builder,
		// then string-edit. But lua_value_to_json on a Lua table emits {} object,
		// and we want to inject one extra field. Trick: emit the object, then
		// rewind one byte ("}"), append `,"rect":[...]` then "}".
		tmp := strings.builder_make()
		defer strings.builder_destroy(&tmp)
		lua_value_to_json(&tmp, L, -1)
		s := strings.to_string(tmp)
		if len(s) >= 2 && s[len(s)-1] == '}' {
			if s == "{}" {
				strings.write_string(b, "{")
				// rect_str starts with ','; strip the leading comma.
				strings.write_string(b, rect_str[1:])
				strings.write_string(b, "}")
			} else {
				strings.write_string(b, s[:len(s)-1])
				strings.write_string(b, rect_str)
				strings.write_string(b, "}")
			}
		} else {
			// Defensive: emit as-is.
			strings.write_string(b, s)
		}
	} else {
		// No attrs table — synthesise {rect}.
		strings.write_string(b, "{")
		strings.write_string(b, rect_str[1:])
		strings.write_string(b, "}")
	}
	lua_pop(L, 1)
	// children at slots 3..n
	n := lua_objlen(L, idx)
	for i in 3..=n {
		strings.write_string(b, ",")
		lua_rawgeti(L, idx, i32(i))
		frame_value_to_json(b, L, -1, rects, dfs_idx)
		lua_pop(L, 1)
	}
	strings.write_string(b, "]")
}
```

- [ ] **Step 5: Build**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: success.

- [ ] **Step 6: Smoke-test**

```bash
./build/redin --dev test/ui/drag_app.fnl &
sleep 1
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -sH "Authorization: Bearer $TOKEN" http://localhost:$PORT/frames | head -c 1000
curl -sH "Authorization: Bearer $TOKEN" -X POST http://localhost:$PORT/shutdown
wait
```
Expected: JSON contains `"rect":[N,N,N,N]` on every node.

- [ ] **Step 7: Commit**

```bash
git add src/redin/bridge/bridge.odin src/redin/bridge/devserver.odin src/redin/runtime.odin
git commit -m "$(cat <<'EOF'
feat(devserver): embed layout :rect in /frames JSON

Each node's attrs object gains "rect":[x,y,w,h] sourced from the renderer's
node_rects array, matched by DFS index. Tests now resolve element positions
without a separate /rects endpoint.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Babashka test helpers

**Files:**
- Modify: `test/ui/redin_test.bb`
- Modify: `.gitignore`

- [ ] **Step 1: Add helpers in `redin_test.bb`**

After the existing `click` helper (around line 95), add:

```clojure
;; -- Mouse takeover --

(defn input-takeover [] (post-json "/input/takeover" {}))
(defn input-release  [] (post-json "/input/release"  {}))

(defn input-mouse-move [x y]
  (post-json "/input/mouse/move" {:x x :y y}))

(defn input-mouse-down [btn]
  (post-json "/input/mouse/down" {:button (name btn)}))

(defn input-mouse-up [btn]
  (post-json "/input/mouse/up" {:button (name btn)}))

(defn input-key
  ([k]      (post-json "/input/key" {:key (name k)}))
  ([k mods] (post-json "/input/key" {:key (name k) :mods mods})))

(defn rect-of
  "Read the :rect attr from a frame node and return {:x :y :w :h}."
  [node]
  (let [[x y w h] (get (frame-attrs node) :rect)]
    {:x x :y y :w w :h h}))
```

`frame-attrs` is private to that file but we're adding helpers in the same namespace, so it's accessible.

- [ ] **Step 2: Add artifact dir to gitignore**

In `.gitignore`, add:
```
test/ui/artifacts/
```

- [ ] **Step 3: Smoke-test the bb helpers**

```bash
./build/redin --dev test/ui/drag_app.fnl &
sleep 1
bb -e '(load-file "test/ui/redin_test.bb")
       (require (quote redin-test))
       (redin-test/input-takeover)
       (redin-test/input-mouse-move 50 50)
       (redin-test/input-release)
       (println "ok")'
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -sH "Authorization: Bearer $TOKEN" -X POST http://localhost:$PORT/shutdown
wait
```
Expected: prints `ok`, no errors.

- [ ] **Step 4: Commit**

```bash
git add test/ui/redin_test.bb .gitignore
git commit -m "$(cat <<'EOF'
test(ui): add input takeover helpers to redin-test framework

input-takeover, input-release, input-mouse-{move,down,up}, input-key,
and rect-of for resolving element positions from /frames.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: New drag UI tests

**Files:**
- Modify: `test/ui/test_drag.bb`
- Modify: `test/ui/drag_app.fnl` (only if rows lack `:id` attrs)

- [ ] **Step 1: Verify `drag_app.fnl` rows expose ids**

Run:
```bash
grep -n ":id" test/ui/drag_app.fnl
```
Expected: each row hbox has `:id :item-N` or similar so `find-element` can target it. If not, add ids to the row hboxes (not just the inner text nodes).

If a row already has `:id`, skip to Step 3. If not, add `:id (.. "row-" i)` to the hbox in the `icollect`.

- [ ] **Step 2: Smoke-test that ids appear in /frames**

```bash
./build/redin --dev test/ui/drag_app.fnl &
sleep 1
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -sH "Authorization: Bearer $TOKEN" http://localhost:$PORT/frames | grep -o '"id":"row-[0-9]*"' | head -4
curl -sH "Authorization: Bearer $TOKEN" -X POST http://localhost:$PORT/shutdown
wait
```
Expected: 4 ids matching the rows.

- [ ] **Step 3: Append the new tests to `test/ui/test_drag.bb`**

```clojure
;; -- End-to-end via input pipeline --

(defn- ensure-artifacts-dir []
  (let [d (io/file "test/ui/artifacts")]
    (when-not (.exists d) (.mkdirs d))))

(deftest drag-preview-pops-out
  (dispatch ["event/reset"])
  (wait-ms 100)
  (ensure-artifacts-dir)
  (let [src (rect-of (find-element {:id :row-1}))
        dst (rect-of (find-element {:id :row-3}))
        sx  (+ (:x src) 10) sy (+ (:y src) 10)
        dx  (+ (:x dst) 10) dy (+ (:y dst) 10)]
    (input-takeover)
    (try
      (input-mouse-move sx sy)
      (input-mouse-down :left)
      (input-mouse-move (+ sx 20) (+ sy 5))   ; cross 4px threshold
      (wait-for (state= "last-drag" 1) {:timeout 2000})
      (input-mouse-move dx dy)
      (wait-ms 50)
      (screenshot "test/ui/artifacts/drag_preview.png")
      (input-mouse-up :left)
      (wait-for (state= "last-drop.from" 1) {:timeout 2000})
      (finally
        (input-release)))))

(deftest drag-esc-cancels
  (dispatch ["event/reset"])
  (wait-ms 100)
  (let [src (rect-of (find-element {:id :row-1}))
        sx  (+ (:x src) 10) sy (+ (:y src) 10)]
    (input-takeover)
    (try
      (input-mouse-move sx sy)
      (input-mouse-down :left)
      (input-mouse-move (+ sx 20) sy)
      (wait-for (state= "last-drag" 1) {:timeout 2000})
      (input-key :escape)
      (wait-ms 100)
      (input-mouse-up :left)
      (wait-ms 100)
      (assert-state "last-drop" nil? "Esc should cancel; no drop fires")
      (finally
        (input-release)))))
```

If `io` isn't already required at the top of the file, add `[clojure.java.io :as io]` to the `require`.

- [ ] **Step 4: Run drag tests**

```bash
./build/redin --dev test/ui/drag_app.fnl &
sleep 2
bb test/ui/run.bb test/ui/test_drag.bb
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -sH "Authorization: Bearer $TOKEN" -X POST http://localhost:$PORT/shutdown
wait
```
Expected: all drag tests pass, `test/ui/artifacts/drag_preview.png` written.

- [ ] **Step 5: Visually inspect the screenshot**

Open `test/ui/artifacts/drag_preview.png`. The drag preview clone should be visible at the cursor position over row-3, distinct from the original row-1 slot. (If running headless, copy out and view locally.)

- [ ] **Step 6: Commit**

```bash
git add test/ui/test_drag.bb test/ui/drag_app.fnl
git commit -m "$(cat <<'EOF'
test(ui): drag end-to-end via input pipeline

Two new tests drive a real drag through the dev server's input takeover:
drag-preview-pops-out (asserts the drag → drop pipeline + writes a
mid-drag screenshot artifact for human inspection) and drag-esc-cancels
(asserts Esc mid-drag prevents the drop from firing).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Documentation updates

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/core-api.md`
- Modify: `docs/reference/dev-server.md`
- Modify: `.claude/skills/redin-dev/SKILL.md`
- Modify: `.claude/skills/redin-maintenance/SKILL.md`

- [ ] **Step 1: Update `CLAUDE.md` dev-server table**

Find the dev-server endpoint table in `CLAUDE.md`. Add rows:

```markdown
| `POST` | `/input/takeover` | Take over mouse polling. Required before `/input/mouse/*`. |
| `POST` | `/input/release` | Restore raylib mouse polling. |
| `POST` | `/input/mouse/move` | Set override mouse position (`{x,y}`). |
| `POST` | `/input/mouse/down` | Press a button (`{button:"left\|right\|middle"}`). |
| `POST` | `/input/mouse/up` | Release a button. |
| `POST` | `/input/key` | Synthesise one KeyEvent (`{key, mods?}`). |
```

Also update the `/frames` row description to mention `:rect` embedding:
```markdown
| `GET` | `/frames` | Last pushed frame (view tree as JSON). Each node's attrs include `"rect":[x,y,w,h]` from the most recent layout. |
```

- [ ] **Step 2: Update `docs/core-api.md`**

Find the dev-server section. Add the same six endpoints with one-paragraph descriptions of the takeover lifecycle and a small `curl` example that does press-move-release.

Find the `/frames` description. Note that each node now carries `:rect [x y w h]` reflecting the last rendered layout (may be one frame stale during hot-reload).

- [ ] **Step 3: Update `docs/reference/dev-server.md`**

Same six endpoints + a worked example end-to-end (take over, move, down, move, up, release).

- [ ] **Step 4: Update `redin-dev` skill**

In `.claude/skills/redin-dev/SKILL.md`, find the dev-server table and add the six endpoints. Note the `:rect` attr in `/frames`.

- [ ] **Step 5: Update `redin-maintenance` skill**

In `.claude/skills/redin-maintenance/SKILL.md`, the testing section: note that drag tests now exercise the real input pipeline, and that `test/ui/artifacts/` is gitignored (created on demand).

- [ ] **Step 6: Run a doc-vs-code grep sweep**

```bash
rg -n 'input.override|/input/takeover|/input/release|/input/mouse|/input/key' docs/ .claude/skills/ CLAUDE.md
```
Expected: hits in CLAUDE.md, the docs and skill files updated above.

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md docs/core-api.md docs/reference/dev-server.md .claude/skills/
git commit -m "$(cat <<'EOF'
docs: mouse takeover endpoints and /frames :rect embedding

Update CLAUDE.md, core-api, dev-server reference, and the redin-dev /
redin-maintenance skills.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Final verification

- [ ] **Step 1: Build**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```
Expected: success, no warnings.

- [ ] **Step 2: Fennel runtime tests**

```bash
luajit test/lua/runner.lua test/lua/test_*.fnl
```
Expected: all pass.

- [ ] **Step 3: Odin parser tests**

```bash
odin test src/redin/parser
```
Expected: all pass.

- [ ] **Step 4: Odin input tests**

```bash
odin test src/redin/input -collection:lib=lib -collection:luajit=vendor/luajit
```
Expected: all pass (including new override tests).

- [ ] **Step 5: Full UI suite (headless)**

```bash
bash test/ui/run-all.sh --headless
```
Expected: all UI tests pass, including the new drag tests.

- [ ] **Step 6: Memory check on the takeover flow**

```bash
./build/redin --dev --track-mem test/ui/drag_app.fnl &
sleep 1
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token); H="Authorization: Bearer $TOKEN"
curl -sH "$H" -X POST http://localhost:$PORT/input/takeover
curl -sH "$H" -X POST -d '{"x":100,"y":80}' http://localhost:$PORT/input/mouse/move
curl -sH "$H" -X POST -d '{"button":"left"}' http://localhost:$PORT/input/mouse/down
sleep 0.1
curl -sH "$H" -X POST -d '{"x":140,"y":80}' http://localhost:$PORT/input/mouse/move
sleep 0.1
curl -sH "$H" -X POST -d '{"button":"left"}' http://localhost:$PORT/input/mouse/up
curl -sH "$H" -X POST http://localhost:$PORT/input/release
curl -sH "$H" -X POST http://localhost:$PORT/shutdown
wait
```
Expected: no `leak` / `outstanding` lines on stderr at shutdown.

- [ ] **Step 7: No commit (verification only)**

---

## Self-review checklist (run before handing off)

- Spec coverage:
  - input.override + helpers → Task 1
  - call-site sweep → Task 2
  - takeover/release endpoints → Task 4
  - mouse move/down/up endpoints → Task 5
  - /input/key endpoint → Task 6
  - rect embedding in /frames → Task 7
  - bb helpers + rect-of → Task 8
  - drag-preview screenshot test → Task 9
  - Esc-cancel test → Task 9
  - docs update → Task 10
  - All spec sections covered.
- Placeholder scan: none of "TBD", "TODO", "implement later", "appropriate error handling".
- Type consistency: `Mouse_Override`, `mouse_pos`, `is_mouse_button_down/pressed/released`, `pending_press_*`, `pending_release_*`, `current_rects` — used consistently across tasks.
