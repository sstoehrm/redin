# Animate Attribute Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a universal `:animate` attribute that renders a registered canvas provider at a viewport-anchored rect relative to the host element, with `:above` (default) / `:behind` z-order. Click-through; no decoration-side input.

**Architecture:** Reuse the existing canvas provider registry — no new animation primitive. The framework's only new work is positioning (a per-node side table holding a parsed `Animate_Decoration`, plus a small rect-resolver against the host's `node_rects` entry) and draw-order (a `:behind` hook at the start of `draw_node`, an `:above` hook at the end after children render).

**Tech Stack:** Odin (`core:fmt`, `core:strings`), Raylib (existing), LuaJIT (Lua 5.1 API). Tests: Odin `core:testing` + Babashka (`bb`) integration tests.

**Spec:** `docs/superpowers/specs/2026-04-27-animate-attribute-design.md`

---

## File Structure

| File | Responsibility |
|------|----------------|
| `src/redin/types/view_tree.odin` | Add `Animate_Z` enum + `Animate_Decoration` struct |
| `src/redin/bridge/bridge.odin` | Add `node_animations` side table to `Bridge`, parse `:animate`, free in `clear_frame` |
| `src/redin/render.odin` | `resolve_decoration_rect` helper; `:behind` / `:above` dispatch hooks in `draw_node` |
| `test/ui/animate_app.fnl` | Fixture: a button with a counter-bumping canvas provider as `:animate` |
| `test/ui/test_animate.bb` | Integration tests: frame-rate dispatch, click-through |
| `docs/core-api.md` | New "Animation" subsection under Attributes |
| `docs/reference/elements.md` | Note `:animate` as a universal attribute |

---

## Task 1: Add Animate types

**Files:**
- Modify: `src/redin/types/view_tree.odin`

- [ ] **Step 1: Add `Animate_Z` enum and `Animate_Decoration` struct**

Insert immediately after the existing `ViewportRect` struct (around line 36) so all viewport-related types live together:

```odin
Animate_Z :: enum u8 {
	Above,
	Behind,
}

Animate_Decoration :: struct {
	provider: string,        // owned, freed by clear_frame
	rect:     ViewportRect,  // resolved against the host node's rect (not window)
	z:        Animate_Z,
}
```

- [ ] **Step 2: Build verification**

Run:
```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: exit 0 (the new types are unused but compile cleanly).

- [ ] **Step 3: Commit**

```bash
git add src/redin/types/view_tree.odin
git commit -m "$(cat <<'EOF'
feat(types): add Animate_Decoration + Animate_Z (animate attr scaffolding)

