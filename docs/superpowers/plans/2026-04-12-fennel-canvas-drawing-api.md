# Fennel Canvas 2D Drawing API — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Fennel code draw 2D primitives on canvas elements without modifying the Odin binary per-provider.

**Architecture:** Command-buffer approach. Fennel draw functions append commands to a Lua table; a generic Odin provider reads the buffer and executes Raylib calls. Registration, ctx building, and input queries live in a new `canvas.fnl` module. Odin-side changes are in `bridge.odin` (host functions, buffer execution) and `canvas.odin` (name tracking).

**Tech Stack:** Fennel (Lua 5.1), Odin, Raylib, LuaJIT C API

---

### File Structure

**New files:**
- `src/runtime/canvas.fnl` — Fennel module: register/unregister, ctx builder, `_draw` entry point, global registration
- `test/lua/test_canvas.fnl` — Unit tests for the canvas module
- `test/ui/canvas_app.fnl` — Minimal canvas test app
- `test/ui/test_canvas.bb` — UI integration test

**Modified files:**
- `src/host/canvas/canvas.odin` — Add `current_name` tracking (set in `process`)
- `src/host/bridge/bridge.odin` — Add host functions (`canvas_register`, `canvas_unregister`, `key_down`, `key_pressed`), generic Fennel provider, `lua_canvas_draw`, command buffer execution, helper procs
- `src/runtime/init.fnl` — Require and wire up canvas module

---

### Task 1: Fennel canvas module — ctx drawing primitives

**Files:**
- Create: `test/lua/test_canvas.fnl`
- Create: `src/runtime/canvas.fnl`

- [ ] **Step 1: Write failing tests for ctx drawing methods**

```fennel
;; test/lua/test_canvas.fnl
(local canvas (require :canvas))

(local t {})

(fn setup []
  (canvas._reset))

;; --- ctx drawing primitives ---

(fn t.test-ctx-rect-appends-to-buffer []
  (setup)
  (canvas.register :test-draw
    (fn [ctx]
      (ctx.rect 10 20 100 50 {:fill [255 0 0]})))
  (let [buf (canvas._draw :test-draw 400 300 {})]
    (assert buf "buffer returned")
    (assert (= (length buf) 1) "one command")
    (let [cmd (. buf 1)]
      (assert (= (. cmd 1) :rect) "tag is rect")
      (assert (= (. cmd 2) 10) "x")
      (assert (= (. cmd 3) 20) "y")
      (assert (= (. cmd 4) 100) "w")
      (assert (= (. cmd 5) 50) "h")
      (assert (= (. (. cmd 6) :fill 1) 255) "fill r"))))

(fn t.test-ctx-circle-appends-to-buffer []
  (setup)
  (canvas.register :test-circle
    (fn [ctx]
      (ctx.circle 50 60 25 {:fill [0 255 0]})))
  (let [buf (canvas._draw :test-circle 400 300 {})]
    (assert (= (length buf) 1) "one command")
    (let [cmd (. buf 1)]
      (assert (= (. cmd 1) :circle) "tag is circle")
      (assert (= (. cmd 2) 50) "cx")
      (assert (= (. cmd 3) 60) "cy")
      (assert (= (. cmd 4) 25) "r"))))

(fn t.test-ctx-line-appends-to-buffer []
  (setup)
  (canvas.register :test-line
    (fn [ctx]
      (ctx.line 0 0 100 100 {:stroke [0 0 0] :width 2})))
  (let [buf (canvas._draw :test-line 400 300 {})]
    (assert (= (length buf) 1) "one command")
    (let [cmd (. buf 1)]
      (assert (= (. cmd 1) :line) "tag is line")
      (assert (= (. cmd 5) 100) "y2"))))

(fn t.test-ctx-text-appends-to-buffer []
  (setup)
  (canvas.register :test-text
    (fn [ctx]
      (ctx.text 10 20 "hello" {:size 16 :color [0 0 0]})))
  (let [buf (canvas._draw :test-text 400 300 {})]
    (assert (= (length buf) 1) "one command")
    (let [cmd (. buf 1)]
      (assert (= (. cmd 1) :text) "tag is text")
      (assert (= (. cmd 4) "hello") "text content"))))

(fn t.test-ctx-ellipse-appends-to-buffer []
  (setup)
  (canvas.register :test-ellipse
    (fn [ctx]
      (ctx.ellipse 100 100 40 20 {:fill [0 0 255]})))
  (let [buf (canvas._draw :test-ellipse 400 300 {})]
    (let [cmd (. buf 1)]
      (assert (= (. cmd 1) :ellipse) "tag is ellipse")
      (assert (= (. cmd 4) 40) "rx")
      (assert (= (. cmd 5) 20) "ry"))))

(fn t.test-ctx-polygon-appends-to-buffer []
  (setup)
  (canvas.register :test-polygon
    (fn [ctx]
      (ctx.polygon [[0 0] [100 0] [50 80]] {:fill [255 255 0]})))
  (let [buf (canvas._draw :test-polygon 400 300 {})]
    (let [cmd (. buf 1)]
      (assert (= (. cmd 1) :polygon) "tag is polygon")
      (assert (= (length (. cmd 2)) 3) "3 points"))))

(fn t.test-ctx-image-appends-to-buffer []
  (setup)
  (canvas.register :test-image
    (fn [ctx]
      (ctx.image 10 10 64 64 "icon")))
  (let [buf (canvas._draw :test-image 400 300 {})]
    (let [cmd (. buf 1)]
      (assert (= (. cmd 1) :image) "tag is image")
      (assert (= (. cmd 6) "icon") "asset name"))))

(fn t.test-ctx-multiple-commands []
  (setup)
  (canvas.register :test-multi
    (fn [ctx]
      (ctx.rect 0 0 10 10 {})
      (ctx.circle 50 50 5 {})
      (ctx.line 0 0 100 100 {})))
  (let [buf (canvas._draw :test-multi 400 300 {})]
    (assert (= (length buf) 3) "three commands")
    (assert (= (. (. buf 1) 1) :rect) "first is rect")
    (assert (= (. (. buf 2) 1) :circle) "second is circle")
    (assert (= (. (. buf 3) 1) :line) "third is line")))

(fn t.test-ctx-width-height []
  (setup)
  (var captured-w nil)
  (var captured-h nil)
  (canvas.register :test-dims
    (fn [ctx]
      (set captured-w ctx.width)
      (set captured-h ctx.height)))
  (canvas._draw :test-dims 800 600 {})
  (assert (= captured-w 800) "width passed")
  (assert (= captured-h 600) "height passed"))

t
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `luajit test/lua/runner.lua test/lua/test_canvas.fnl`
Expected: FAIL — module `canvas` not found

- [ ] **Step 3: Implement canvas module with ctx builder and drawing primitives**

```fennel
;; src/runtime/canvas.fnl
(local M {})

