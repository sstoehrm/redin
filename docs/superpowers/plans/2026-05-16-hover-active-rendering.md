# Hover/Active rendering implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the half-built `aspect#hover` and `aspect#active` theme state variants end-to-end so the documented behaviour actually renders.

**Architecture:** Track `hovered_indices: [dynamic]int` (set) and `active_idx: int` as package-level state in `src/redin/input`, populated by the existing event/listener flow. Introduce a single `resolve_themed_aspect(idx, aspect, theme)` helper in `src/redin/render.odin` that merges base + `#focus` + `#hover` + `#active` and is called from every aspect lookup site in the four draw procs. The drag-preview draw paths bypass state overlays by passing `idx = -1`.

**Tech Stack:** Odin + Raylib (render, input), Fennel/Lua (test fixture), Babashka (UI integration test). Existing tooling: `./build-dev.sh`, `bb test/ui/run.bb`, dev-server `/input/*` endpoints for mouse takeover.

**Spec:** `docs/superpowers/specs/2026-05-16-hover-active-rendering-design.md`

---

## File map

| Path                                   | Action  | Responsibility                                                                              |
|----------------------------------------|---------|---------------------------------------------------------------------------------------------|
| `test/ui/hover_active_app.fnl`         | Create  | Single-button fixture app with distinct base/hover/active bg colours for pixel sampling.    |
| `test/ui/test_hover_active.bb`         | Create  | Babashka integration test: mouse takeover, press/move/release, screenshot pixel asserts.    |
| `test/ui/redin_test.bb`                | Modify  | Add `screenshot-pixel` helper (PNG → RGB at coordinate).                                    |
| `src/redin/input/input.odin`           | Modify  | Add `hovered_indices` + `active_idx` package vars.                                          |
| `src/redin/input/user_events.odin`     | Modify  | Populate `hovered_indices` in the existing hover-listener loop.                             |
| `src/redin/input/apply.odin`           | Modify  | Set `active_idx` on press; clear via `is_mouse_button_down` poll; drop `ApplyActive` emit.  |
| `src/redin/types/apply_events.odin`    | Modify  | Delete `ApplyActive` struct + union case.                                                   |
| `src/redin/runtime.odin`               | Modify  | Drop empty `case types.ApplyActive:` line.                                                  |
| `src/redin/render.odin`                | Modify  | Add `resolve_themed_aspect`; thread `idx` into `draw_button`/`draw_themed_rect`; route 4 draw procs through helper; drag-preview paths pass `idx = -1`. |

---

### Task 1: Failing UI integration test

**Files:**
- Create: `test/ui/hover_active_app.fnl`
- Create: `test/ui/test_hover_active.bb`
- Modify: `test/ui/redin_test.bb` (add `screenshot-pixel` helper)

- [ ] **Step 1: Add `screenshot-pixel` helper to `test/ui/redin_test.bb`**

Insert the following after the existing `screenshot-dims` function (after the closing `]` at the end of `screenshot-dims`, before `wait-ms`):

```clojure
(defn screenshot-pixel
  "Read RGB at (x,y) from PNG bytes. Returns [r g b]. Uses javax.imageio
   (Babashka built-in) so no external dependency. Coordinates are in
   PNG pixels, matching raylib's framebuffer dimensions."
  [^bytes png-bytes x y]
  (let [bais (java.io.ByteArrayInputStream. png-bytes)
        img  (javax.imageio.ImageIO/read bais)]
    (when (nil? img)
      (throw (ex-info "could not decode screenshot PNG" {})))
    (let [argb (.getRGB img (int x) (int y))
          r (bit-and (bit-shift-right argb 16) 0xff)
          g (bit-and (bit-shift-right argb 8) 0xff)
          b (bit-and argb 0xff)]
      [r g b])))
```

- [ ] **Step 2: Create the fixture app `test/ui/hover_active_app.fnl`**