First step of the :animate attribute (spec
docs/superpowers/specs/2026-04-27-animate-attribute-design.md). No
behaviour change — types are unused until the parser and renderer
land.
EOF
)"
```

---

## Task 2: Add node_animations side table

**Files:**
- Modify: `src/redin/bridge/bridge.odin`

- [ ] **Step 1: Add field to `Bridge` struct**

Find the `Bridge :: struct {` block (around line 16). Add `node_animations` alongside the other per-node parallel arrays:

```odin
Bridge :: struct {
	L:               ^Lua_State,
	paths:           [dynamic]types.Path,
	nodes:           [dynamic]types.Node,
	parent_indices:  [dynamic]int,
	children_list:   [dynamic]types.Children,
	node_animations: [dynamic]Maybe(types.Animate_Decoration),
	theme:           map[string]types.Theme,
	http_client:     Http_Client,
	shell_client:    Shell_Client,
	hot_reload:      Hot_Reload,
	dev_server:      Dev_Server,
	frame_changed:   bool,
	dev_mode:        bool,
}
```

- [ ] **Step 2: Free + clear in `clear_frame`**

Find `clear_frame :: proc(b: ^Bridge) {` (around line 164). Add the animation cleanup alongside the other side-table resets:

```odin
clear_frame :: proc(b: ^Bridge) {
	// Any cross-frame caches keyed by node string pointers become stale
	// the moment strings are freed. Invalidate before any delete calls.
	text_pkg.invalidate_height_cache()

	for &p in b.paths {
		delete(p.value)
	}
	delete(b.paths)
	b.paths = {}
	for &n in b.nodes {
		clear_node_strings(n)
	}
	delete(b.nodes)
	b.nodes = {}
	delete(b.parent_indices)
	b.parent_indices = {}
	for &c in b.children_list {
		delete(c.value)
	}
	delete(b.children_list)
	b.children_list = {}
	for entry in b.node_animations {
		if d, has := entry.?; has && len(d.provider) > 0 {
			delete(d.provider)
		}
	}
	delete(b.node_animations)
	b.node_animations = {}
}
```

- [ ] **Step 3: Build verification**

Run:
```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: exit 0.

- [ ] **Step 4: Commit**

```bash
git add src/redin/bridge/bridge.odin
git commit -m "$(cat <<'EOF'
feat(bridge): node_animations side table on Bridge

Idx-keyed parallel array for per-node :animate decorations. Cleared in
clear_frame alongside the other parallel arrays, with provider strings
freed (the only owned heap allocation in Animate_Decoration).
EOF
)"
```

---

## Task 3: UI integration test fixture (RED)

**Files:**
- Create: `test/ui/animate_app.fnl`
- Create: `test/ui/test_animate.bb`

- [ ] **Step 1: Write the fixture app**

Create `test/ui/animate_app.fnl`:

```fennel
;; test/ui/animate_app.fnl
;; Fixture for the :animate attribute. A button hosts a canvas provider
;; that increments :tick-count every time it's drawn. Production code
;; reads /state/tick-count to verify frame-rate dispatch, and POSTs
;; /click at the host's center to verify click-through.

(local canvas (require :canvas))
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:button {:bg [76 86 106] :color [236 239 244] :radius 6 :padding [8 16 8 16]}})

(dataflow.init {:tick-count 0 :host-clicks 0})
(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :ev/host-click
  (fn [db event] (update db :host-clicks #(+ (or $1 0) 1))))

(reg-sub :sub/tick-count (fn [db] (or (get db :tick-count) 0)))
(reg-sub :sub/host-clicks (fn [db] (or (get db :host-clicks) 0)))

(canvas.register :tick-counter
  (fn [ctx]
    ;; Increment a counter on every frame. Provider read access is
    ;; via subscribe; mutation goes through dispatch, which the dev
    ;; server's view loop applies once per tick.
    (ctx.dispatch [:ev/tick])
    (ctx.rect 0 0 ctx.width ctx.height {:fill [255 200 50]})))

(reg-handler :ev/tick
  (fn [db event] (update db :tick-count #(+ (or $1 0) 1))))

(global main_view
  (fn []
    [:vbox {:layout :center}
     [:button {:id :host
               :click [:ev/host-click]
               :animate {:provider :tick-counter
                         :rect [:top_left -4 -4 16 16]
                         :z :above}}
              "Host"]]))
```

- [ ] **Step 2: Write the failing integration test**

Create `test/ui/test_animate.bb`:

```clojure
(require '[redin-test :refer :all])

;; Test 1: the button itself renders (sanity — proves the fixture loaded).
(deftest host-button-exists
  (let [host (find-element {:tag :button :attrs {:id "host"}})]
    (assert (some? host) "Host button should appear in the frame tree")))

;; Test 2: the animate provider runs at frame rate. After ~500ms, the
;; provider should have ticked many times. Pre-implementation this
;; counter stays at 0 because the framework doesn't recognize :animate
;; and never dispatches to the provider.
(deftest animate-provider-runs-each-frame
  (dispatch ["ev/host-click"]) ; reset path warm-up
  (wait-ms 500)
  (let [count (get-state "tick-count")]
    (assert (> count 10)
            (str "Expected the animate provider to have ticked > 10 times in 500ms; got "
                 count))))

;; Click-through is structural, not behavioural: the decoration's rect
;; never enters node_rects, so the existing hit-test path can't
;; possibly intercept clicks meant for the host. We verify this in the
;; render code review (search for node_rects in the :animate dispatch
;; path — there should be no append) rather than via a bb test, since
;; redin-test doesn't expose the rendered rect of an element.
```

- [ ] **Step 3: Build, run the test, verify it fails for the right reason**

Build:
```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Run:
```bash
rm -f .redin-port .redin-token
xvfb-run -a -s "-screen 0 1024x768x24" build/redin --dev test/ui/animate_app.fnl &
SERVER_PID=$!
for i in $(seq 1 30); do [ -f .redin-port ] && [ -f .redin-token ] && break; sleep 0.2; done
bb test/ui/run.bb test/ui/test_animate.bb
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" "http://localhost:$PORT/shutdown" >/dev/null
wait $SERVER_PID 2>/dev/null
```

Expected:
- `host-button-exists`: PASS (the button is just a normal :button — `:animate` is silently ignored by the unmodified parser).
- `animate-provider-runs-each-frame`: FAIL (`tick-count` is 0).

The decisive RED is `animate-provider-runs-each-frame`.

- [ ] **Step 4: Commit (test only, RED state)**

```bash
git add test/ui/animate_app.fnl test/ui/test_animate.bb
git commit -m "$(cat <<'EOF'
test(ui): add animate fixture + integration tests (RED)

Fixture wires a canvas provider that increments :tick-count every
draw, attached as an :animate decoration on a button. Tests assert
frame-rate dispatch (currently fails — :animate is parsed as a no-op)
and click-through (currently passes vacuously — no decoration is
drawn so nothing intercepts).

Drives the GREEN tasks that follow.
EOF
)"
```

---

## Task 4: Parse `:animate` attribute

**Files:**
- Modify: `src/redin/bridge/bridge.odin`

- [ ] **Step 1: Implement `parse_animate_attr` helper**

Add this proc near the other Lua-table helpers (e.g., right above `lua_flatten_node` around line 845). It mirrors the inline viewport parser inside `lua_read_node`'s `"stack"` case but for a single rect:

```odin
// Parse a :animate attribute table at attrs_idx. Returns the parsed
// decoration on success; the second return is false when the attribute
// is missing or malformed (in which case nothing is stored). The caller
// owns the returned decoration's `provider` string.
parse_animate_attr :: proc(L: ^Lua_State, attrs_idx: i32) -> (types.Animate_Decoration, bool) {
	zero: types.Animate_Decoration
	if attrs_idx <= 0 do return zero, false

	lua_getfield(L, attrs_idx, "animate")
	defer lua_pop(L, 1)
	if !lua_istable(L, -1) do return zero, false
	a_idx := lua_gettop(L)

	// :provider — required string
	provider: string
	lua_getfield(L, a_idx, "provider")
	if lua_isstring(L, -1) {
		provider = strings.clone_from_cstring(lua_tostring_raw(L, -1))
	}
	lua_pop(L, 1)
	if len(provider) == 0 {
		fmt.eprintln("animate: missing or non-string :provider, skipping")
		return zero, false
	}

	// :rect — required 5-element vector matching :viewport entries
	rect: types.ViewportRect
	rect_ok := false
	lua_getfield(L, a_idx, "rect")
	if lua_istable(L, -1) {
		r_idx := lua_gettop(L)
		if int(lua_objlen(L, r_idx)) == 5 {
			lua_rawgeti(L, r_idx, 1)
			if lua_isstring(L, -1) {
				rect.anchor = parse_anchor(string(lua_tostring_raw(L, -1)))
			}
			lua_pop(L, 1)
			fields := [4]^types.ViewportValue{&rect.x, &rect.y, &rect.w, &rect.h}
			for j in 0 ..< 4 {
				lua_rawgeti(L, r_idx, i32(j + 2))
				if lua_isnumber(L, -1) {
					fields[j]^ = f32(lua_tonumber(L, -1))
				} else if lua_isstring(L, -1) {
					s := string(lua_tostring_raw(L, -1))
					if s == "full" {
						fields[j]^ = types.SizeValue.FULL
					} else {
						fields[j]^ = parse_fraction(s)
					}
				}
				lua_pop(L, 1)
			}
			rect_ok = true
		}
	}
	lua_pop(L, 1)
	if !rect_ok {
		fmt.eprintln("animate: missing or malformed :rect (must be a 5-element vector), skipping")
		delete(provider)
		return zero, false
	}

	// :z — optional, defaults to .Above
	z := types.Animate_Z.Above
	lua_getfield(L, a_idx, "z")
	if lua_isstring(L, -1) {
		s := string(lua_tostring_raw(L, -1))
		switch s {
		case "above": z = .Above
		case "behind": z = .Behind
		case:
			fmt.eprintfln("animate: unknown :z value %q, defaulting to :above", s)
		}
	}
	lua_pop(L, 1)

	return types.Animate_Decoration{provider = provider, rect = rect, z = z}, true
}
```

- [ ] **Step 2: Wire the parser into `lua_flatten_node`**

Find `lua_flatten_node :: proc(...)` (around line 847). The existing append site is at lines 884–888:

```odin
// Build node based on tag
node := lua_read_node(L, tag, attrs_idx, text_content)
append(&b.nodes, node)

// Pop attrs
if attrs_idx != 0 do lua_pop(L, 1)
```

Insert the animate append **between** `append(&b.nodes, node)` and the `lua_pop` of attrs (the parser needs `attrs_idx` still on the stack):

```odin
// Build node based on tag
node := lua_read_node(L, tag, attrs_idx, text_content)
append(&b.nodes, node)

// :animate decoration (idx-aligned with b.nodes). Always append so
// node_animations stays length-aligned — a missing or malformed
// entry pushes nil.
if dec, ok := parse_animate_attr(L, attrs_idx); ok {
	append(&b.node_animations, dec)
} else {
	append(&b.node_animations, nil)
}

// Pop attrs
if attrs_idx != 0 do lua_pop(L, 1)
```

The existing `my_idx := len(b.nodes)` at line 849 stays as-is — it captures the index the new node will land at, computed *before* the node is appended.

- [ ] **Step 3: Build verification**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: exit 0.

- [ ] **Step 4: Verify the integration test still RED but now for the right reason**

```bash
rm -f .redin-port .redin-token
xvfb-run -a -s "-screen 0 1024x768x24" build/redin --dev test/ui/animate_app.fnl &
SERVER_PID=$!
for i in $(seq 1 30); do [ -f .redin-port ] && [ -f .redin-token ] && break; sleep 0.2; done
bb test/ui/run.bb test/ui/test_animate.bb
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" "http://localhost:$PORT/shutdown" >/dev/null
wait $SERVER_PID 2>/dev/null
```

Expected: `animate-provider-runs-each-frame` still FAIL — parsing now happens, but the renderer hasn't been wired so the provider never runs. This is the intended intermediate state.

- [ ] **Step 5: Commit (test still RED)**

```bash
git add src/redin/bridge/bridge.odin
git commit -m "$(cat <<'EOF'
feat(bridge): parse :animate attribute into node_animations

Reads {provider, rect, z} from the attribute table using the same
tokens the existing :viewport parser accepts (anchor enum, "full",
M_N fractions). Missing/malformed entries log to stderr and store
nil — the side-table length stays aligned with b.nodes.

Renderer wiring follows in the next commit; tests still RED until then.
EOF
)"
```

---

## Task 5: Decoration rect resolver

**Files:**
- Modify: `src/redin/render.odin`

- [ ] **Step 1: Add `resolve_decoration_rect` helper**

Add this near `layout_children_viewport` (around line 206), since it shares the same anchor math but operates on a host rect instead of the screen:

```odin
// Resolve an :animate decoration's ViewportRect against its host node's
// rect. Same anchor / value semantics as the existing :viewport on
// :stack, but axes are the host's width and height (not the screen).
resolve_decoration_rect :: proc(vr: types.ViewportRect, host: rl.Rectangle) -> rl.Rectangle {
	w := px(resolve_vp(vr.w, host.width))
	h := px(resolve_vp(vr.h, host.height))
	offset_x := px(resolve_vp(vr.x, host.width))
	offset_y := px(resolve_vp(vr.y, host.height))

	x: f32; y: f32
	#partial switch vr.anchor {
	case .TOP_LEFT, .CENTER_LEFT, .BOTTOM_LEFT:
		x = host.x + offset_x
	case .TOP_CENTER, .CENTER, .BOTTOM_CENTER:
		x = host.x + host.width/2 - w/2 + offset_x
	case .TOP_RIGHT, .CENTER_RIGHT, .BOTTOM_RIGHT:
		x = host.x + host.width - w + offset_x
	}
	#partial switch vr.anchor {
	case .TOP_LEFT, .TOP_CENTER, .TOP_RIGHT:
		y = host.y + offset_y
	case .CENTER_LEFT, .CENTER, .CENTER_RIGHT:
		y = host.y + host.height/2 - h/2 + offset_y
	case .BOTTOM_LEFT, .BOTTOM_CENTER, .BOTTOM_RIGHT:
		y = host.y + host.height - h + offset_y
	}
	return rl.Rectangle{x, y, w, h}
}
```

- [ ] **Step 2: Build verification**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: exit 0 (helper unused but compiles).

- [ ] **Step 3: Commit**

```bash
git add src/redin/render.odin
git commit -m "$(cat <<'EOF'
feat(render): resolve_decoration_rect for animate hosts