(var registry {})

(fn build-ctx [w h input]
  (let [buf []]
    {:width w
     :height h
     :_buffer buf
     ;; Drawing primitives
     :rect (fn [x y w h ?opts]
             (table.insert buf [:rect x y w h (or ?opts {})]))
     :circle (fn [cx cy r ?opts]
               (table.insert buf [:circle cx cy r (or ?opts {})]))
     :ellipse (fn [cx cy rx ry ?opts]
                (table.insert buf [:ellipse cx cy rx ry (or ?opts {})]))
     :line (fn [x1 y1 x2 y2 ?opts]
             (table.insert buf [:line x1 y1 x2 y2 (or ?opts {})]))
     :text (fn [x y str ?opts]
             (table.insert buf [:text x y str (or ?opts {})]))
     :polygon (fn [points ?opts]
                (table.insert buf [:polygon points (or ?opts {})]))
     :image (fn [x y w h name]
              (table.insert buf [:image x y w h name]))
     ;; Input queries
     :mouse-x (fn [] (or (. input :mouse-x) 0))
     :mouse-y (fn [] (or (. input :mouse-y) 0))
     :mouse-in? (fn [] (or (. input :mouse-in) false))
     :mouse-down? (fn [?btn]
                    (let [tbl (. input :mouse-down)]
                      (if tbl (. tbl (or ?btn :left)) false)))
     :mouse-pressed? (fn [?btn]
                       (let [tbl (. input :mouse-pressed)]
                         (if tbl (. tbl (or ?btn :left)) false)))
     :mouse-released? (fn [?btn]
                        (let [tbl (. input :mouse-released)]
                          (if tbl (. tbl (or ?btn :left)) false)))
     :key-down? (fn [key]
                  (let [redin-tbl (rawget _G :redin)]
                    (if (and redin-tbl (rawget redin-tbl :key_down))
                      ((rawget redin-tbl :key_down) key)
                      false)))
     :key-pressed? (fn [key]
                     (let [redin-tbl (rawget _G :redin)]
                       (if (and redin-tbl (rawget redin-tbl :key_pressed))
                         ((rawget redin-tbl :key_pressed) key)
                         false)))
     ;; Dispatch
     :dispatch (fn [event]
                 (let [dispatch-fn (or _G.dispatch _G.redin_dispatch)]
                   (when dispatch-fn (dispatch-fn event))))}))

;; Register a draw function under a name
(fn M.register [name draw-fn]
  (tset registry name draw-fn)
  (let [redin-tbl (rawget _G :redin)]
    (when (and redin-tbl (rawget redin-tbl :canvas_register))
      ((rawget redin-tbl :canvas_register) name))))

;; Unregister a draw function
(fn M.unregister [name]
  (tset registry name nil)
  (let [redin-tbl (rawget _G :redin)]
    (when (and redin-tbl (rawget redin-tbl :canvas_unregister))
      ((rawget redin-tbl :canvas_unregister) name))))

;; Called by Odin during render phase. Returns command buffer.
(fn M._draw [name w h input]
  (let [draw-fn (. registry name)]
    (when draw-fn
      (let [ctx (build-ctx w h (or input {}))]
        (draw-fn ctx)
        ctx._buffer))))

;; Reset (for testing)
(fn M._reset []
  (set registry {}))

;; Global registration (called by init.fnl)
(fn M.register-globals []
  (set _G.redin_canvas_draw M._draw))