```fennel
;; Hover/active state-variant test fixture.
;;
;; One themed button at a fixed-size rect. Distinct, easy-to-recognise
;; bg colours per state so the test can pixel-sample and compare exactly:
;;   base   = [50 50 50]     (dark grey)
;;   hover  = [100 100 100]  (mid grey)
;;   active = [200 200 200]  (light grey)
;;
;; No corner radius, no shadow — solid rect makes pixel sampling stable.

(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme {:bg-fill {:bg [0 0 0]}
                      :btn         {:bg [50 50 50]
                                    :color [255 255 255]
                                    :radius 0
                                    :padding [0 0 0 0]
                                    :font-size 14}
                      :btn#hover   {:bg [100 100 100]}
                      :btn#active  {:bg [200 200 200]}})

(dataflow.init {:clicks 0})

(reg-handler :test/click
             (fn [db event]
               (update db :clicks #(+  1))))

(reg-sub :clicks (fn [db] (get db :clicks 0)))

(global main_view
        (fn []
          [:stack
           {:viewport [[:top_left 0 0 :full :full]]}
           ;; Solid black background fill so anything outside the button
           ;; is obviously not the button.
           [:vbox {:aspect :bg-fill :width :full :height :full}
            [:button {:aspect :btn
                      :width 100
                      :height 40
                      :click [:test/click]}
             ""]]]))
```

- [ ] **Step 3: Create the integration test `test/ui/test_hover_active.bb`**

```clojure
(require '[redin-test :refer :all])

;; ---------------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------------

(defn- btn-rect []
  (rect-of (find-element {:tag :button :aspect :btn})))

(defn- sample-bg
  "Sample a pixel from the screenshot at a bg-only point inside the button
   (4px in from the top-left corner — clear of any glyph footprint)."
  []
  (let [{:keys [x y]} (btn-rect)
        png (screenshot)]
    (screenshot-pixel png (+ x 4) (+ y 4))))

(defn- center-of
  "Return [cx cy] for the button rect's center."
  []
  (let [{:keys [x y w h]} (btn-rect)]
    [(int (+ x (/ w 2))) (int (+ y (/ h 2)))]))

;; ---------------------------------------------------------------------------
;; Tests
;; ---------------------------------------------------------------------------

(deftest button-rect-exists
  (assert (some? (btn-rect)) "Button rect should be present in /frames"))

(deftest base-color-resting
  ;; Cursor at default position (outside the button). Bg should be base.
  (input-takeover)
  (input-mouse-move 0 0)
  (wait-ms 100)
  (let [[r g b] (sample-bg)]
    (assert (= [r g b] [50 50 50])
            (str "Expected base color [50 50 50], got " [r g b])))
  (input-release))

(deftest hover-color-on-cursor-over
  (input-takeover)
  (let [[cx cy] (center-of)]
    (input-mouse-move cx cy)
    (wait-ms 100)
    (let [[r g b] (sample-bg)]
      (assert (= [r g b] [100 100 100])
              (str "Expected hover color [100 100 100], got " [r g b]))))
  (input-release))

(deftest active-color-on-mouse-down
  (input-takeover)
  (let [[cx cy] (center-of)]
    (input-mouse-move cx cy)
    (wait-ms 100)
    (input-mouse-down :left)
    (wait-ms 100)
    (let [[r g b] (sample-bg)]
      (assert (= [r g b] [200 200 200])
              (str "Expected active color [200 200 200], got " [r g b])))
    (input-mouse-up :left))
  (input-release))

(deftest active-persists-when-cursor-drags-off
  ;; CSS-like semantics: pressed button stays active until mouseup,
  ;; even when the cursor leaves the rect while still held.
  (input-takeover)
  (let [[cx cy] (center-of)]
    (input-mouse-move cx cy)
    (wait-ms 100)
    (input-mouse-down :left)
    (wait-ms 100)
    (input-mouse-move 0 0)
    (wait-ms 100)
    (let [[r g b] (sample-bg)]
      (assert (= [r g b] [200 200 200])
              (str "Active should persist while held; got " [r g b])))
    (input-mouse-up :left))
  (input-release))

(deftest base-restored-after-mouseup-off-rect
  (input-takeover)
  (let [[cx cy] (center-of)]
    (input-mouse-move cx cy)
    (wait-ms 100)
    (input-mouse-down :left)
    (wait-ms 100)
    (input-mouse-move 0 0)
    (wait-ms 100)
    (input-mouse-up :left)
    (wait-ms 100)
    (let [[r g b] (sample-bg)]
      (assert (= [r g b] [50 50 50])
              (str "After release with cursor off, base should return; got " [r g b]))))
  (input-release))
```