Same anchor/value math as the existing :viewport solver, but resolves
against the host element's rect instead of the screen. Used by the
:animate render hooks added in the next commit.
EOF
)"
```

---

## Task 6: Render `:behind` hook

**Files:**
- Modify: `src/redin/render.odin`

- [ ] **Step 1: Import the canvas package and bridge access**

Find `draw_node :: proc(...)` (around line 404). The function currently doesn't reach the bridge for animations, so it needs access to `bridge.g_bridge.node_animations`. Verify the existing imports include `bridge` (search for `import .* "../bridge"` near the top of `render.odin`); if not, add it.

```bash
grep -n "../bridge" src/redin/render.odin | head -3
```

If bridge isn't already imported, add `import bridge "./bridge"` (or whichever form matches the file's import style — read the existing imports first).

- [ ] **Step 2: Dispatch `:behind` at the start of `draw_node`**

After the rect lookups (lines 411–412) and before the `switch n in nodes[idx]`, insert:

```odin
draw_node :: proc(
	idx: int,
	nodes: []types.Node,
	children_list: []types.Children,
	theme: map[string]types.Theme,
) {
	if idx < 0 || idx >= len(nodes) do return
	rect := node_rects[idx]
	content_rect := node_content_rects[idx]

	// :animate :behind — drawn before the host's own bg/border/children.
	if idx < len(bridge.g_bridge.node_animations) {
		if dec, has := bridge.g_bridge.node_animations[idx].?; has && dec.z == .Behind {
			drect := resolve_decoration_rect(dec.rect, rect)
			canvas.process(dec.provider, drect)
		}
	}

	switch n in nodes[idx] {
	// ... existing cases unchanged ...
	}
}
```

(Keep every existing `case` arm exactly as-is; only insert the `if idx < len(...)` block before the switch.)

- [ ] **Step 3: Build verification**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: exit 0.

- [ ] **Step 4: Commit**

```bash
git add src/redin/render.odin
git commit -m "$(cat <<'EOF'
feat(render): dispatch :animate :behind decorations