M
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `luajit test/lua/runner.lua test/lua/test_canvas.fnl`
Expected: All 10 tests PASS

- [ ] **Step 5: Commit**

```bash
git add src/runtime/canvas.fnl test/lua/test_canvas.fnl
git commit -m "feat: add canvas.fnl with ctx builder and drawing primitives"
```

---

### Task 2: Fennel canvas module — registry, input, dispatch

**Files:**
- Modify: `test/lua/test_canvas.fnl`
- Modify: `src/runtime/canvas.fnl` (already created in Task 1)

- [ ] **Step 1: Add failing tests for registry, input, and dispatch**

Append to `test/lua/test_canvas.fnl` (before the final `t`):

```fennel
;; --- registry ---

(fn t.test-register-stores-draw-fn []
  (setup)
  (var called false)
  (canvas.register :test-reg (fn [ctx] (set called true)))
  (canvas._draw :test-reg 100 100 {})
  (assert called "draw fn was called"))

(fn t.test-unregister-removes-draw-fn []
  (setup)
  (var called false)
  (canvas.register :test-unreg (fn [ctx] (set called true)))
  (canvas.unregister :test-unreg)
  (let [buf (canvas._draw :test-unreg 100 100 {})]
    (assert (= buf nil) "returns nil after unregister")
    (assert (not called) "draw fn not called")))

(fn t.test-draw-unknown-name-returns-nil []
  (setup)
  (let [buf (canvas._draw :nonexistent 100 100 {})]
    (assert (= buf nil) "nil for unknown")))

(fn t.test-fresh-buffer-per-call []
  (setup)
  (canvas.register :test-fresh
    (fn [ctx] (ctx.rect 0 0 10 10 {})))
  (let [buf1 (canvas._draw :test-fresh 100 100 {})
        buf2 (canvas._draw :test-fresh 100 100 {})]
    (assert (= (length buf1) 1) "first call has 1")
    (assert (= (length buf2) 1) "second call has 1")
    (assert (~= buf1 buf2) "different buffer objects")))

;; --- input queries ---

(fn t.test-ctx-mouse-position []
  (setup)
  (var mx nil)
  (var my nil)
  (canvas.register :test-mouse
    (fn [ctx]
      (set mx (ctx.mouse-x))
      (set my (ctx.mouse-y))))
  (canvas._draw :test-mouse 400 300
    {:mouse-x 150 :mouse-y 200})
  (assert (= mx 150) "mouse-x")
  (assert (= my 200) "mouse-y"))

(fn t.test-ctx-mouse-defaults-to-zero []
  (setup)
  (var mx nil)
  (canvas.register :test-mouse-default
    (fn [ctx] (set mx (ctx.mouse-x))))
  (canvas._draw :test-mouse-default 400 300 {})
  (assert (= mx 0) "defaults to 0"))

(fn t.test-ctx-mouse-in []
  (setup)
  (var inside nil)
  (canvas.register :test-mouse-in
    (fn [ctx] (set inside (ctx.mouse-in?))))
  (canvas._draw :test-mouse-in 400 300 {:mouse-in true})
  (assert (= inside true) "mouse is in"))

(fn t.test-ctx-mouse-buttons []
  (setup)
  (var down nil)
  (var pressed nil)
  (var released nil)
  (canvas.register :test-buttons
    (fn [ctx]
      (set down (ctx.mouse-down?))
      (set pressed (ctx.mouse-pressed?))
      (set released (ctx.mouse-released?))))
  (canvas._draw :test-buttons 400 300
    {:mouse-down {:left true :right false :middle false}
     :mouse-pressed {:left false :right false :middle false}
     :mouse-released {:left false :right false :middle false}})
  (assert (= down true) "left down")
  (assert (= pressed false) "not pressed")
  (assert (= released false) "not released"))

(fn t.test-ctx-mouse-button-right []
  (setup)
  (var right-down nil)
  (canvas.register :test-right
    (fn [ctx]
      (set right-down (ctx.mouse-down? :right))))
  (canvas._draw :test-right 400 300
    {:mouse-down {:left false :right true :middle false}})
  (assert (= right-down true) "right down"))

;; --- dispatch ---

(fn t.test-ctx-dispatch []
  (setup)
  (let [dispatched []]
    (set _G.dispatch (fn [event] (table.insert dispatched event)))
    (canvas.register :test-dispatch
      (fn [ctx]
        (ctx.dispatch [:test-event {:x 10}])))
    (canvas._draw :test-dispatch 400 300 {})
    (set _G.dispatch nil)
    (assert (= (length dispatched) 1) "one event dispatched")
    (assert (= (. (. dispatched 1) 1) :test-event) "event name")))
```

- [ ] **Step 2: Run tests to verify the new tests pass**

Run: `luajit test/lua/runner.lua test/lua/test_canvas.fnl`
Expected: All 20 tests PASS (implementation already in Task 1)

- [ ] **Step 3: Commit**

```bash
git add test/lua/test_canvas.fnl
git commit -m "test: add canvas registry, input query, and dispatch tests"
```

---

### Task 3: Wire canvas module into init.fnl

**Files:**
- Modify: `test/lua/test_canvas.fnl`
- Modify: `src/runtime/init.fnl:1-27`