- [ ] **Step 4: Build dev binary and start the fixture app**

```bash
./build-dev.sh
./build/redin test/ui/hover_active_app.fnl &
```

Wait for the dev server to start (look for `redin-port` and `redin-token` files).

- [ ] **Step 5: Run the test — confirm it FAILS**

```bash
bb test/ui/run.bb test/ui/test_hover_active.bb
```

Expected: `button-rect-exists` and `base-color-resting` PASS. `hover-color-on-cursor-over`, `active-color-on-mouse-down`, `active-persists-when-cursor-drags-off`, `base-restored-after-mouseup-off-rect` FAIL with "Expected hover/active color ..., got [50 50 50]" — proving the variants are not currently applied.

Kill the app:

```bash
curl -X POST -H "Authorization: Bearer $(cat .redin-token)" \
  "http://localhost:$(cat .redin-port)/shutdown" || true
wait
```

- [ ] **Step 6: Commit the failing test**

```bash
git add test/ui/redin_test.bb test/ui/hover_active_app.fnl test/ui/test_hover_active.bb
git commit -m "$(cat <<'EOF'
test(ui): failing #hover / #active state-variant test

Fixture renders one themed button with distinct base/hover/active bg
colours; test pixel-samples the screenshot through resting / hover /
press / drag-off-while-held / release. All but the resting case fail
today because render.odin never applies the documented #hover and
#active variants.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Track `hovered_indices` and `active_idx` in the input package

**Files:**
- Modify: `src/redin/input/input.odin` (add package vars)
- Modify: `src/redin/input/user_events.odin` (populate `hovered_indices`)
- Modify: `src/redin/input/apply.odin` (set/clear `active_idx`)

- [ ] **Step 1: Add package-level state to `src/redin/input/input.odin`**

Find the existing `focused_idx` declaration (it's a package-level `var`). Add the two new vars next to it. Search for `focused_idx :=` or `focused_idx:` to locate it:

```bash
grep -n "^focused_idx\|^@(private) focused_idx\|focused_idx :=" src/redin/input/input.odin
```

Add directly below the line that declares `focused_idx`:

```odin
// Set of node indices currently under the mouse that carry a HoverListener.
// Multiple ancestors can be hovered simultaneously (matches the deepest-
// listener-but-hover-multi-fires policy documented above). Rebuilt every
// frame in get_user_events; never cleared elsewhere.
hovered_indices: [dynamic]int

// Index of the node currently in the #active visual state. Set on
// mousedown when the press lands on a winner with a ClickListener.
// Cleared in apply_listeners when the left mouse button is no longer
// down (CSS-like "stays active until mouseup"). -1 means none.
active_idx: int = -1
```

- [ ] **Step 2: Populate `hovered_indices` in `src/redin/input/user_events.odin`**

Replace the existing hover-listener loop at lines 19-29 with:

```odin
	clear(&hovered_indices)
	for listener in listeners {
		if hl, ok := listener.(types.HoverListener); ok {
			if hl.node_idx < len(node_rects) &&
			   rl.CheckCollisionPointRec(mouse, node_rects[hl.node_idx]) {
				append(&hovered_indices, hl.node_idx)
				append(
					&user_events,
					types.UserEvent{event = .HOVER, node_idx = hl.node_idx},
				)
			}
		}
	}