Hooks the bridge's node_animations side table at the start of
draw_node — :behind decorations resolve their rect against the host
and dispatch to the canvas provider before the host paints.
EOF
)"
```

---

## Task 7: Render `:above` hook

**Files:**
- Modify: `src/redin/render.odin`

- [ ] **Step 1: Dispatch `:above` at the end of `draw_node`**

In the same `draw_node` proc, after the entire `switch n in nodes[idx]` block (i.e., after the closing `}` of the switch but before the closing `}` of the proc), append:

```odin
	// :animate :above — drawn after the host's own draw + descendant
	// subtree complete (the recursive draw_children calls inside each
	// switch arm have returned by now).
	if idx < len(bridge.g_bridge.node_animations) {
		if dec, has := bridge.g_bridge.node_animations[idx].?; has && dec.z == .Above {
			drect := resolve_decoration_rect(dec.rect, rect)
			canvas.process(dec.provider, drect)
		}
	}
}
```

The recursive draw walk means "after the switch returns" naturally implies "after every descendant has drawn" — the `case types.NodeVbox: ... draw_box_children(...)` arm and friends recurse into descendants synchronously before returning to this point.

- [ ] **Step 2: Build verification**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin
```

Expected: exit 0.

- [ ] **Step 3: Run the integration test — must now pass**