- [ ] **Step 1: Add failing test for canvas globals**

Append to `test/lua/test_canvas.fnl` (before the final `t`):

```fennel
;; --- init wiring ---

(fn t.test-canvas-global-set-after-register-globals []
  (setup)
  (canvas.register-globals)
  (assert _G.redin_canvas_draw "redin_canvas_draw global exists")
  (set _G.redin_canvas_draw nil))
```

- [ ] **Step 2: Run test to verify it passes**

Run: `luajit test/lua/runner.lua test/lua/test_canvas.fnl`
Expected: PASS (`register-globals` already exists in canvas.fnl from Task 1)

- [ ] **Step 3: Wire canvas into init.fnl**

In `src/runtime/init.fnl`, add the canvas require and global registration:

```fennel
;; init.fnl -- Bootstrap sequence.
;; Loads all runtime modules, registers globals, wires up effect handler.

(local dataflow (require :dataflow))
(local effect (require :effect))
(local frame (require :frame))
(local theme (require :theme))
(local view (require :view))
(local canvas (require :canvas))

;; Register globals
(dataflow.register-globals)
(effect.register-globals)
(canvas.register-globals)

;; Wire effect handler: dataflow dispatch -> effect execute
(dataflow.set-effect-handler effect.execute)

;; Bridge-facing globals (called by Odin host each frame)
(set _G.redin_render_tick view.render-tick)
(set _G.redin_events view.deliver-events)

;; Export for host access
{:dataflow dataflow
 :effect effect
 :frame frame
 :theme theme
 :view view
 :canvas canvas}
```

- [ ] **Step 4: Run all Fennel tests**

Run: `luajit test/lua/runner.lua test/lua/test_*.fnl`
Expected: All tests pass (including existing tests unaffected)

- [ ] **Step 5: Commit**

```bash
git add src/runtime/init.fnl src/runtime/canvas.fnl test/lua/test_canvas.fnl
git commit -m "feat: wire canvas module into init.fnl"
```

---

### Task 4: Odin — canvas.odin current_name tracking

**Files:**
- Modify: `src/host/canvas/canvas.odin:25,51-69`

- [ ] **Step 1: Add current_name and set it in process**

Add a module-level `current_name` variable and set it at the start of `process`:

In `src/host/canvas/canvas.odin`, after line 25 (`entries: map[string]Canvas_Entry`), add:

```odin
current_name: string
```

In the `process` proc, add `current_name = provider_name` as the first line after the entry lookup:

```odin
process :: proc(provider_name: string, rect: rl.Rectangle) {
	entry, ok := &entries[provider_name]
	if !ok do return

	current_name = provider_name

	switch entry.lifecycle {
	case .Idle, .Suspended:
		if entry.provider.start != nil {
			entry.provider.start(rect)
		}
		entry.lifecycle = .Running
		if entry.provider.update != nil {
			entry.provider.update(rect)
		}
	case .Running:
		if entry.provider.update != nil {
			entry.provider.update(rect)
		}
	}
	entry.visited = true
}
```

- [ ] **Step 2: Commit**

```bash
git add src/host/canvas/canvas.odin
git commit -m "feat: track current_name in canvas.process for Fennel provider"
```

---

### Task 5: Odin bridge — host functions and generic provider

**Files:**
- Modify: `src/host/bridge/bridge.odin:1-13,44-53`

- [ ] **Step 1: Add canvas import to bridge.odin**

Add the import at the top of `bridge.odin`, after the existing imports (line 12):

```odin
import "../canvas"
```

- [ ] **Step 2: Add string_to_key reverse lookup**

Add this proc near the existing `key_to_string` at line 1137. Place it right after `key_to_string`:

```odin
string_to_key :: proc(name: string) -> rl.KeyboardKey {
	switch name {
	case "enter":     return .ENTER
	case "escape":    return .ESCAPE
	case "backspace": return .BACKSPACE
	case "tab":       return .TAB
	case "space":     return .SPACE
	case "up":        return .UP
	case "down":      return .DOWN
	case "left":      return .LEFT
	case "right":     return .RIGHT
	case "delete":    return .DELETE
	case "home":      return .HOME
	case "end":       return .END
	case "pageup":    return .PAGE_UP
	case "pagedown":  return .PAGE_DOWN
	case "insert":    return .INSERT
	case "f1":        return .F1
	case "f2":        return .F2
	case "f3":        return .F3
	case "f4":        return .F4
	case "f5":        return .F5
	case "f6":        return .F6
	case "f7":        return .F7
	case "f8":        return .F8
	case "f9":        return .F9
	case "f10":       return .F10
	case "f11":       return .F11
	case "f12":       return .F12
	case "a":         return .A
	case "b":         return .B
	case "c":         return .C
	case "d":         return .D
	case "e":         return .E
	case "f":         return .F
	case "g":         return .G
	case "h":         return .H
	case "i":         return .I
	case "j":         return .J
	case "k":         return .K
	case "l":         return .L
	case "m":         return .M
	case "n":         return .N
	case "o":         return .O
	case "p":         return .P
	case "q":         return .Q
	case "r":         return .R
	case "s":         return .S
	case "t":         return .T
	case "u":         return .U
	case "v":         return .V
	case "w":         return .W
	case "x":         return .X
	case "y":         return .Y
	case "z":         return .Z
	case "0":         return .ZERO
	case "1":         return .ONE
	case "2":         return .TWO
	case "3":         return .THREE
	case "4":         return .FOUR
	case "5":         return .FIVE
	case "6":         return .SIX
	case "7":         return .SEVEN
	case "8":         return .EIGHT
	case "9":         return .NINE
	case "shift":     return .LEFT_SHIFT
	case "ctrl":      return .LEFT_CONTROL
	case "alt":       return .LEFT_ALT
	case:             return .KEY_NULL
	}
}
```