```

- [ ] **Step 3: Set/clear `active_idx` in `src/redin/input/apply.odin`**

Replace the entire body of `apply_listeners` (the whole proc) with:

```odin
apply_listeners :: proc(
	listeners: [dynamic]types.Listener,
	events: [dynamic]types.InputEvent,
	node_rects: []rl.Rectangle,
) -> [dynamic]types.ApplyEvents {
	applied: [dynamic]types.ApplyEvents

	if focused_idx >= len(node_rects) {
		focused_idx = -1
	}
	if active_idx >= len(node_rects) {
		active_idx = -1
	}

	press_this_frame := false

	for event in events {
		switch e in event {
		case types.MouseEvent:
			if e.button != .LEFT do continue
			mouse := rl.Vector2{e.x, e.y}

			// Deepest node wins (see get_user_events). Only listeners on
			// the innermost listener-bearing node under the pointer fire.
			winner := deepest_listener_idx(listeners[:], node_rects, mouse)
			new_focus := -1
			has_active := false
			if winner >= 0 {
				for listener in listeners {
					switch l in listener {
					case types.FocusListener:
						if l.node_idx == winner do new_focus = winner
					case types.ClickListener:
						if l.node_idx == winner do has_active = true
					case types.HoverListener, types.KeyListener, types.ChangeListener,
					     types.DragListener, types.DropListener, types.Text_Select_Listener,
					     types.DragOverListener:
					}
				}
			}
			focused_idx = new_focus
			if new_focus >= 0 {
				append(&applied, types.ApplyEvents(types.ApplyFocus{idx = new_focus}))
			}
			if has_active {
				active_idx = winner
				press_this_frame = true
			}

		case types.KeyEvent, types.CharEvent, types.ScrollEvent, types.ResizeEvent:
		}
	}

	// Clear active_idx the frame the button comes up, but never on the
	// same frame as the press (so a single-frame click still shows
	// active for at least one rendered frame).
	if !press_this_frame && !is_mouse_button_down(.LEFT) {
		active_idx = -1
	}

	return applied
}
```

- [ ] **Step 4: Build**

```bash
./build-dev.sh
```

Expected: clean compile, no new warnings. (`ApplyActive` is still emitted nowhere now — that's deliberate; we delete the type in the next task.)

- [ ] **Step 5: Run existing UI tests to confirm no regression**

```bash
./build/redin test/ui/smoke_app.fnl &
sleep 1
bb test/ui/run.bb test/ui/test_smoke.bb
curl -X POST -H "Authorization: Bearer $(cat .redin-token)" "http://localhost:$(cat .redin-port)/shutdown" || true
wait
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/redin/input/input.odin src/redin/input/user_events.odin src/redin/input/apply.odin
git commit -m "$(cat <<'EOF'
feat(input): track hovered_indices and active_idx

State lives in the input package alongside focused_idx. hovered_indices
is rebuilt each frame from the existing HoverListener loop; active_idx
is set on mousedown when the winner has a ClickListener and cleared
when the left button is no longer down (one-frame minimum visibility
to keep single-frame clicks observable).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Delete unused `ApplyActive` event

**Files:**
- Modify: `src/redin/types/apply_events.odin`
- Modify: `src/redin/runtime.odin`

- [ ] **Step 1: Remove `ApplyActive` from the apply-event union**

Edit `src/redin/types/apply_events.odin` to delete the `ApplyActive` struct and its union variant. The file should end up with only `ApplyFocus`:

```odin
package types

ApplyFocus :: struct {
	idx: int,
}

ApplyEvents :: union {
	ApplyFocus,
}
```

- [ ] **Step 2: Drop the empty `ApplyActive` case in `src/redin/runtime.odin`**

Around line 260, the runtime loop has:

```odin
		for ae in applied_events {
			switch a in ae {
			case types.ApplyFocus:
				if a.idx < len(b.nodes) {
					if n, ok := b.nodes[a.idx].(types.NodeInput); ok {
						input.focus_enter(n.value)
					} else {
						input.focus_leave()
					}
				}
			case types.ApplyActive:
			}
		}
```

Remove the trailing `case types.ApplyActive:` line. Result:

```odin
		for ae in applied_events {
			switch a in ae {
			case types.ApplyFocus:
				if a.idx < len(b.nodes) {
					if n, ok := b.nodes[a.idx].(types.NodeInput); ok {
						input.focus_enter(n.value)
					} else {
						input.focus_leave()
					}
				}
			}
		}
```

- [ ] **Step 3: Build and run smoke test**

```bash
./build-dev.sh
./build/redin test/ui/smoke_app.fnl &
sleep 1
bb test/ui/run.bb test/ui/test_smoke.bb
curl -X POST -H "Authorization: Bearer $(cat .redin-token)" "http://localhost:$(cat .redin-port)/shutdown" || true
wait
```

Expected: clean compile, smoke PASS.

- [ ] **Step 4: Commit**

