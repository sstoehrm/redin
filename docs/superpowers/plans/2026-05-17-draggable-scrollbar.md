# Draggable scrollbar implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the scrollbar thumb in `scroll-y` / `scroll-x` containers draggable. Drag the thumb to scroll proportionally, click the gutter outside the thumb to page-up/page-down, swap to a vertical-resize cursor while hovered or dragging, and visually emphasise the bar via `:scrollbar` / `#hover` / `#active` theme variants.

**Architecture:** A new parallel state machine `Scrollbar_State` in `src/redin/input/scrollbar.odin` (separate from the app-level `Drag_State` in `drag.odin` which carries payload/animate/tags). `apply_scrollbar` runs each frame between `apply_listeners` and `set_hover_cursor`, hit-tests the gutter rect (4px visible bar + 4px tolerance each side), and mutates `scroll_offsets[idx]` directly. Bar rendering routes through the existing `resolve_themed_aspect` helper so `#hover` and `#active` overlay naturally. New dev-server endpoints `GET /scroll-info` and `GET /cursor` expose state for UI tests to assert.

**Tech Stack:** Odin + Raylib (render, input), Fennel (theme defaults, test fixture), Babashka (UI integration tests).

**Spec:** `docs/superpowers/specs/2026-05-17-draggable-scrollbar-design.md`