- [ ] **Step 3: Add the generic Fennel canvas provider**

Add this after the host functions section (after `redin_http`, around line 242):

```odin
// ---------------------------------------------------------------------------
// Fennel canvas provider
// ---------------------------------------------------------------------------

fennel_canvas_update :: proc(rect: rl.Rectangle) {
	if g_bridge == nil do return
	lua_canvas_draw(g_bridge, canvas.current_name, rect)
}

fennel_canvas_provider := canvas.Canvas_Provider {
	start   = nil,
	update  = fennel_canvas_update,
	suspend = nil,
	stop    = nil,
}
```

- [ ] **Step 4: Add host function callbacks**

Add these after the generic provider:

```odin
// redin.canvas_register(name) — register a Fennel canvas provider
redin_canvas_register :: proc "c" (L: ^Lua_State) -> i32 {
	context = runtime.default_context()
	if lua_isstring(L, 1) {
		name := strings.clone_from_cstring(lua_tostring_raw(L, 1))
		canvas.register(name, fennel_canvas_provider)
	}
	return 0
}

// redin.canvas_unregister(name) — remove a Fennel canvas provider
redin_canvas_unregister :: proc "c" (L: ^Lua_State) -> i32 {
	context = runtime.default_context()
	if lua_isstring(L, 1) {
		name := string(lua_tostring_raw(L, 1))
		canvas.unregister(name)
	}
	return 0
}

// redin.key_down(key_name) — check if a key is currently held
redin_key_down :: proc "c" (L: ^Lua_State) -> i32 {
	context = runtime.default_context()
	if lua_isstring(L, 1) {
		key := string_to_key(string(lua_tostring_raw(L, 1)))
		lua_pushboolean(L, rl.IsKeyDown(key) ? 1 : 0)
	} else {
		lua_pushboolean(L, 0)
	}
	return 1
}

// redin.key_pressed(key_name) — check if a key was pressed this frame
redin_key_pressed :: proc "c" (L: ^Lua_State) -> i32 {
	context = runtime.default_context()
	if lua_isstring(L, 1) {
		key := string_to_key(string(lua_tostring_raw(L, 1)))
		lua_pushboolean(L, rl.IsKeyPressed(key) ? 1 : 0)
	} else {
		lua_pushboolean(L, 0)
	}
	return 1
}
```

- [ ] **Step 5: Register host functions in init**

In the `init` proc (around lines 44-53), add the new registrations before `lua_setglobal(b.L, "redin")`:

```odin
	register_cfunc(b.L, "canvas_register", redin_canvas_register)
	register_cfunc(b.L, "canvas_unregister", redin_canvas_unregister)
	register_cfunc(b.L, "key_down", redin_key_down)
	register_cfunc(b.L, "key_pressed", redin_key_pressed)
```

- [ ] **Step 6: Commit**

```bash
git add src/host/bridge/bridge.odin
git commit -m "feat: add canvas host functions and generic Fennel provider"
```

---

### Task 6: Odin bridge — lua_canvas_draw and command execution

**Files:**
- Modify: `src/host/bridge/bridge.odin`

- [ ] **Step 1: Add helper procs for reading command buffer data**

Add these near the other helper procs (after `register_cfunc` around line 1030):

```odin
// Read a number from a Lua table at integer index
lua_rawgeti_number :: proc(L: ^Lua_State, idx: i32, i: i32) -> f64 {
	lua_rawgeti(L, idx, i)
	defer lua_pop(L, 1)
	return lua_tonumber(L, -1)
}

// Read a color [r,g,b] or [r,g,b,a] from a table field. Returns ok=false if field missing.
read_color_field :: proc(L: ^Lua_State, idx: i32, field: cstring) -> (rl.Color, bool) {
	lua_getfield(L, idx, field)
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) do return {}, false

	color_idx := lua_gettop(L)
	r := u8(lua_rawgeti_number(L, color_idx, 1))
	g := u8(lua_rawgeti_number(L, color_idx, 2))
	b := u8(lua_rawgeti_number(L, color_idx, 3))

	lua_rawgeti(L, color_idx, 4)
	a := u8(255)
	if lua_isnumber(L, -1) {
		a = u8(lua_tonumber(L, -1))
	}
	lua_pop(L, 1)

	return rl.Color{r, g, b, a}, true
}

// Read a number field from a Lua table, default 0
read_number_field :: proc(L: ^Lua_State, idx: i32, field: cstring) -> f32 {
	lua_getfield(L, idx, field)
	defer lua_pop(L, 1)
	if lua_isnumber(L, -1) {
		return f32(lua_tonumber(L, -1))
	}
	return 0
}
```