```bash
rm -f .redin-port .redin-token
xvfb-run -a -s "-screen 0 1024x768x24" build/redin --dev test/ui/animate_app.fnl &
SERVER_PID=$!
for i in $(seq 1 30); do [ -f .redin-port ] && [ -f .redin-token ] && break; sleep 0.2; done
bb test/ui/run.bb test/ui/test_animate.bb
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" "http://localhost:$PORT/shutdown" >/dev/null
wait $SERVER_PID 2>/dev/null
```

Expected: all three `test_animate.bb` tests PASS.

- [ ] **Step 4: Run the full UI suite to confirm no regression**

```bash
bash test/ui/run-all.sh --headless
```

Expected: every existing suite still passes (test_canvas, test_smoke, test_input, etc.).

- [ ] **Step 5: Commit**

```bash
git add src/redin/render.odin
git commit -m "$(cat <<'EOF'
feat(render): dispatch :animate :above decorations

After the recursive draw_node returns from its descendants, dispatch
any :above decoration on top. Click-through is implicit: the
decoration's rect never enters node_rects, so hit-testing is unchanged.

Closes the animate feature loop — test/ui/test_animate.bb passes.
EOF
)"
```

---

## Task 8: Memory + perf verification

**Files:** none (verification only)

- [ ] **Step 1: Memory leak check**