**Depends on:** [#142](https://github.com/sstoehrm/redin/issues/142) (PR [#144](https://github.com/sstoehrm/redin/pull/144)) — the regression tests for this feature pixel-sample over the list edge and need consistent scissor clipping. This branch is layered on top of that PR. After #144 merges, rebase onto main.

---

## File map

| Path | Action | Responsibility |
|------|--------|----------------|
| `src/redin/types/scroll.odin` | Create | Move the `Scroll_Info` struct out of `render.odin` so both `render` (writer) and `bridge` (reader for `/scroll-info`) can import it. |
| `src/redin/input/scrollbar.odin` | Create | `Scrollbar_State` union + `apply_scrollbar` proc that mutates state and `scroll_offsets[idx]`. |
| `src/redin/input/scrollbar_test.odin` | Create | Unit tests for the drag-math formula. |
| `src/redin/input/input.odin` | Modify | Extend `set_hover_cursor` precedence to honour `Scrollbar_*` states; track `current_cursor` package-var so `/cursor` can return it. |
| `src/redin/input/apply.odin` | Modify | Skip the MouseEvent loop's press handling when `apply_scrollbar` consumed the press. |
| `src/redin/input/drag.odin` | Modify | Skip entry into `Drag_Pending` while `Scrollbar_Dragging`. |
| `src/redin/input/text_select.odin` | Modify | Skip selection-start while scrollbar consumed press. |
| `src/redin/input/state.odin` | Modify | Reset `scrollbar` in `state_destroy`. |
| `src/redin/render.odin` | Modify | Move `Scroll_Info` import. Route bar drawing through `resolve_themed_aspect`. Compute bar rect from theme `:border-width` (default 4). |
| `src/redin/runtime.odin` | Modify | Call `input.apply_scrollbar` between `apply_listeners` and `set_hover_cursor`. Publish `node_scroll_info` to bridge. |
| `src/redin/bridge/devserver.odin` | Modify | `GET /scroll-info` returns the publish map as JSON. `GET /cursor` returns the tracked cursor name. |
| `src/redin/bridge/bridge.odin` | Modify | Extend `poll_devserver` signature to receive `node_scroll_info`; store on `Dev_Server`. |
| `src/runtime/theme.fnl` | Modify | Bundle `:scrollbar` / `:scrollbar#hover` / `:scrollbar#active` defaults. |
| `test/ui/redin_test.bb` | Modify | Add `scroll-info` and `cursor-kind` helpers. |
| `test/ui/scrollbar_drag_app.fnl` | Create | Test fixture: scroll-y vbox with enough rows to overflow + known geometry. |
| `test/ui/test_scrollbar_drag.bb` | Create | UI integration tests (hover-cursor, thumb-drag, page-up, page-down, drag-off-gutter). |
| `docs/reference/theme.md` | Modify | Document `:scrollbar` aspect family. |
| `docs/core-api.md` | Modify | Document `GET /scroll-info` and `GET /cursor` endpoints. |
| `CLAUDE.md` | Modify | Same endpoint table. |

---

### Task 1: Test infrastructure — `/scroll-info` and `/cursor` endpoints

**Files:**
- Create: `src/redin/types/scroll.odin`
- Modify: `src/redin/render.odin`
- Modify: `src/redin/input/input.odin`
- Modify: `src/redin/bridge/devserver.odin`
- Modify: `src/redin/bridge/bridge.odin`
- Modify: `src/redin/runtime.odin`
- Modify: `test/ui/redin_test.bb`
- Modify: `CLAUDE.md`
- Modify: `docs/core-api.md`

- [ ] **Step 1: Move `Scroll_Info` to package `types`**

Create `src/redin/types/scroll.odin`:

```odin
package types

Scroll_Info :: struct {
	total: f32, // sum of child sizes on the scroll axis
	off:   f32, // clamped scroll offset
}
```

- [ ] **Step 2: Delete the duplicate in `src/redin/render.odin`**

Replace the local struct definition at `src/redin/render.odin:121-124`:

```odin
Scroll_Info :: struct {
	total: f32, // sum of child sizes on the scroll axis
	off:   f32, // clamped scroll offset
}
node_scroll_info: map[int]Scroll_Info
```

with:

```odin
node_scroll_info: map[int]types.Scroll_Info
```

Confirm `import "types"` is already present at the top of `render.odin` (it is — line 8 area).

Search for any `Scroll_Info` references in `render.odin` and prefix with `types.` (likely line 423: `node_scroll_info[idx] = Scroll_Info{...}` becomes `types.Scroll_Info{...}`).

- [ ] **Step 3: Track current cursor in `input/input.odin`**

Add a package var near the top of the file alongside `focused_idx` / `active_idx`:

```odin
// Cursor most recently passed to rl.SetMouseCursor. Tracked here so
// the dev-server /cursor endpoint can echo it without raylib needing
// a getter. Updated by set_hover_cursor.
current_cursor: rl.MouseCursor = .DEFAULT
```

In `set_hover_cursor`, replace every `rl.SetMouseCursor(.X)` with a tiny helper:

```odin
set_cursor :: proc(c: rl.MouseCursor) {
	current_cursor = c
	rl.SetMouseCursor(c)
}
```

and call `set_cursor(.RESIZE_ALL)`, `set_cursor(.POINTING_HAND)`, etc., in place of the existing `rl.SetMouseCursor` calls. Don't change the precedence cascade.

- [ ] **Step 4: Extend `Dev_Server` struct + `poll_devserver` to carry scroll info**

In `src/redin/bridge/devserver.odin` around line 84 (where `current_rects` is declared on `Dev_Server`), add:

```odin
current_scroll_info: map[int]types.Scroll_Info,
```

In `src/redin/bridge/bridge.odin`, change `poll_devserver`'s signature and body. The current code at line 161-167 is:

```odin
poll_devserver :: proc(b: ^Bridge, events: ^[dynamic]types.InputEvent, node_rects: []rl.Rectangle) {
	when !(REDIN_DEV || REDIN_AGENT) do return
	b.dev_server.current_rects = node_rects
	devserver_poll(&b.dev_server)
	devserver_drain_events(&b.dev_server, events)
	b.dev_server.current_rects = nil
}
```

Replace with:

```odin
poll_devserver :: proc(
	b: ^Bridge,
	events: ^[dynamic]types.InputEvent,
	node_rects: []rl.Rectangle,
	scroll_info: map[int]types.Scroll_Info,
) {
	when !(REDIN_DEV || REDIN_AGENT) do return
	b.dev_server.current_rects = node_rects
	b.dev_server.current_scroll_info = scroll_info
	devserver_poll(&b.dev_server)
	devserver_drain_events(&b.dev_server, events)
	b.dev_server.current_rects = nil
	b.dev_server.current_scroll_info = nil
}
```

- [ ] **Step 5: Update the caller in `runtime.odin`**

At `src/redin/runtime.odin:220` change:

```odin
bridge.poll_devserver(&b, &input_events, node_rects[:])
```

to:

```odin
bridge.poll_devserver(&b, &input_events, node_rects[:], node_scroll_info)
```

(`node_scroll_info` is the package-redin var in `render.odin`; same package, so accessible by name.)

- [ ] **Step 6: Add `GET /scroll-info` handler**

In `src/redin/bridge/devserver.odin`, find the request-dispatch switch (around line 740-790). After the existing `/aspects` GET handler (search `req.path == "/aspects"`), add a route for `/scroll-info`:

```odin
		} else if req.method == "GET" && req.path == "/scroll-info" {
			handle_get_scroll_info(ds, ch)
```

Then add the handler proc near the other `handle_get_*` procs (e.g. just before `handle_get_window`):

```odin
handle_get_scroll_info :: proc(ds: ^Dev_Server, ch: ^Response_Channel) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	strings.write_string(&b, "{")
	first := true
	for idx, info in ds.current_scroll_info {
		if !first do strings.write_string(&b, ",")
		first = false
		fmt.sbprintf(&b, `"%d":{"total":%g,"off":%g}`, idx, info.total, info.off)
	}
	strings.write_string(&b, "}")
	respond_json(ch, strings.to_string(b))
}
```

- [ ] **Step 7: Add `GET /cursor` handler**

In the same dispatch switch, add a route for `/cursor`:

```odin
		} else if req.method == "GET" && req.path == "/cursor" {
			handle_get_cursor(ds, ch)
```

And the handler:

```odin
handle_get_cursor :: proc(ds: ^Dev_Server, ch: ^Response_Channel) {
	name := "default"
	switch input.current_cursor {
	case .DEFAULT:        name = "default"
	case .ARROW:          name = "arrow"
	case .IBEAM:          name = "ibeam"
	case .CROSSHAIR:      name = "crosshair"
	case .POINTING_HAND:  name = "pointing-hand"
	case .RESIZE_EW:      name = "resize-ew"
	case .RESIZE_NS:      name = "resize-ns"
	case .RESIZE_NWSE:    name = "resize-nwse"
	case .RESIZE_NESW:    name = "resize-nesw"
	case .RESIZE_ALL:     name = "resize-all"
	case .NOT_ALLOWED:    name = "not-allowed"
	}
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	fmt.sbprintf(&b, `{{"kind":"%s"}}`, name)
	respond_json(ch, strings.to_string(b))
}
```

Confirm `import "input"` is present at the top of `devserver.odin` (it is — many handlers reference it).

- [ ] **Step 8: Add Babashka helpers**

In `test/ui/redin_test.bb`, after the existing `input-scroll` helper, add:

```clojure
(defn scroll-info
  "Fetch the per-node scroll state via GET /scroll-info.
   Returns a map keyed by node idx (string) → {:total N :off N}."
  []
  (get-json "/scroll-info"))

(defn cursor-kind
  "Fetch the current mouse cursor kind via GET /cursor.
   Returns a keyword like :default, :resize-ns, :pointing-hand."
  []
  (keyword (:kind (get-json "/cursor"))))
```

- [ ] **Step 9: Document the endpoints**

Add to the dev-server endpoint table in `CLAUDE.md` (after the existing `/input/scroll` row):

```
| `GET`  | `/scroll-info` | Per-node scroll state: `{"<idx>":{"total":N,"off":N}, ...}`. Empty when no scrollable nodes. |
| `GET`  | `/cursor` | Current mouse-cursor kind: `{"kind":"default\|resize-ns\|resize-ew\|pointing-hand\|ibeam\|resize-all"}`. |
```

Add the same two rows to `docs/core-api.md`'s dev-server endpoint table.

- [ ] **Step 10: Build + smoke**

```bash
./build-dev.sh
./build/redin test/ui/smoke_app.fnl &
sleep 2
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -H "Authorization: Bearer $TOKEN" "http://localhost:$PORT/scroll-info"
echo ""
curl -s -H "Authorization: Bearer $TOKEN" "http://localhost:$PORT/cursor"
curl -s -X POST -H "Authorization: Bearer $TOKEN" "http://localhost:$PORT/shutdown" > /dev/null
wait 2>/dev/null
```

Expected:
- `/scroll-info` returns `{}` (smoke fixture has no scrollables).
- `/cursor` returns `{"kind":"default"}`.

- [ ] **Step 11: Commit**

```bash
git add src/redin/types/scroll.odin src/redin/render.odin src/redin/input/input.odin \
  src/redin/bridge/devserver.odin src/redin/bridge/bridge.odin src/redin/runtime.odin \
  test/ui/redin_test.bb CLAUDE.md docs/core-api.md
git commit -m "$(cat <<'EOF'
feat(devserver): GET /scroll-info + GET /cursor endpoints

Test infrastructure for the scrollbar-drag feature: /scroll-info exposes
per-scrollable-node {total, off} so UI tests can assert scroll position
without screenshot inspection; /cursor exposes the tracked mouse cursor
kind so tests can verify cursor swaps. set_hover_cursor now routes
through a tiny set_cursor helper that mirrors rl.SetMouseCursor into a
package-local current_cursor, since raylib has no getter.

Scroll_Info moves to package types so the bridge can read render's
node_scroll_info via the existing poll_devserver pump pattern.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Failing UI test (red phase)

**Files:**
- Create: `test/ui/scrollbar_drag_app.fnl`
- Create: `test/ui/test_scrollbar_drag.bb`

- [ ] **Step 1: Create the fixture `test/ui/scrollbar_drag_app.fnl`**

```fennel
;; Fixture for #143 — draggable scrollbar tests.
;; A 200px-tall scroll-y vbox at known coordinates with 30 rows of
;; 30px each (total content 900px → 700px scrollable). Geometry is
;; pinned so the test can compute thumb position and drag deltas
;; analytically.
;;
;; Layout:
;;   sibling above: y=0..50, red (smoke check that clipping holds)
;;   list:          y=50..250, scroll-y, 200px tall, content 900px
;;   thumb:         visible width 4px at x=1276 (window 1280 - 4)
;;     thumb_h = 200 * (200 / 900) ≈ 44px
;;     gutter is y=50..250 (200px tall)
;;     max_thumb_y = 250 - 44 = 206
;;     each scroll-tick = 30 / (900-200) ≈ 4.3% of gutter

(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme {:sibling {:bg [220 0 0] :padding [0 0 0 0]}
                      :list    {:bg [40 40 40] :padding [0 0 0 0]}
                      :row     {:bg [70 70 70] :padding [0 0 0 0]}})

(dataflow.init {})
(global redin_get_state (. dataflow :_get-raw-db))

(global main_view
        (fn []
          [:stack {:viewport [[:top_left 0 0 :full :full]]}
           [:vbox {:width :full :height :full}
            [:vbox {:aspect :sibling :width :full :height 50}]
            [:vbox {:aspect :list :width :full :height 200
                    :overflow :scroll-y}
             (icollect [i v (ipairs [1 2 3 4 5 6 7 8 9 10
                                     11 12 13 14 15 16 17 18 19 20
                                     21 22 23 24 25 26 27 28 29 30])]
               [:vbox {:aspect :row :width :full :height 30}])]]]))
```

- [ ] **Step 2: Create the test `test/ui/test_scrollbar_drag.bb`**

```clojure
(require '[redin-test :refer :all])

;; Tests for #143: draggable scrollbar.
;;
;; Geometry (see scrollbar_drag_app.fnl):
;;   gutter:     y=50..250 (200px tall, list height)
;;   bar width:  4px visible, hit-zone +4 each side (effective 12px)
;;   total:      900px content
;;   max_scroll: 900 - 200 = 700
;;   thumb_h:    200 * (200/900) ≈ 44.4 → 45 after clamp/round
;;
;; The window is 1280 wide; the scroll-y bar sits at x = 1280-4 = 1276.

(defn- list-idx
  "Find the scrollable list's node idx from /scroll-info — it's the
   only key in the map at boot."
  []
  (let [info (scroll-info)
        ks   (keys info)]
    (when (= 1 (count ks))
      (Long/parseLong (name (first ks))))))

(defn- list-info [] (let [info (scroll-info)] (first (vals info))))

(defn- offset [] (:off (list-info)))

(defn- thumb-rect
  "Compute the bar's expected y-range from /scroll-info. Pure derivation
   from total/off and the known container dims."
  []
  (let [{:keys [total off]} (list-info)
        gutter-y0 50
        gutter-h  200
        ratio     (/ gutter-h total)
        thumb-h   (max 20 (* gutter-h ratio))
        max-scr   (- total gutter-h)
        thumb-y   (+ gutter-y0
                     (if (pos? max-scr)
                       (* (/ off max-scr) (- gutter-h thumb-h))
                       0))]
    {:y0 thumb-y :y1 (+ thumb-y thumb-h) :h thumb-h}))

(deftest scroll-info-reports-list
  (assert (some? (list-idx)) "scrollable list should appear in /scroll-info")
  (let [{:keys [total off]} (list-info)]
    (assert (= 0.0 off) (str "fresh app: scroll offset should be 0; got " off))
    (assert (= 900.0 total) (str "expected total=900; got " total))))

(deftest cursor-on-thumb-is-resize-ns
  ;; Hover the cursor over the thumb (cursor center at y=72ish — gutter
  ;; top + half-thumb). Cursor should swap to resize-ns.
  (input-takeover)
  (try
    (let [{:keys [y0 y1]} (thumb-rect)
          ty (int (+ y0 (/ (- y1 y0) 2)))]
      (input-mouse-move 1278 ty)
      (wait-ms 100)
      (let [k (cursor-kind)]
        (assert (= k :resize-ns)
                (str "cursor over thumb should be :resize-ns; got " k))))
    (finally
      (input-release))))

(deftest drag-thumb-changes-scroll
  (input-takeover)
  (try
    (let [{:keys [y0 y1]} (thumb-rect)
          ty (int (+ y0 (/ (- y1 y0) 2)))]
      (input-mouse-move 1278 ty)
      (wait-ms 100)
      (input-mouse-down :left)
      (wait-ms 100)
      ;; Drag the thumb 50px down. Expected delta in scroll_offset:
      ;;   50 / (gutter_h - thumb_h) * max_scroll
      ;;   = 50 / (200 - 44.44) * 700 ≈ 225
      (input-mouse-move 1278 (+ ty 50))
      (wait-ms 100)
      (let [off (offset)]
        (assert (and (> off 200) (< off 250))
                (str "after 50px drag, offset should be ~225; got " off)))
      (input-mouse-up :left))
    (finally
      (input-release))))

(deftest click-below-thumb-pages-down
  (input-takeover)
  (try
    (let [{:keys [y1]} (thumb-rect)
          ;; 10px below the thumb's bottom edge — inside the gutter,
          ;; outside the thumb.
          cy (int (+ y1 10))]
      (input-mouse-move 1278 cy)
      (wait-ms 100)
      (input-mouse-down :left)
      (wait-ms 100)
      (input-mouse-up :left)
      (wait-ms 100)
      ;; Page-down adds one container-height (200px) to offset, clamped
      ;; to max_scroll=700.
      (let [off (offset)]
        (assert (and (>= off 190) (<= off 210))
                (str "page-down should advance by ~200; got " off))))
    (finally
      (input-release))))

(deftest click-above-thumb-pages-up
  (input-takeover)
  (try
    ;; Set up: scroll to the middle first via /input/scroll.
    (input-scroll 640 150 -10)
    (wait-ms 100)
    (let [start-off (offset)
          {:keys [y0]} (thumb-rect)
          ;; 10px above the thumb's top edge — inside the gutter,
          ;; outside the thumb.
          cy (int (- y0 10))]
      (assert (> start-off 100) (str "setup: offset should be >100; got " start-off))
      (input-mouse-move 1278 cy)
      (wait-ms 100)
      (input-mouse-down :left)
      (wait-ms 100)
      (input-mouse-up :left)
      (wait-ms 100)
      (let [off (offset)]
        (assert (= off (max 0 (- start-off 200)))
                (str "page-up should retreat by 200; got " off))))
    (finally
      (input-release))))

(deftest drag-survives-cursor-off-gutter
  (input-takeover)
  (try
    (let [{:keys [y0 y1]} (thumb-rect)
          ty (int (+ y0 (/ (- y1 y0) 2)))]
      (input-mouse-move 1278 ty)
      (wait-ms 100)
      (input-mouse-down :left)
      (wait-ms 100)
      ;; Drag down 30px, then move cursor far left (off the gutter).
      ;; The drag should keep tracking the cursor's y, ignoring x.
      (input-mouse-move 1278 (+ ty 30))
      (wait-ms 50)
      (input-mouse-move 100 (+ ty 60))
      (wait-ms 100)
      (let [off (offset)]
        (assert (> off 200)
                (str "drag should continue when cursor leaves gutter horizontally; got "
                     off)))
      (input-mouse-up :left))
    (finally
      (input-release))))
```

- [ ] **Step 3: Build and run — expect failures**

```bash
./build-dev.sh
./build/redin test/ui/scrollbar_drag_app.fnl &
sleep 2
bb test/ui/run.bb test/ui/test_scrollbar_drag.bb
curl -s -X POST -H "Authorization: Bearer $(cat .redin-token)" "http://localhost:$(cat .redin-port)/shutdown" > /dev/null 2>&1
wait 2>/dev/null
```

Expected: `scroll-info-reports-list` PASSES (the infrastructure from Task 1 works). The other five tests FAIL (no scrollbar interaction wired yet).

- [ ] **Step 4: Commit**

```bash
git add test/ui/scrollbar_drag_app.fnl test/ui/test_scrollbar_drag.bb
git commit -m "$(cat <<'EOF'
test(ui): failing scrollbar-drag tests (#143)

Fixture: 200px scroll-y vbox with 30 rows of 30px so total=900,
max_scroll=700. Six deftests: scroll-info reports the list,
cursor swaps on thumb hover, thumb drag changes scroll, page-down
on gutter click below thumb, page-up on gutter click above thumb,
drag survives cursor leaving the gutter horizontally.

Today, only the scroll-info pre-condition passes. The rest fail
because no scrollbar input handler exists yet.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Scrollbar state types + theme defaults + theme-driven bar render

**Files:**
- Create: `src/redin/input/scrollbar.odin`
- Modify: `src/redin/render.odin`
- Modify: `src/runtime/theme.fnl`

- [ ] **Step 1: Create the state types**

Create `src/redin/input/scrollbar.odin`:

```odin
package input

import "../types"
import rl "vendor:raylib"

Scrollbar_Axis :: enum { Y, X }

Scrollbar_Hovering :: struct {
	container_idx: int,
	axis:          Scrollbar_Axis,
}

Scrollbar_Dragging :: struct {
	using hovering:       Scrollbar_Hovering,
	// Cursor's offset from the thumb's top (or left) edge at drag-start.
	// Holding this constant during drag keeps the thumb from snapping
	// under the cursor.
	grab_offset_in_thumb: f32,
}

Scrollbar_State :: union { Scrollbar_Hovering, Scrollbar_Dragging }

scrollbar: Scrollbar_State

// container_idx of the scrollbar state, regardless of variant.
// Returns -1 if scrollbar is idle.
scrollbar_container_idx :: proc() -> int {
	switch s in scrollbar {
	case Scrollbar_Hovering: return s.container_idx
	case Scrollbar_Dragging: return s.container_idx
	}
	return -1
}

// Stub: implemented in Task 5/6/7.
apply_scrollbar :: proc(
	events:      []types.InputEvent,
	nodes:       []types.Node,
	node_rects:  []rl.Rectangle,
	scroll_info: map[int]types.Scroll_Info,
	scroll_offsets: ^map[int]f32,
	theme:       map[string]types.Theme,
) -> (consumed_press: bool) {
	return false
}
```

The stub is intentional: Task 3 ships the types so the runtime can wire the call without breaking the build. Tasks 5-7 fill in the logic.

- [ ] **Step 2: Wire the call in `runtime.odin`**

In `src/redin/runtime.odin`, after `apply_listeners` returns and before `set_hover_cursor` (around line 247-272), add:

```odin
		scrollbar_consumed := input.apply_scrollbar(
			input_events[:], b.nodes[:], node_rects[:],
			node_scroll_info, &scroll_offsets, b.theme,
		)
		_ = scrollbar_consumed // hooked up by gating tasks (10) later
```

`scroll_offsets` is the package-redin var in `render.odin`. Same package as runtime.odin, so accessible by name. Pass `&scroll_offsets` so apply_scrollbar can mutate.

- [ ] **Step 3: Bundle `:scrollbar` defaults in `src/runtime/theme.fnl`**

Find the `(local defaults ...)` table in `src/runtime/theme.fnl`. Add three new entries:

```fennel
   :scrollbar         {:bg [200 200 200] :opacity 0.47 :radius 2 :border-width 4}
   :scrollbar#hover   {:bg [200 200 200] :opacity 0.71}
   :scrollbar#active  {:bg [230 230 230] :opacity 0.78}
```

If the existing defaults block has no convenient place, append at the end of the table before the closing brace.

- [ ] **Step 4: Route bar rendering through `resolve_themed_aspect`**

In `src/redin/render.odin`, find the bar-draw block in `draw_box_children` (around line 894-916). The existing code uses a hardcoded color:

```odin
		if scrollable_y && fixed_total > content_rect.height {
			bar_w: f32 = 4
			bar_x := content_rect.x + content_rect.width - bar_w
			visible_ratio := content_rect.height / fixed_total
			bar_h := max(content_rect.height * visible_ratio, 20)
			max_scroll := fixed_total - content_rect.height
			scroll_ratio := scroll_off / max_scroll if max_scroll > 0 else 0
			bar_y := content_rect.y + scroll_ratio * (content_rect.height - bar_h)
			rl.DrawRectangleRounded(
				{bar_x, bar_y, bar_w, bar_h}, 1, 4, rl.Color{200, 200, 200, 120},
			)
		}
```

Replace with:

```odin
		if scrollable_y && fixed_total > content_rect.height {
			t := resolve_scrollbar_theme(idx, theme)
			bar_w := f32(t.border_width if t.border_width > 0 else 4)
			bar_x := content_rect.x + content_rect.width - bar_w
			visible_ratio := content_rect.height / fixed_total
			bar_h := max(content_rect.height * visible_ratio, 20)
			max_scroll := fixed_total - content_rect.height
			scroll_ratio := scroll_off / max_scroll if max_scroll > 0 else 0
			bar_y := content_rect.y + scroll_ratio * (content_rect.height - bar_h)
			roundness := f32(t.radius * 2) / bar_w if bar_w > 0 else 1
			rl.DrawRectangleRounded(
				{bar_x, bar_y, bar_w, bar_h}, roundness, 4,
				scrollbar_color(t),
			)
		}
```

Do the same for the scrollable_x branch immediately below it:

```odin
		} else if scrollable_x && fixed_total > content_rect.width {
			t := resolve_scrollbar_theme(idx, theme)
			bar_h := f32(t.border_width if t.border_width > 0 else 4)
			bar_y := content_rect.y + content_rect.height - bar_h
			visible_ratio := content_rect.width / fixed_total
			bar_w := max(content_rect.width * visible_ratio, 20)
			max_scroll := fixed_total - content_rect.width
			scroll_ratio := scroll_off / max_scroll if max_scroll > 0 else 0
			bar_x := content_rect.x + scroll_ratio * (content_rect.width - bar_w)
			roundness := f32(t.radius * 2) / bar_h if bar_h > 0 else 1
			rl.DrawRectangleRounded(
				{bar_x, bar_y, bar_w, bar_h}, roundness, 4,
				scrollbar_color(t),
			)
		}
```

Add the two helper procs near the top of `draw_box_children`, or as file-local procs above it:

```odin
// Resolve :scrollbar with #hover / #active overlays based on the
// current input.scrollbar state. Active wins over hover, CSS-style.
resolve_scrollbar_theme :: proc(idx: int, theme: map[string]types.Theme) -> types.Theme {
	result: types.Theme
	if base, ok := theme["scrollbar"]; ok do result = base
	if input.scrollbar_container_idx() == idx {
		switch s in input.scrollbar {
		case input.Scrollbar_Hovering:
			if t, ok := theme["scrollbar#hover"]; ok do overlay_theme(&result, t)
		case input.Scrollbar_Dragging:
			if t, ok := theme["scrollbar#hover"]; ok do overlay_theme(&result, t)
			if t, ok := theme["scrollbar#active"]; ok do overlay_theme(&result, t)
		}
	}
	return result
}

scrollbar_color :: proc(t: types.Theme) -> rl.Color {
	r := t.bg[0] if t.bg != {} else 200
	g := t.bg[1] if t.bg != {} else 200
	b := t.bg[2] if t.bg != {} else 200
	alpha: u8 = 120
	if t.opacity > 0 && t.opacity < 1 do alpha = u8(t.opacity * 255)
	return rl.Color{r, g, b, alpha}
}

// Field-by-field non-zero overlay, same shape as resolve_themed_aspect's
// inner `overlay` proc. Lifted out for reuse here.
overlay_theme :: proc(out: ^types.Theme, src: types.Theme) {
	if src.bg != {}            do out.bg = src.bg
	if src.color != {}         do out.color = src.color
	if src.border != {}        do out.border = src.border
	if src.border_width > 0    do out.border_width = src.border_width
	if src.radius > 0          do out.radius = src.radius
	if src.padding != {}       do out.padding = src.padding
	if src.font_size > 0       do out.font_size = src.font_size
	if len(src.font) > 0       do out.font = src.font
	if src.weight > 0          do out.weight = src.weight
	if src.line_height > 0     do out.line_height = src.line_height
	if src.opacity > 0         do out.opacity = src.opacity
	if src.shadow != {}        do out.shadow = src.shadow
	if src.selection != {}     do out.selection = src.selection
	if src.text_align != .Auto do out.text_align = src.text_align
}
```

Note: `resolve_themed_aspect` (added in #142's earlier work) has the same `overlay` proc inline. If the existing one is reusable as a free helper, extract it; otherwise the duplication here is acceptable scope (a future refactor can consolidate).

- [ ] **Step 5: Build + smoke**

```bash
./build-dev.sh
./build/redin test/ui/scrollbar_drag_app.fnl &
sleep 2
bb test/ui/run.bb test/ui/test_scrollbar_drag.bb
curl -s -X POST -H "Authorization: Bearer $(cat .redin-token)" "http://localhost:$(cat .redin-port)/shutdown" > /dev/null 2>&1
wait 2>/dev/null
```

Expected: same as Task 2 (1 pass, 5 fail). The bar now renders via theme, but interaction still isn't wired.

- [ ] **Step 6: Commit**

```bash
git add src/redin/input/scrollbar.odin src/redin/render.odin src/runtime/theme.fnl src/redin/runtime.odin
git commit -m "$(cat <<'EOF'
feat(scrollbar): state types + theme-driven bar rendering

Scrollbar_State union in input/scrollbar.odin (parallel to Drag_State,
not folded in — the existing one carries app-level payload/animate
fields that don't apply here). apply_scrollbar stubbed at this point;
wired into runtime.odin between apply_listeners and set_hover_cursor.

Bar rendering in draw_box_children now resolves :scrollbar + #hover +
#active state variants via a small helper. Default styling moves out
of the render path into runtime/theme.fnl.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Hover state + cursor swap

**Files:**
- Modify: `src/redin/input/scrollbar.odin`
- Modify: `src/redin/input/input.odin`

- [ ] **Step 1: Replace the stub with hover-only logic**

In `src/redin/input/scrollbar.odin`, replace `apply_scrollbar` with:

```odin
apply_scrollbar :: proc(
	events:         []types.InputEvent,
	nodes:          []types.Node,
	node_rects:     []rl.Rectangle,
	scroll_info:    map[int]types.Scroll_Info,
	scroll_offsets: ^map[int]f32,
	theme:          map[string]types.Theme,
) -> (consumed_press: bool) {
	// Re-flatten safety: container_idx may no longer exist.
	if idx := scrollbar_container_idx(); idx >= 0 && idx >= len(node_rects) {
		scrollbar = nil
	}

	mouse := mouse_pos()

	// Pre-compute gutter rects for every scrollable node that needs a
	// visible bar. The map lookup is O(1) per node and bounded by the
	// number of nodes we already iterate, so the cost is dominated by
	// the existing per-frame layout pass.
	hovered_idx := -1
	hovered_axis: Scrollbar_Axis = .Y

	for idx, info in scroll_info {
		if idx < 0 || idx >= len(node_rects) do continue
		container := node_rects[idx]
		bar_w := f32(scrollbar_bar_thickness(theme))

		// Y axis: gutter is the right edge of the container, full height.
		if info.total > container.height {
			gutter := rl.Rectangle{
				container.x + container.width - bar_w - 4,  // -4 = hit-zone padding
				container.y,
				bar_w + 8,                                   // +8 = +4 on each side
				container.height,
			}
			if rl.CheckCollisionPointRec(mouse, gutter) {
				hovered_idx = idx
				hovered_axis = .Y
				break
			}
		}
		// X axis: gutter is the bottom edge, full width.
		if info.total > container.width {
			gutter := rl.Rectangle{
				container.x,
				container.y + container.height - bar_w - 4,
				container.width,
				bar_w + 8,
			}
			if rl.CheckCollisionPointRec(mouse, gutter) {
				hovered_idx = idx
				hovered_axis = .X
				break
			}
		}
	}

	if hovered_idx >= 0 {
		if _, is_dragging := scrollbar.(Scrollbar_Dragging); !is_dragging {
			scrollbar = Scrollbar_Hovering{
				container_idx = hovered_idx,
				axis          = hovered_axis,
			}
		}
	} else {
		if _, is_dragging := scrollbar.(Scrollbar_Dragging); !is_dragging {
			scrollbar = nil
		}
	}

	return false
}

scrollbar_bar_thickness :: proc(theme: map[string]types.Theme) -> int {
	if t, ok := theme["scrollbar"]; ok && t.border_width > 0 {
		return int(t.border_width)
	}
	return 4
}
```

- [ ] **Step 2: Extend `set_hover_cursor` precedence**

In `src/redin/input/input.odin`, find `set_hover_cursor` (around line 532). At the very top of its body (before the existing `drag` switch), add:

```odin
	switch s in scrollbar {
	case Scrollbar_Hovering:
		set_cursor(s.axis == .Y ? .RESIZE_NS : .RESIZE_EW)
		return
	case Scrollbar_Dragging:
		set_cursor(s.axis == .Y ? .RESIZE_NS : .RESIZE_EW)
		return
	}
```

- [ ] **Step 3: Run the test — expect `cursor-on-thumb-is-resize-ns` to PASS**

```bash
./build-dev.sh
./build/redin test/ui/scrollbar_drag_app.fnl &
sleep 2
bb test/ui/run.bb test/ui/test_scrollbar_drag.bb
curl -s -X POST -H "Authorization: Bearer $(cat .redin-token)" "http://localhost:$(cat .redin-port)/shutdown" > /dev/null 2>&1
wait 2>/dev/null
```

Expected:
- `scroll-info-reports-list` PASS
- `cursor-on-thumb-is-resize-ns` PASS (newly)
- `drag-thumb-changes-scroll`, `click-below-thumb-pages-down`, `click-above-thumb-pages-up`, `drag-survives-cursor-off-gutter` FAIL — drag interaction still missing.

- [ ] **Step 4: Commit**

```bash
git add src/redin/input/scrollbar.odin src/redin/input/input.odin
git commit -m "$(cat <<'EOF'
feat(scrollbar): hover state + cursor swap

apply_scrollbar walks scrollable nodes each frame, hit-tests the bar
gutter (visible bar + 4px tolerance each side), and enters
Scrollbar_Hovering for the deepest match. set_hover_cursor honours
the state and swaps to RESIZE_NS / RESIZE_EW per axis. Bar's #hover
overlay also kicks in via the theme path wired in the previous task.

Cursor stays default outside the gutter; drag interaction follows
in the next task.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Drag-math unit test + implementation

**Files:**
- Create: `src/redin/input/scrollbar_test.odin`
- Modify: `src/redin/input/scrollbar.odin`

- [ ] **Step 1: Write the failing unit test**

Create `src/redin/input/scrollbar_test.odin`:

```odin
package input

import "core:testing"
import "../types"

@(test)
test_drag_math_proportional :: proc(t: ^testing.T) {
	// Gutter at y=50..250 (h=200). Total content 900 → max_scroll=700.
	// Thumb height = 200 * (200/900) ≈ 44.44. max_thumb_y = 250 - 44.44.
	// Cursor drags from thumb-center down by 50px. Expected offset
	// delta: 50 / (200 - 44.44) * 700 ≈ 224.9.
	container_h: f32 = 200
	total: f32       = 900
	thumb_h          := f32(container_h * (container_h / total))
	max_thumb_travel := container_h - thumb_h
	max_scroll       := total - container_h

	new_thumb_y := f32(50)              // dragged 50px from gutter top
	expected    := new_thumb_y / max_thumb_travel * max_scroll
	got         := drag_offset_for_thumb_y(new_thumb_y, max_thumb_travel, max_scroll)

	testing.expect_value(t, got, expected)
}

@(test)
test_drag_math_clamps_at_zero :: proc(t: ^testing.T) {
	// Cursor above the gutter → thumb_y clamped to 0 → offset 0.
	got := drag_offset_for_thumb_y(-10, 155.56, 700)
	testing.expect_value(t, got, f32(0))
}

@(test)
test_drag_math_clamps_at_max :: proc(t: ^testing.T) {
	// Cursor past the gutter bottom → thumb_y clamped to max_thumb_travel
	// → offset = max_scroll.
	got := drag_offset_for_thumb_y(999, 155.56, 700)
	testing.expect_value(t, got, f32(700))
}
```

- [ ] **Step 2: Run the test — expect FAIL**

```bash
odin test src/redin/input -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
```

Expected: build fails because `drag_offset_for_thumb_y` is undefined.

- [ ] **Step 3: Implement `drag_offset_for_thumb_y`**

In `src/redin/input/scrollbar.odin`, add at the bottom of the file:

```odin
// Pure drag-math: map a new thumb top-y (relative to gutter top) to the
// corresponding scroll offset. Clamps both endpoints. Pure function;
// tested in scrollbar_test.odin.
drag_offset_for_thumb_y :: proc(
	new_thumb_y_in_gutter: f32,
	max_thumb_travel: f32,
	max_scroll: f32,
) -> f32 {
	if max_thumb_travel <= 0 || max_scroll <= 0 do return 0
	y := new_thumb_y_in_gutter
	if y < 0                 do y = 0
	if y > max_thumb_travel  do y = max_thumb_travel
	return y / max_thumb_travel * max_scroll
}
```

- [ ] **Step 4: Run the test — expect PASS**

```bash
odin test src/redin/input -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
```

Expected: all 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/redin/input/scrollbar.odin src/redin/input/scrollbar_test.odin
git commit -m "$(cat <<'EOF'
feat(scrollbar): drag-offset math helper + unit tests

drag_offset_for_thumb_y is the pure math used by apply_scrollbar to
turn a cursor's y into a scroll offset. Three unit tests cover the
happy path (proportional within bounds) and both clamps (above the
gutter → 0, past the bottom → max_scroll).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Thumb-drag state machine

**Files:**
- Modify: `src/redin/input/scrollbar.odin`

- [ ] **Step 1: Implement press/move/release transitions**

In `src/redin/input/scrollbar.odin`, replace `apply_scrollbar`'s body with the full version that also handles dragging:

```odin
apply_scrollbar :: proc(
	events:         []types.InputEvent,
	nodes:          []types.Node,
	node_rects:     []rl.Rectangle,
	scroll_info:    map[int]types.Scroll_Info,
	scroll_offsets: ^map[int]f32,
	theme:          map[string]types.Theme,
) -> (consumed_press: bool) {
	// Re-flatten safety.
	if idx := scrollbar_container_idx(); idx >= 0 && idx >= len(node_rects) {
		scrollbar = nil
	}

	mouse := mouse_pos()
	bar_w := f32(scrollbar_bar_thickness(theme))

	// Currently dragging? Update offset based on cursor y.
	if drag_state, dragging := scrollbar.(Scrollbar_Dragging); dragging {
		container := node_rects[drag_state.container_idx]
		info := scroll_info[drag_state.container_idx]

		if drag_state.axis == .Y && info.total > container.height {
			gutter_top := container.y
			thumb_h    := max(container.height * (container.height / info.total), 20)
			max_thumb  := container.height - thumb_h
			max_scroll := info.total - container.height
			new_y_in_gutter := mouse.y - gutter_top - drag_state.grab_offset_in_thumb
			scroll_offsets[drag_state.container_idx] = drag_offset_for_thumb_y(
				new_y_in_gutter, max_thumb, max_scroll,
			)
		} else if drag_state.axis == .X && info.total > container.width {
			gutter_left := container.x
			thumb_w    := max(container.width * (container.width / info.total), 20)
			max_thumb  := container.width - thumb_w
			max_scroll := info.total - container.width
			new_x_in_gutter := mouse.x - gutter_left - drag_state.grab_offset_in_thumb
			scroll_offsets[drag_state.container_idx] = drag_offset_for_thumb_y(
				new_x_in_gutter, max_thumb, max_scroll,
			)
		}

		// Release ends the drag.
		if is_mouse_button_released(.LEFT) {
			scrollbar = Scrollbar_Hovering{
				container_idx = drag_state.container_idx,
				axis          = drag_state.axis,
			}
		}
		return false  // consumed_press is for the press frame only
	}

	// Hit-test gutters for hover + press.
	hovered_idx := -1
	hovered_axis: Scrollbar_Axis = .Y
	for idx, info in scroll_info {
		if idx < 0 || idx >= len(node_rects) do continue
		container := node_rects[idx]
		if info.total > container.height {
			gutter := rl.Rectangle{
				container.x + container.width - bar_w - 4,
				container.y, bar_w + 8, container.height,
			}
			if rl.CheckCollisionPointRec(mouse, gutter) {
				hovered_idx = idx
				hovered_axis = .Y
				break
			}
		}
		if info.total > container.width {
			gutter := rl.Rectangle{
				container.x, container.y + container.height - bar_w - 4,
				container.width, bar_w + 8,
			}
			if rl.CheckCollisionPointRec(mouse, gutter) {
				hovered_idx = idx
				hovered_axis = .X
				break
			}
		}
	}

	// Press on a gutter → start drag (if on thumb) or page jump (if outside).
	if hovered_idx >= 0 {
		for event in events {
			me, ok := event.(types.MouseEvent)
			if !ok || me.button != .LEFT do continue

			container := node_rects[hovered_idx]
			info := scroll_info[hovered_idx]
			cur_off := scroll_offsets[hovered_idx]

			if hovered_axis == .Y {
				gutter_top := container.y
				thumb_h    := max(container.height * (container.height / info.total), 20)
				max_thumb  := container.height - thumb_h
				max_scroll := info.total - container.height
				thumb_y    := gutter_top + (cur_off / max_scroll if max_scroll > 0 else 0) * max_thumb

				if mouse.y >= thumb_y && mouse.y <= thumb_y + thumb_h {
					scrollbar = Scrollbar_Dragging{
						hovering = Scrollbar_Hovering{
							container_idx = hovered_idx, axis = .Y,
						},
						grab_offset_in_thumb = mouse.y - thumb_y,
					}
				} else if mouse.y < thumb_y {
					new := cur_off - container.height
					if new < 0 do new = 0
					scroll_offsets[hovered_idx] = new
				} else {
					new := cur_off + container.height
					if new > max_scroll do new = max_scroll
					scroll_offsets[hovered_idx] = new
				}
				consumed_press = true
			} else {
				gutter_left := container.x
				thumb_w    := max(container.width * (container.width / info.total), 20)
				max_thumb  := container.width - thumb_w
				max_scroll := info.total - container.width
				thumb_x    := gutter_left + (cur_off / max_scroll if max_scroll > 0 else 0) * max_thumb

				if mouse.x >= thumb_x && mouse.x <= thumb_x + thumb_w {
					scrollbar = Scrollbar_Dragging{
						hovering = Scrollbar_Hovering{
							container_idx = hovered_idx, axis = .X,
						},
						grab_offset_in_thumb = mouse.x - thumb_x,
					}
				} else if mouse.x < thumb_x {
					new := cur_off - container.width
					if new < 0 do new = 0
					scroll_offsets[hovered_idx] = new
				} else {
					new := cur_off + container.width
					if new > max_scroll do new = max_scroll
					scroll_offsets[hovered_idx] = new
				}
				consumed_press = true
			}
			break  // only first press matters
		}

		if _, is_dragging := scrollbar.(Scrollbar_Dragging); !is_dragging {
			scrollbar = Scrollbar_Hovering{
				container_idx = hovered_idx, axis = hovered_axis,
			}
		}
	} else {
		if _, is_dragging := scrollbar.(Scrollbar_Dragging); !is_dragging {
			scrollbar = nil
		}
	}

	return consumed_press
}
```

- [ ] **Step 2: Build + run UI tests**

```bash
./build-dev.sh
./build/redin test/ui/scrollbar_drag_app.fnl &
sleep 2
bb test/ui/run.bb test/ui/test_scrollbar_drag.bb
curl -s -X POST -H "Authorization: Bearer $(cat .redin-token)" "http://localhost:$(cat .redin-port)/shutdown" > /dev/null 2>&1
wait 2>/dev/null
```

Expected:
- `scroll-info-reports-list` PASS
- `cursor-on-thumb-is-resize-ns` PASS
- `drag-thumb-changes-scroll` PASS (newly)
- `click-below-thumb-pages-down` PASS (newly)
- `click-above-thumb-pages-up` PASS (newly)
- `drag-survives-cursor-off-gutter` PASS (newly — the dragging state doesn't gate on gutter membership)

If any of the four newly-expected tests still fails, the offsets in the test are tight (the drag math is precise but the test allows ±25 slack). Investigate before continuing.

- [ ] **Step 3: Commit**

```bash
git add src/redin/input/scrollbar.odin
git commit -m "$(cat <<'EOF'
feat(scrollbar): thumb-drag + page-jump on gutter click

apply_scrollbar's full state machine:
- Press inside thumb → enter Scrollbar_Dragging with grab_offset.
- Press in gutter above thumb → page-up by one container height.
- Press in gutter below thumb → page-down by one container height.
- Mouse-move while dragging → update scroll_offsets[idx] via the
  pure drag_offset_for_thumb_y helper. Survives cursor leaving the
  gutter horizontally.
- Release → fall back to Scrollbar_Hovering, then nil if cursor is
  no longer over a gutter.

Closes the user-visible portion of #143; the next task gates other
input consumers so a press on the bar doesn't also fire clicks /
selections / app-level drags on whatever sits behind it.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Gate other input consumers while scrollbar consumed press

**Files:**
- Modify: `src/redin/runtime.odin`
- Modify: `src/redin/input/apply.odin`
- Modify: `src/redin/input/drag.odin`
- Modify: `src/redin/input/text_select.odin`

- [ ] **Step 1: Thread `consumed_press` through `runtime.odin`**

In `src/redin/runtime.odin`, the current call (added in Task 3 Step 2) discards the return:

```odin
scrollbar_consumed := input.apply_scrollbar(...)
_ = scrollbar_consumed
```

Pass it into the dependent input procs. `apply_listeners` and friends already iterate `input_events` themselves; the simplest gating is a package-level flag that they consult. Add to `input/input.odin` near `current_cursor`:

```odin
// True for the rest of the frame after apply_scrollbar consumed a
// press. Other consumers (apply_listeners, process_text_selection,
// drag_update) skip their MouseEvent paths so a press on the bar
// doesn't also fire clicks / selections / app-drags on whatever sits
// behind the scrollbar.
scrollbar_consumed_press: bool
```

Set it from `apply_scrollbar`:

```odin
// At the end of apply_scrollbar, before the return:
scrollbar_consumed_press = consumed_press
return consumed_press
```

Reset at frame start. Add to `apply_scrollbar`'s top (just inside the proc):

```odin
scrollbar_consumed_press = false
```

So the flag is true only during the same-frame window after press detection.

- [ ] **Step 2: Skip click dispatch in `apply.odin`**

In `src/redin/input/apply.odin`, find `apply_listeners`'s MouseEvent case. Add at the very top of the case body:

```odin
		case types.MouseEvent:
			if scrollbar_consumed_press do continue
			if e.button != .LEFT do continue
```

(Inserting `if scrollbar_consumed_press do continue` as the first line of the case.)

- [ ] **Step 3: Skip selection-start in `text_select.odin`**

In `src/redin/input/text_select.odin`, find the MouseEvent branch (around line 33 — the `me, is_mouse := event.(types.MouseEvent)` pattern). After the type check, add:

```odin
		me, is_mouse := event.(types.MouseEvent)
		if !is_mouse do continue
		if scrollbar_consumed_press do continue
```

- [ ] **Step 4: Skip drag start in `drag.odin`**

In `src/redin/input/drag.odin`, the transition `nil → Drag_Pending` lives in the `case nil, Drag_Idle:` arm around line 171. Read the enclosing proc signature first (`grep -n "^\\w.*::.*proc" src/redin/input/drag.odin` lists them) to know whether `return` needs a value. In current code the proc is void; if that's still true, plain `return` works. Add at the top of that case:

```odin
	case nil, Drag_Idle:
		if scrollbar_consumed_press do return
```

- [ ] **Step 5: Run tests**

```bash
./build-dev.sh
./build/redin test/ui/scrollbar_drag_app.fnl &
sleep 2
bb test/ui/run.bb test/ui/test_scrollbar_drag.bb
curl -s -X POST -H "Authorization: Bearer $(cat .redin-token)" "http://localhost:$(cat .redin-port)/shutdown" > /dev/null 2>&1
wait 2>/dev/null

# And the full UI suite, to confirm no regression in click/selection/drag tests
bash test/ui/run-all.sh 2>&1 | tail -8
```

Expected: scrollbar tests all 6 PASS. Full suite green.

- [ ] **Step 6: Commit**

```bash
git add src/redin/input/scrollbar.odin src/redin/input/apply.odin \
  src/redin/input/text_select.odin src/redin/input/drag.odin
git commit -m "$(cat <<'EOF'
feat(scrollbar): gate clicks / selection / app-drag on consumed press

A press on the scrollbar gutter shouldn't also fire a click on the
content behind it, start text selection, or begin an app-level drag.
apply_scrollbar sets a package-level scrollbar_consumed_press flag for
the frame; apply_listeners, process_text_selection, and drag_update
short-circuit when it's set.

The flag resets at the top of every apply_scrollbar call so it lives
only for the frame that owns the press.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: State cleanup on shutdown

**Files:**
- Modify: `src/redin/input/state.odin`

- [ ] **Step 1: Reset `scrollbar` in `state_destroy`**

In `src/redin/input/state.odin`, find the existing `delete(hovered_indices); hovered_indices = {}` lines in `state_destroy` (added during the #hover/#active work). Add three more sibling resets immediately after:

```odin
delete(hovered_indices)
hovered_indices = {}
scrollbar = nil
scrollbar_consumed_press = false
current_cursor = .DEFAULT
```

- [ ] **Step 2: Build + run full suite under REDIN_TRACK_MEM**

`./build-dev.sh` bakes in `REDIN_TRACK_MEM`. The smoke test will dump a leak report on shutdown.

```bash
./build-dev.sh
./build/redin test/ui/smoke_app.fnl > /tmp/smk.log 2>&1 &
sleep 2
curl -s -X POST -H "Authorization: Bearer $(cat .redin-token)" "http://localhost:$(cat .redin-port)/shutdown" > /dev/null
wait 2>/dev/null
grep -E "leak|allocation" /tmp/smk.log | head
```

Expected: no leak related to scrollbar state. `Scrollbar_State` is a union of structs (no heap pointers) so no `delete()` needed — the `scrollbar = nil` is for hygiene.

- [ ] **Step 3: Commit**

```bash
git add src/redin/input/state.odin
git commit -m "$(cat <<'EOF'
chore(input): reset scrollbar state on shutdown

scrollbar / scrollbar_consumed_press / current_cursor are stateless in
the heap-allocation sense (no [dynamic] backings to free), but
state_destroy is the canonical reset point and the symmetry with
focused_idx / active_idx / hovered_indices is worth keeping.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Documentation

**Files:**
- Modify: `docs/reference/theme.md`
- Modify: `docs/core-api.md`

- [ ] **Step 1: Document `:scrollbar` in `docs/reference/theme.md`**

Find the existing list of state-variant-bearing aspects. Add an entry for `:scrollbar`:

```markdown
#### `:scrollbar`

Bar drawn at the right (`scroll-y`) or bottom (`scroll-x`) edge of a
scrollable container. Supported state variants: `#hover` and `#active`.

| Field          | Meaning |
|----------------|---------|
| `:bg`          | Thumb fill colour (`[r g b]`). |
| `:opacity`     | Thumb alpha (0..1). Default 0.47 — light grey, sits visually quiet on most backgrounds. |
| `:radius`      | Thumb corner radius. Default 2. |
| `:border-width`| Bar thickness in pixels. Default 4. |

`#hover` fires while the cursor is over the bar gutter (visible bar + 4px
each side). `#active` fires while the bar is being dragged. Active wins
over hover when both apply, CSS-style.

Defaults bundled in `src/runtime/theme.fnl`:

```fennel
:scrollbar         {:bg [200 200 200] :opacity 0.47 :radius 2 :border-width 4}
:scrollbar#hover   {:bg [200 200 200] :opacity 0.71}
:scrollbar#active  {:bg [230 230 230] :opacity 0.78}
```
```

- [ ] **Step 2: Document the endpoints in `docs/core-api.md`**

The /scroll-info and /cursor rows were added to the table in Task 1. Confirm they're present; if not, add them now.

- [ ] **Step 3: Commit**

```bash
git add docs/reference/theme.md docs/core-api.md
git commit -m "$(cat <<'EOF'
docs(theme): document :scrollbar aspect family

Scrollbar appearance is themable via :scrollbar / :scrollbar#hover /
:scrollbar#active. :border-width controls bar thickness; :opacity
controls translucency (default 0.47 mirrors the previous hardcoded
alpha of 120/255).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Full verification

**Files:** none

- [ ] **Step 1: Full UI suite**

```bash
bash test/ui/run-all.sh
```

Expected: all suites pass, including the new `test_scrollbar_drag`.

- [ ] **Step 2: Fennel runtime unit tests**

```bash
luajit test/lua/runner.lua test/lua/test_*.fnl
```

Expected: all pass (theme defaults are checked here).

- [ ] **Step 3: Odin unit tests**

```bash
odin test src/redin/input -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
```

Expected: drag-math tests pass + all existing input tests still pass.

- [ ] **Step 4: Release build check**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin-release
```

Expected: clean. Confirms the feature doesn't depend on REDIN_DEV-gated paths.

- [ ] **Step 5: Manual smoke — kitchen-sink**

```bash
./build/redin examples/kitchen-sink.fnl &
```

Manually:
1. Hover the cursor over the scrollbar — cursor should swap to vertical-resize, bar tint should shift slightly.
2. Click the bar thumb and drag — list should scroll proportionally.
3. Click in the gutter below the thumb — list should jump down by one container height.
4. Click in the gutter above the thumb — list should jump up by one container height.

```bash
curl -X POST -H "Authorization: Bearer $(cat .redin-token)" "http://localhost:$(cat .redin-port)/shutdown" || true
wait
```

- [ ] **Step 6: No commit needed**

Verification-only task.