- [ ] **Step 2: Add push_canvas_input_state**

Add this after the helpers:

```odin
// Push a {left=bool, right=bool, middle=bool} table for a mouse button query
push_mouse_buttons :: proc(L: ^Lua_State, parent_idx: i32, field: cstring, query: proc "c" (button: rl.MouseButton) -> bool) {
	lua_createtable(L, 0, 3)
	btn_idx := lua_gettop(L)
	lua_pushboolean(L, query(.LEFT) ? 1 : 0)
	lua_setfield(L, btn_idx, "left")
	lua_pushboolean(L, query(.RIGHT) ? 1 : 0)
	lua_setfield(L, btn_idx, "right")
	lua_pushboolean(L, query(.MIDDLE) ? 1 : 0)
	lua_setfield(L, btn_idx, "middle")
	lua_setfield(L, parent_idx, field)
}

// Build a Lua table with mouse state for canvas draw functions
push_canvas_input_state :: proc(L: ^Lua_State, rect: rl.Rectangle) {
	lua_createtable(L, 0, 6)
	input_idx := lua_gettop(L)

	// Mouse position relative to canvas
	mouse_pos := rl.GetMousePosition()
	lua_pushnumber(L, f64(mouse_pos.x - rect.x))
	lua_setfield(L, input_idx, "mouse-x")
	lua_pushnumber(L, f64(mouse_pos.y - rect.y))
	lua_setfield(L, input_idx, "mouse-y")

	// Mouse in bounds
	mouse_in := mouse_pos.x >= rect.x && mouse_pos.x <= rect.x + rect.width &&
	            mouse_pos.y >= rect.y && mouse_pos.y <= rect.y + rect.height
	lua_pushboolean(L, mouse_in ? 1 : 0)
	lua_setfield(L, input_idx, "mouse-in")

	push_mouse_buttons(L, input_idx, "mouse-down", rl.IsMouseButtonDown)
	push_mouse_buttons(L, input_idx, "mouse-pressed", rl.IsMouseButtonPressed)
	push_mouse_buttons(L, input_idx, "mouse-released", rl.IsMouseButtonReleased)
}
```

- [ ] **Step 3: Add lua_canvas_draw**

Add this after `push_canvas_input_state`:

```odin
// Call into Fennel canvas._draw, read command buffer, execute Raylib draws
lua_canvas_draw :: proc(b: ^Bridge, name: string, rect: rl.Rectangle) {
	L := b.L

	lua_getglobal(L, "redin_canvas_draw")
	if lua_isnil(L, -1) {
		lua_pop(L, 1)
		return
	}

	// Push args: name, width, height, input_state
	cname := strings.clone_to_cstring(name)
	defer delete(cname)
	lua_pushstring(L, cname)
	lua_pushnumber(L, f64(rect.width))
	lua_pushnumber(L, f64(rect.height))
	push_canvas_input_state(L, rect)

	if lua_pcall(L, 4, 1, 0) != 0 {
		msg := lua_tostring_raw(L, -1)
		fmt.eprintfln("Canvas draw error (%s): %s", name, msg)
		lua_pop(L, 1)
		return
	}

	// Execute command buffer
	if lua_istable(L, -1) {
		execute_canvas_commands(L, lua_gettop(L), rect)
	}
	lua_pop(L, 1)
}
```

- [ ] **Step 4: Add execute_canvas_commands and execute_canvas_command**