```bash
git add src/redin/types/apply_events.odin src/redin/runtime.odin
git commit -m "$(cat <<'EOF'
refactor(input): drop unused ApplyActive event

Active state lives directly in input.active_idx now; the ApplyActive
event was an empty-case no-op in runtime.odin. One less indirection.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Add `resolve_themed_aspect` helper

**Files:**
- Modify: `src/redin/render.odin`

- [ ] **Step 1: Add the helper near the top of `src/redin/render.odin`**

Find the existing `resolve_vp` function (line 18). Insert the new helper directly above it so it's findable next to other small render helpers. Match the existing style (no doc-comment on small helpers is consistent with the file's tone, but this one merits a short note because the precedence order matters):

```odin
// Merge base aspect with #focus, #hover, #active state variants.
// Later overrides earlier: base < #focus < #hover < #active. Matches
// the order documented in docs/reference/theme.md.
//
// idx = -1 means "no state overlays" (used by the drag-preview draw
// paths, where the source/clone aspect already encodes the dragging
// visual and should not be further mutated).
//
// Returns a zero-value Theme if the base aspect is missing — every
// caller already handles default values per-field with `t.<field> != {}`.
resolve_themed_aspect :: proc(
	idx: int,
	aspect: string,
	theme: map[string]types.Theme,
) -> types.Theme {
	result: types.Theme
	if len(aspect) == 0 do return result
	if base, ok := theme[aspect]; ok do result = base
	if idx < 0 do return result

	overlay :: proc(out: ^types.Theme, src: types.Theme) {
		if src.bg != {}          do out.bg = src.bg
		if src.color != {}       do out.color = src.color
		if src.border != {}      do out.border = src.border
		if src.border_width > 0  do out.border_width = src.border_width
		if src.radius > 0        do out.radius = src.radius
		if src.padding != {}     do out.padding = src.padding
		if src.font_size > 0     do out.font_size = src.font_size
		if len(src.font) > 0     do out.font = src.font
		if src.weight > 0        do out.weight = src.weight
		if src.line_height > 0   do out.line_height = src.line_height
		if src.opacity > 0       do out.opacity = src.opacity
		if src.shadow != {}      do out.shadow = src.shadow
		if src.selection != {}   do out.selection = src.selection
		if src.text_align != .Auto do out.text_align = src.text_align
	}

	if idx == input.focused_idx {
		if t, ok := theme[strings.concatenate({aspect, "#focus"}, context.temp_allocator)]; ok do overlay(&result, t)
	}
	for hi in input.hovered_indices {
		if hi == idx {
			if t, ok := theme[strings.concatenate({aspect, "#hover"}, context.temp_allocator)]; ok do overlay(&result, t)
			break
		}
	}
	if idx == input.active_idx {
		if t, ok := theme[strings.concatenate({aspect, "#active"}, context.temp_allocator)]; ok do overlay(&result, t)
	}
	return result
}
```

- [ ] **Step 2: Verify the `Theme` struct fields match the overlay list**

The overlay proc above lists every field it knows about. Confirm with:

```bash
grep -n "^Theme :: struct\|^\}" src/redin/types/theme.odin | head -10
```

Then open `src/redin/types/theme.odin` and confirm every field in `Theme` appears in the `overlay` proc. If any new field is present (e.g. `selection` exists per the canvas docs — already in the list), add it to the overlay. If a field is missing from the helper, **add it now** before continuing — the helper must overlay every Theme field or `#hover`/`#active` will silently drop properties.

- [ ] **Step 3: Build**

```bash
./build-dev.sh
```

Expected: clean compile. (Helper is currently unused; Odin tolerates unused procs without warnings.)

- [ ] **Step 4: No commit yet**

This task ends without a commit; the helper is dead code until Task 5 wires it in. Task 5 will commit both the helper and its callers together.

---

### Task 5: Use the helper from the four draw procs

**Files:**
- Modify: `src/redin/render.odin`

- [ ] **Step 1: Update `draw_box_chrome` (already has `idx`) to use the helper**

Find `draw_box_chrome` (around line 696). Replace its body. The existing function looks like:

```odin
draw_box_chrome :: proc(
	idx: int,
	rect: rl.Rectangle,
	aspect: string,
	theme: map[string]types.Theme,
) {
	if len(aspect) == 0 do return

	bg_color: rl.Color
	has_bg := false
	shadow: types.Shadow

	if t, ok := theme[aspect]; ok {
		if t.bg != {} {
			alpha := u8(255)
			if t.opacity > 0 && t.opacity < 1 do alpha = u8(t.opacity * 255)
			bg_color = rl.Color{t.bg[0], t.bg[1], t.bg[2], alpha}
			has_bg = true
		}
		shadow = t.shadow
	}
	draw_shadow(rect, shadow, 0)
	if has_bg do rl.DrawRectangleRec(rect, bg_color)
}
```

Replace with:

```odin
draw_box_chrome :: proc(
	idx: int,
	rect: rl.Rectangle,
	aspect: string,
	theme: map[string]types.Theme,
) {
	if len(aspect) == 0 do return

	bg_color: rl.Color
	has_bg := false

	t := resolve_themed_aspect(idx, aspect, theme)
	if t.bg != {} {
		alpha := u8(255)
		if t.opacity > 0 && t.opacity < 1 do alpha = u8(t.opacity * 255)
		bg_color = rl.Color{t.bg[0], t.bg[1], t.bg[2], alpha}
		has_bg = true
	}

	draw_shadow(rect, t.shadow, 0)
	if has_bg do rl.DrawRectangleRec(rect, bg_color)
}
```

- [ ] **Step 2: Update `draw_themed_rect` to take `idx`**

Find `draw_themed_rect` at `src/redin/render.odin:1105`. The current body is exactly:

```odin
draw_themed_rect :: proc(rect: rl.Rectangle, aspect: string, theme: map[string]types.Theme) {
	if len(aspect) > 0 {
		if t, ok := theme[aspect]; ok && t.bg != {} {
			bg := rl.Color{t.bg[0], t.bg[1], t.bg[2], 255}
			rl.DrawRectangleRec(rect, bg)
		}
	}
}
```

Replace with:

```odin
draw_themed_rect :: proc(idx: int, rect: rl.Rectangle, aspect: string, theme: map[string]types.Theme) {
	if len(aspect) > 0 {
		t := resolve_themed_aspect(idx, aspect, theme)
		if t.bg != {} {
			bg := rl.Color{t.bg[0], t.bg[1], t.bg[2], 255}
			rl.DrawRectangleRec(rect, bg)
		}
	}
}
```

- [ ] **Step 3: Update every `draw_themed_rect` call site**

There are exactly three (`grep -n "draw_themed_rect(" src/redin/render.odin` to confirm):

- `src/redin/render.odin:567` (case `NodeImage` in main render, inside the per-node loop). Change `draw_themed_rect(rect, n.aspect, theme)` → `draw_themed_rect(idx, rect, n.aspect, theme)`.
- `src/redin/render.odin:573` (case `NodeModal` in main render). Change `draw_themed_rect(rect, n.aspect, theme)` → `draw_themed_rect(idx, rect, n.aspect, theme)`.
- `src/redin/render.odin:668` (inside `draw_subtree_translated`, drag-preview path). Change `draw_themed_rect(rect, aspect, theme)` → `draw_themed_rect(-1, rect, aspect, theme)`.
- `src/redin/render.odin:675` (drag-preview path, `NodeInput` clone). Change `draw_themed_rect(rect, n.aspect, theme)` → `draw_themed_rect(-1, rect, n.aspect, theme)`.

- [ ] **Step 4: Update `draw_button` to take `idx`**

Find `draw_button` (around line 1313). Replace its signature and the theme lookup. The existing function:

```odin
draw_button :: proc(rect: rl.Rectangle, n: types.NodeButton, theme: map[string]types.Theme) {
	bg_color := rl.LIGHTGRAY
	text_color := rl.BLACK
	radius: f32 = 0
	font_size: f32 = 18
	font_name := "sans"
	font_weight: u8 = 0
	shadow: types.Shadow
	radius_u8: u8 = 0

	if len(n.aspect) > 0 {
		if t, ok := theme[n.aspect]; ok {
			if t.bg != {} do bg_color = rl.Color{t.bg[0], t.bg[1], t.bg[2], 255}
			if t.color != {} do text_color = rl.Color{t.color[0], t.color[1], t.color[2], 255}
			if t.radius > 0 do radius = f32(t.radius)
			if t.font_size > 0 do font_size = f32(t.font_size)
			if len(t.font) > 0 do font_name = t.font
			font_weight = t.weight
			shadow = t.shadow
			radius_u8 = t.radius
		}
	}
	...
```