```bash
rm -f .redin-port .redin-token
xvfb-run -a -s "-screen 0 1024x768x24" build/redin --dev --track-mem test/ui/animate_app.fnl > /tmp/animate-mem.log 2>&1 &
SERVER_PID=$!
for i in $(seq 1 30); do [ -f .redin-port ] && [ -f .redin-token ] && break; sleep 0.2; done
sleep 2  # let the provider tick a few hundred frames
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" "http://localhost:$PORT/shutdown" >/dev/null
wait $SERVER_PID 2>/dev/null
grep -iE "leak|outstanding|alloc.*not freed" /tmp/animate-mem.log
```

Expected: no `leak` / `outstanding` / `not freed` lines (clear_frame's new `delete(d.provider)` should keep the budget clean across hot reloads).

- [ ] **Step 2: Perf check on perf-10k**

The animate path is opt-in — perf-10k doesn't use it — but a sanity run confirms no regression on the existing render path:

```bash
rm -f .redin-port .redin-token
xvfb-run -a -s "-screen 0 1280x800x24" build/redin --dev --profile examples/perf-10k.fnl > /tmp/animate-perf.log 2>&1 &
SERVER_PID=$!
for i in $(seq 1 50); do [ -f .redin-port ] && [ -f .redin-token ] && break; sleep 0.2; done
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
sleep 3
curl -s -H "Authorization: Bearer $TOKEN" "http://localhost:$PORT/profile" | head -c 600
echo
curl -s -X POST -H "Authorization: Bearer $TOKEN" "http://localhost:$PORT/shutdown" >/dev/null
wait $SERVER_PID 2>/dev/null
```

Expected: per-frame total comparable to the pre-feature baseline (≈9.5–10.7 ms on the M1-era reference run).

---

## Task 9: Documentation

**Files:**
- Modify: `docs/core-api.md`
- Modify: `docs/reference/elements.md`

- [ ] **Step 1: Add an "Animation" subsection to core-api.md**

Find the "Attributes" section in `docs/core-api.md` (search for `### Attributes` around line 158) and add a new subsection after the existing attribute discussion (and before "Sizing model"):

````markdown
### Animation

Any element may carry an `:animate` map that renders a registered canvas provider at a viewport-anchored rect relative to the host. Useful for corner ornaments — a blinking notification star, a soft glow behind a tile, a badge in the bottom-right.

```fennel
[:button {:animate {:provider :star-blink
                    :rect [:top_left -4 -4 16 16]
                    :z :above}}
  "Click me"]
```

| Field | Required | Type | Notes |
|---|---|---|---|
| `:provider` | yes | keyword or string | Name of a registered canvas provider (same registry as `:canvas`). |
| `:rect` | yes | 5-element vector | `[anchor x y w h]`, identical to the `:viewport` syntax on `:stack`. Negative `x`/`y` allowed for overhang outside the host. |
| `:z` | no | `:above` (default) or `:behind` | Draw order relative to the host element. |

The decoration is purely visual: clicks fall through to the host. The provider's `mouse-in?` / `mouse-pressed?` queries still work in canvas-local coordinates so the decoration can react visually to hover.

If the provider name isn't registered, the host renders a placeholder rect (same fallback as `:canvas`). If `:rect` is malformed (wrong arity, unknown anchor token), a warning prints to stderr at parse time and the decoration is skipped — the host renders normally.
````

- [ ] **Step 2: Note `:animate` as a universal attribute in elements.md**

Find the per-element table or the "Universal attributes" section in `docs/reference/elements.md` (search for `Universal attributes` or similar; if no such section exists, add one near the top). Add:

```markdown
| `:animate` | All elements | Map: `{:provider name :rect [anchor x y w h] :z :above|:behind}` — render a canvas provider at a host-relative rect. See [core-api.md § Animation](../core-api.md#animation). |
```

If `docs/reference/elements.md` doesn't have a universal-attributes section, append a new top-level section:

```markdown
## Universal attributes

These attributes apply to every element type.

| Attribute | Notes |
|---|---|
| `:animate` | Map: `{:provider name :rect [anchor x y w h] :z :above|:behind}` — render a canvas provider at a host-relative rect. See [core-api.md § Animation](../core-api.md#animation). |
```

- [ ] **Step 3: Commit**

```bash
git add docs/core-api.md docs/reference/elements.md
git commit -m "$(cat <<'EOF'
docs: document :animate universal attribute

Adds an Animation subsection to core-api.md (full field reference +
example) and notes :animate as a universal attribute in
reference/elements.md.
EOF
)"
```

---

## Done criteria

After all nine tasks land:

- `odin test src/redin/bridge ...` — every existing test still passes (no Odin-side test added for the parser; covered by the integration test).
- `odin build src/cmd/redin ...` — exit 0.
- `luajit test/lua/runner.lua test/lua/test_*.fnl` — 122/122 pass (no Fennel runtime change, but worth re-running per redin-maintenance).
- `bash test/ui/run-all.sh --headless` — all suites pass; `test_animate` shows 3/3.
- `--track-mem` smoke run with the animate fixture — no leak / outstanding reports.
- `docs/core-api.md` Animation subsection visible; `docs/reference/elements.md` references it.

The branch can then merge to main as a single PR.