```odin
execute_canvas_commands :: proc(L: ^Lua_State, buf_idx: i32, rect: rl.Rectangle) {
	rl.BeginScissorMode(i32(rect.x), i32(rect.y), i32(rect.width), i32(rect.height))
	defer rl.EndScissorMode()

	n := i32(lua_objlen(L, buf_idx))
	for i: i32 = 1; i <= n; i += 1 {
		lua_rawgeti(L, buf_idx, i)
		if lua_istable(L, -1) {
			cmd_idx := lua_gettop(L)
			lua_rawgeti(L, cmd_idx, 1)
			if lua_isstring(L, -1) {
				tag := string(lua_tostring_raw(L, -1))
				execute_canvas_command(L, cmd_idx, tag, rect.x, rect.y)
			}
			lua_pop(L, 1) // pop tag
		}
		lua_pop(L, 1) // pop entry
	}
}

execute_canvas_command :: proc(L: ^Lua_State, idx: i32, tag: string, ox: f32, oy: f32) {
	switch tag {
	case "rect":
		x := f32(lua_rawgeti_number(L, idx, 2)) + ox
		y := f32(lua_rawgeti_number(L, idx, 3)) + oy
		w := f32(lua_rawgeti_number(L, idx, 4))
		h := f32(lua_rawgeti_number(L, idx, 5))
		lua_rawgeti(L, idx, 6)
		opts := lua_gettop(L)

		r := rl.Rectangle{x, y, w, h}
		radius := read_number_field(L, opts, "radius")

		if fill, ok := read_color_field(L, opts, "fill"); ok {
			if radius > 0 {
				roundness := radius / min(w, h) * 2
				rl.DrawRectangleRounded(r, roundness, 6, fill)
			} else {
				rl.DrawRectangleRec(r, fill)
			}
		}
		if stroke, ok := read_color_field(L, opts, "stroke"); ok {
			sw := read_number_field(L, opts, "stroke-width")
			if sw <= 0 do sw = 1
			if radius > 0 {
				roundness := radius / min(w, h) * 2
				rl.DrawRectangleRoundedLinesEx(r, roundness, 6, sw, stroke)
			} else {
				rl.DrawRectangleLinesEx(r, sw, stroke)
			}
		}
		lua_pop(L, 1)

	case "circle":
		cx := f32(lua_rawgeti_number(L, idx, 2)) + ox
		cy := f32(lua_rawgeti_number(L, idx, 3)) + oy
		cr := f32(lua_rawgeti_number(L, idx, 4))
		lua_rawgeti(L, idx, 5)
		opts := lua_gettop(L)

		if fill, ok := read_color_field(L, opts, "fill"); ok {
			rl.DrawCircleV({cx, cy}, cr, fill)
		}
		if stroke, ok := read_color_field(L, opts, "stroke"); ok {
			rl.DrawCircleLinesV({cx, cy}, cr, stroke)
		}
		lua_pop(L, 1)

	case "ellipse":
		cx := f32(lua_rawgeti_number(L, idx, 2)) + ox
		cy := f32(lua_rawgeti_number(L, idx, 3)) + oy
		rx := f32(lua_rawgeti_number(L, idx, 4))
		ry := f32(lua_rawgeti_number(L, idx, 5))
		lua_rawgeti(L, idx, 6)
		opts := lua_gettop(L)

		if fill, ok := read_color_field(L, opts, "fill"); ok {
			rl.DrawEllipse(i32(cx), i32(cy), rx, ry, fill)
		}
		if stroke, ok := read_color_field(L, opts, "stroke"); ok {
			rl.DrawEllipseLines(i32(cx), i32(cy), rx, ry, stroke)
		}
		lua_pop(L, 1)

	case "line":
		x1 := f32(lua_rawgeti_number(L, idx, 2)) + ox
		y1 := f32(lua_rawgeti_number(L, idx, 3)) + oy
		x2 := f32(lua_rawgeti_number(L, idx, 4)) + ox
		y2 := f32(lua_rawgeti_number(L, idx, 5)) + oy
		lua_rawgeti(L, idx, 6)
		opts := lua_gettop(L)

		stroke_color: rl.Color
		if s, ok := read_color_field(L, opts, "stroke"); ok {
			stroke_color = s
		} else {
			stroke_color = rl.BLACK
		}
		w := read_number_field(L, opts, "width")
		if w <= 0 do w = 1
		rl.DrawLineEx({x1, y1}, {x2, y2}, w, stroke_color)
		lua_pop(L, 1)

	case "text":
		x := f32(lua_rawgeti_number(L, idx, 2)) + ox
		y := f32(lua_rawgeti_number(L, idx, 3)) + oy
		lua_rawgeti(L, idx, 4)
		text := lua_tostring_raw(L, -1)
		lua_pop(L, 1)
		lua_rawgeti(L, idx, 5)
		opts := lua_gettop(L)

		size := read_number_field(L, opts, "size")
		if size <= 0 do size = 16
		text_color: rl.Color
		if c, ok := read_color_field(L, opts, "color"); ok {
			text_color = c
		} else {
			text_color = rl.BLACK
		}
		font_name := "sans"
		lua_getfield(L, opts, "font")
		if lua_isstring(L, -1) {
			font_name = string(lua_tostring_raw(L, -1))
		}
		lua_pop(L, 1)

		f := font.get(font_name, .Regular)
		spacing := max(size / 10, 1)
		rl.DrawTextEx(f, text, {x, y}, size, spacing, text_color)
		lua_pop(L, 1)

	case "polygon":
		lua_rawgeti(L, idx, 2)
		points_idx := lua_gettop(L)
		lua_rawgeti(L, idx, 3)
		opts := lua_gettop(L)

		if lua_istable(L, points_idx) {
			n_points := i32(lua_objlen(L, points_idx))
			if n_points >= 3 {
				points := make([]rl.Vector2, n_points)
				defer delete(points)
				for p: i32 = 1; p <= n_points; p += 1 {
					lua_rawgeti(L, points_idx, p)
					pt_idx := lua_gettop(L)
					points[p - 1] = {
						f32(lua_rawgeti_number(L, pt_idx, 1)) + ox,
						f32(lua_rawgeti_number(L, pt_idx, 2)) + oy,
					}
					lua_pop(L, 1)
				}

				if fill, ok := read_color_field(L, opts, "fill"); ok {
					for i: i32 = 1; i < n_points - 1; i += 1 {
						rl.DrawTriangle(points[0], points[i], points[i + 1], fill)
					}
				}
				if stroke, ok := read_color_field(L, opts, "stroke"); ok {
					for i: i32 = 0; i < n_points; i += 1 {
						next := (i + 1) % n_points
						rl.DrawLineV(points[i], points[next], stroke)
					}
				}
			}
		}
		lua_pop(L, 2)

	case "image":
		x := f32(lua_rawgeti_number(L, idx, 2)) + ox
		y := f32(lua_rawgeti_number(L, idx, 3)) + oy
		w := f32(lua_rawgeti_number(L, idx, 4))
		h := f32(lua_rawgeti_number(L, idx, 5))
		rl.DrawRectangleLinesEx({x, y, w, h}, 1, rl.GRAY)
		rl.DrawText("img", i32(x) + 2, i32(y) + 2, 12, rl.GRAY)
	}
}
```