Replace with:

```odin
draw_button :: proc(idx: int, rect: rl.Rectangle, n: types.NodeButton, theme: map[string]types.Theme) {
	bg_color := rl.LIGHTGRAY
	text_color := rl.BLACK
	radius: f32 = 0
	font_size: f32 = 18
	font_name := "sans"
	font_weight: u8 = 0
	shadow: types.Shadow
	radius_u8: u8 = 0

	if len(n.aspect) > 0 {
		t := resolve_themed_aspect(idx, n.aspect, theme)
		if t.bg != {} do bg_color = rl.Color{t.bg[0], t.bg[1], t.bg[2], 255}
		if t.color != {} do text_color = rl.Color{t.color[0], t.color[1], t.color[2], 255}
		if t.radius > 0 do radius = f32(t.radius)
		if t.font_size > 0 do font_size = f32(t.font_size)
		if len(t.font) > 0 do font_name = t.font
		font_weight = t.weight
		shadow = t.shadow
		radius_u8 = t.radius
	}
	...
```

(Keep everything after the theme block unchanged.)

- [ ] **Step 5: Update every `draw_button` call site**

There are exactly two (`grep -n "draw_button(" src/redin/render.odin` to confirm):

- `src/redin/render.odin:563` (case `NodeButton` in main render, inside the per-node loop). Change `draw_button(rect, n, theme)` → `draw_button(idx, rect, n, theme)`.
- `src/redin/render.odin:659` (drag-preview path). Change `draw_button(rect, b, theme)` → `draw_button(-1, rect, b, theme)`.

- [ ] **Step 6: Update `draw_text` to use the helper**

Find `draw_text` (around line 1356). It already takes `idx`. Replace the theme lookup block:

```odin
	if len(n.aspect) > 0 {
		if t, ok := theme[n.aspect]; ok {
			if t.font_size > 0 do font_size = f32(t.font_size)
			if t.color != {} do text_color = rl.Color{t.color[0], t.color[1], t.color[2], 255}
			if len(t.font) > 0 do font_name = t.font
			font_weight = t.weight
			lh_ratio = t.line_height
			...
```

becomes:

```odin
	if len(n.aspect) > 0 {
		t := resolve_themed_aspect(idx, n.aspect, theme)
		if t.font_size > 0 do font_size = f32(t.font_size)
		if t.color != {} do text_color = rl.Color{t.color[0], t.color[1], t.color[2], 255}
		if len(t.font) > 0 do font_name = t.font
		font_weight = t.weight
		lh_ratio = t.line_height
		...
```