- [ ] **Step 5: Commit**

```bash
git add src/host/bridge/bridge.odin
git commit -m "feat: add lua_canvas_draw and command buffer execution"
```

---

### Task 7: Build verification

**Files:** None new — verify existing changes compile

- [ ] **Step 1: Build the project**

Run: `odin build src/host -out:build/redin`
Expected: Build succeeds with no errors

- [ ] **Step 2: Fix any compilation errors**

If the build fails, read the error output, fix the issue, and rebuild. Common issues:
- Missing import: ensure `import "../canvas"` is in bridge.odin
- Type mismatches on `push_mouse_buttons` inner proc: ensure Raylib function signatures match
- String ownership: `strings.clone_from_cstring` for names that persist, `string(lua_tostring_raw(...))` for transient reads

- [ ] **Step 3: Run Fennel tests**

Run: `luajit test/lua/runner.lua test/lua/test_*.fnl`
Expected: All tests pass

- [ ] **Step 4: Commit if any fixes were needed**

```bash
git add -A
git commit -m "fix: resolve canvas build issues"
```

---

### Task 8: UI integration test

**Files:**
- Create: `test/ui/canvas_app.fnl`
- Create: `test/ui/test_canvas.bb`

- [ ] **Step 1: Create the canvas test app**

```fennel
;; test/ui/canvas_app.fnl
;; Minimal app exercising the Fennel canvas drawing API.

(local canvas (require :canvas))

(reg-handler :init
  (fn [db _]
    {:db (assoc db :click-count 0)}))

(reg-handler :canvas-click
  (fn [db event]
    {:db (update db :click-count (fn [n] (+ (or n 0) 1)))}))

(reg-sub :click-count
  (fn [db] (or (get db :click-count) 0)))

(canvas.register :test-canvas
  (fn [ctx]
    ;; Background
    (ctx.rect 0 0 ctx.width ctx.height {:fill [240 240 245]})
    ;; A red rectangle
    (ctx.rect 20 20 100 60 {:fill [220 50 50]})
    ;; A blue circle
    (ctx.circle 200 80 30 {:fill [50 80 220]})
    ;; A green line
    (ctx.line 10 150 290 150 {:stroke [50 180 50] :width 2})
    ;; Some text
    (let [count (subscribe :click-count)]
      (ctx.text 20 170 (.. "Clicks: " (tostring count)) {:size 18 :color [0 0 0]}))
    ;; Click detection
    (when (ctx.mouse-pressed?)
      (ctx.dispatch [:canvas-click]))))

(fn main-view []
  [:vbox {:width :full :height :full}
    [:text {} "Canvas Test"]
    [:canvas {:provider :test-canvas :width 300 :height 200}]])

(dispatch [:init])
```

- [ ] **Step 2: Create the UI test**

```clojure
;; test/ui/test_canvas.bb
(require '[babashka.http-client :as http])
(require '[cheshire.core :as json])
(load-file "test/ui/redin_test.bb")

(def base "http://localhost:8800")

(defn get-state [path]
  (-> (http/get (str base "/state/" path))
      :body
      (json/parse-string true)))

(defn get-frames []
  (-> (http/get (str base "/frames"))
      :body
      (json/parse-string true)))

(defn dispatch-event [event]
  (http/post (str base "/events")
    {:body (json/generate-string event)
     :headers {"Content-Type" "application/json"}}))

;; Test: canvas appears in frame tree
(redin-test/deftest test-canvas-in-frame
  (let [frames (get-frames)]
    (redin-test/assert-contains frames "canvas"
      "Frame tree contains a canvas node")))

;; Test: initial click count is 0
(redin-test/deftest test-initial-state
  (let [count (get-state "click-count")]
    (redin-test/assert-eq count 0
      "Initial click count is 0")))

;; Test: clicking canvas dispatches event
(redin-test/deftest test-canvas-click-dispatches
  ;; Click inside the canvas area
  (http/post (str base "/click")
    {:body (json/generate-string {:x 150 :y 150})
     :headers {"Content-Type" "application/json"}})
  (Thread/sleep 100)
  (let [count (get-state "click-count")]
    (redin-test/assert-true (> count 0)
      "Click count increased after canvas click")))

(redin-test/run-tests)
```

- [ ] **Step 3: Run the UI test**

Terminal 1:
```bash
./build/redin --dev test/ui/canvas_app.fnl &
sleep 1
```

Terminal 2:
```bash
bb test/ui/test_canvas.bb
```

Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add test/ui/canvas_app.fnl test/ui/test_canvas.bb
git commit -m "test: add canvas drawing API UI integration test"
```