(Preserve all field reads that follow; only replace the `if t, ok := theme[n.aspect]; ok {` outer shell. The closing brace of the inner block still exists; you're effectively dropping one layer of nesting.)

- [ ] **Step 7: Update `draw_input` to use the helper**

Find `draw_input` (around line 1141). It takes `idx`. There are two theme-related blocks:

1. The leading selection-colour lookup (lines 1156-1165):

```odin
	if len(n.aspect) > 0 {
		if aspect, ok := theme[n.aspect]; ok {
			if aspect.selection != ([4]u8{}) {
				selection_color = rl.Color{...}
			}
		}
	}
```

This stays as-is — selection colour from the base aspect is fine; state overlay doesn't typically change it.

2. The main theme lookup block (lines 1176-1197) plus the inline `#focus` overlay. Replace this entire block:

```odin
	if len(n.aspect) > 0 {
		if t, ok := theme[n.aspect]; ok {
			if t.border != {} do border_color = rl.Color{t.border[0], t.border[1], t.border[2], 255}
			...
		}
		if is_focused {
			focus_key := strings.concatenate({n.aspect, "#focus"}, context.temp_allocator)
			if ft, ok := theme[focus_key]; ok {
				if ft.border != {} do border_color = rl.Color{ft.border[0], ft.border[1], ft.border[2], 255}
			}
		}
	}
```

with:

```odin
	if len(n.aspect) > 0 {
		t := resolve_themed_aspect(idx, n.aspect, theme)
		if t.border != {} do border_color = rl.Color{t.border[0], t.border[1], t.border[2], 255}
		if t.bg != {} do bg_color = rl.Color{t.bg[0], t.bg[1], t.bg[2], 255}
		if t.color != {} do text_color = rl.Color{t.color[0], t.color[1], t.color[2], 255}
		if t.font_size > 0 do font_size = f32(t.font_size)
		if t.border_width > 0 do border_width = f32(t.border_width)
		if t.padding[3] > 0 do padding_l = f32(t.padding[3])
		if t.padding[1] > 0 do padding_r = f32(t.padding[1])
		if t.padding[0] > 0 do padding_t = f32(t.padding[0])
		if len(t.font) > 0 do font_name = t.font
		font_weight = t.weight
		lh_ratio = t.line_height
		text_align = t.text_align
	}
```

Note `is_focused` is no longer consulted here — the helper handles `#focus` via `idx == input.focused_idx`. Confirm `is_focused` is still used elsewhere in `draw_input` (it is — for cursor / selection logic). Leave the local `is_focused := input.focused_idx == idx` definition in place; only the explicit `#focus` overlay block is gone.

- [ ] **Step 8: Build**

```bash
./build-dev.sh
```

Expected: clean compile. If any `draw_button` / `draw_themed_rect` call site was missed, Odin will report "wrong number of arguments". Fix and re-build.

- [ ] **Step 9: Run the failing UI test — confirm it now PASSES**

```bash
./build/redin test/ui/hover_active_app.fnl &
sleep 1
bb test/ui/run.bb test/ui/test_hover_active.bb
curl -X POST -H "Authorization: Bearer $(cat .redin-token)" "http://localhost:$(cat .redin-port)/shutdown" || true
wait
```

Expected: all 5 deftests PASS.

- [ ] **Step 10: Run the existing UI suite to confirm no regression**

```bash
bash test/ui/run-all.sh
```

Expected: all tests pass. If anything fails, investigate before committing — `draw_button` / `draw_text` are on hot paths for the kitchen-sink, drag, button, modal, and popout tests.

- [ ] **Step 11: Commit**

```bash
git add src/redin/render.odin
git commit -m "$(cat <<'EOF'
feat(render): apply #hover and #active theme state variants

Adds resolve_themed_aspect helper that merges base + #focus + #hover +
#active in the documented precedence order. draw_button, draw_text,
draw_themed_rect, draw_box_chrome, and draw_input all route through
it. Drag-preview paths pass idx=-1 to skip overlays (the source/clone
aspect already encodes the drag visual). The inline #focus block in
draw_input is replaced by the helper, so focused inputs now overlay
all #focus fields, not just border.

Closes the documented-but-never-built hover/active rendering gap.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Full verification

**Files:** none

- [ ] **Step 1: Full UI test suite**

```bash
bash test/ui/run-all.sh
```

Expected: all tests pass, including the new `test_hover_active`.

- [ ] **Step 2: Fennel runtime unit tests**

```bash
luajit test/lua/runner.lua test/lua/test_*.fnl
```

Expected: all pass (unchanged by this work).

- [ ] **Step 3: Release build check**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin-release
```

Expected: clean build. Confirms the change doesn't depend on REDIN_DEV-gated paths.

- [ ] **Step 4: Manual smoke — kitchen-sink**

```bash
./build/redin examples/kitchen-sink.fnl &
```

Visually confirm:
- Hovering the "Add" button shows the lighter `[143 188 187]` colour.
- Hovering an "x" remove button turns the text red `[191 97 106]`.
- Pressing either shows the darker active colour.
- Pressing then dragging off the button keeps the active colour until release.

Shutdown:

```bash
curl -X POST -H "Authorization: Bearer $(cat .redin-token)" "http://localhost:$(cat .redin-port)/shutdown" || true
wait
```

- [ ] **Step 5: No commit needed**

This is a verification-only task. If anything failed, fix and amend the previous commit (or commit a fix on top, per the repo's no-amend convention).
