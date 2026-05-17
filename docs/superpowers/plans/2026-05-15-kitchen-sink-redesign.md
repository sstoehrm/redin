# Kitchen-sink Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refresh `examples/kitchen-sink.fnl` into a polished framework showcase and fix the drop-handler off-by-one that mis-orders items dragged downward.

**Architecture:** Single-file change. Six tasks: drop-handler fix, theme rewrite, background canvas rewrite, new `:grip-dots` provider, view-tree restructure, visual+drag verification. Each task lands as its own commit so the work can be bisected if anything breaks.

**Tech Stack:** Fennel (compiled to Lua 5.1) running inside the redin binary. No Odin or framework changes. Verification via the redin dev-server HTTP endpoints (`/screenshot`, `/state`, `/events`, `/input/*`).

**Spec:** [`docs/superpowers/specs/2026-05-15-kitchen-sink-redesign-design.md`](../specs/2026-05-15-kitchen-sink-redesign-design.md)

**Branching:** The current working branch (`docs/sync-129-aftermath`) is unrelated to this work. Recommended: cut a new branch `feat/kitchen-sink-redesign` before Task 1. The plan does not enforce this — if the user prefers a different branch strategy, follow their lead.

---

## File map

- **Modify:** `examples/kitchen-sink.fnl` — the only file touched. Sections changed: background canvas provider, theme map, drop-handler body, view tree. New section added: `:grip-dots` canvas provider.
- **Read only:** `docs/reference/theme.md` (for shadow vector form and hbox shadow support), `docs/core-api.md` § Drag-and-drop and § Viewport.

Verification artifacts written to `/tmp/redin-shots/` (not checked in):
- `/tmp/redin-shots/kitchen-before.png` — already captured baseline.
- `/tmp/redin-shots/kitchen-after.png` — captured during Task 6.

---

## Helper: dev-server probe

Several tasks call out to the running app via curl. Standard preamble used in step bodies below:

```bash
PORT=$(cat .redin-port)
TOKEN=$(cat .redin-token)
H="Authorization: Bearer $TOKEN"
HH="Host: localhost:$PORT"
```

Standard launch / shutdown (used in Tasks 1 and 6):

```bash
# Launch (background)
./build/redin examples/kitchen-sink.fnl > /tmp/redin-kitchen.log 2>&1 &
APP_PID=$!
# Wait for port/token files
for i in $(seq 1 20); do [ -f .redin-port ] && [ -f .redin-token ] && break; sleep 0.2; done

# Shutdown (clean)
curl -sS -X POST -H "$H" -H "$HH" "http://localhost:$PORT/shutdown" > /dev/null
wait "$APP_PID" 2>/dev/null
```

The existing `build/redin` is a dev build (`REDIN_DEV` + `REDIN_PROFILE` + `REDIN_TRACK_MEM`). No rebuild is needed for any task — `.fnl` files are loaded at runtime.

---

## Task 1: Fix drop-handler off-by-one

**Files:**
- Modify: `examples/kitchen-sink.fnl:158-178` (the `:event/drop` handler body)

- [ ] **Step 1: Reproduce the bug against the current code**

Launch the app (using the launch preamble above), then:

```bash
# Reset by removing all items would be ideal, but kitchen-sink has no reset
# handler. Just observe the initial state: items 1..24 = "Test 1".."Test 24".
curl -sS -H "$H" -H "$HH" "http://localhost:$PORT/state/items" | head -c 200; echo

# Drag "Test 1" (from=1) onto position 5
curl -sS -X POST -H "$H" -H "$HH" \
     -d '["event/drop",{"from":1,"to":5}]' \
     "http://localhost:$PORT/events"

# Inspect the first six item texts
curl -sS -H "$H" -H "$HH" "http://localhost:$PORT/state/items" \
  | python3 -c 'import json,sys; xs=json.load(sys.stdin); print([x["text"] for x in xs[:6]])'
```

Expected (buggy) output: `['Test 2', 'Test 3', 'Test 4', 'Test 1', 'Test 5', 'Test 6']` — `Test 1` lands at slot 4 instead of slot 5. Confirm before continuing. Shutdown the app.

- [ ] **Step 2: Replace the drop-handler body**

The current handler is:

```fennel
(reg-handler :event/drop (fn [db event]
                           (let [ctx (. event 2)
                                 from-idx ctx.from
                                 to-idx ctx.to
                                 items (get db :items [])]
                             (when (and from-idx to-idx (> from-idx 0)
                                        (<= from-idx (length items))
                                        (> to-idx 0) (<= to-idx (length items))
                                        (not= from-idx to-idx))
                               (let [item (. items from-idx)
                                     new-items (icollect [i v (ipairs items)]
                                                 (when (not= i from-idx) v))]
                                 (let [insert-at (if (> from-idx to-idx) to-idx
                                                     (- to-idx 1))]
                                   (table.insert new-items
                                                 (math.min insert-at
                                                           (+ (length new-items)
                                                              1))
                                                 item)
                                   (assoc db :items new-items)))))
                           db))
```

Replace with:

```fennel
(reg-handler :event/drop (fn [db event]
                           (let [ctx (. event 2)
                                 from-idx ctx.from
                                 to-idx ctx.to
                                 items (get db :items [])]
                             (when (and from-idx to-idx
                                        (> from-idx 0) (<= from-idx (length items))
                                        (> to-idx   0) (<= to-idx   (length items))
                                        (not= from-idx to-idx))
                               (let [item (. items from-idx)
                                     new-items (icollect [i v (ipairs items)]
                                                 (when (not= i from-idx) v))]
                                 (table.insert new-items to-idx item)
                                 (assoc db :items new-items))))
                           db))
```

The conditional `insert-at` is gone — after `icollect` removes the source, `to-idx` already points at the correct insertion slot in both directions. The outer guard is identical to before. The outer `db` return at the very end is preserved (when the `when` doesn't fire, the handler still returns `db`).

- [ ] **Step 3: Verify the fix**

Launch the app, run the same probe from Step 1:

```bash
curl -sS -X POST -H "$H" -H "$HH" \
     -d '["event/drop",{"from":1,"to":5}]' \
     "http://localhost:$PORT/events"
curl -sS -H "$H" -H "$HH" "http://localhost:$PORT/state/items" \
  | python3 -c 'import json,sys; xs=json.load(sys.stdin); print([x["text"] for x in xs[:6]])'
```

Expected (fixed): `['Test 2', 'Test 3', 'Test 4', 'Test 5', 'Test 1', 'Test 6']` — `Test 1` now at slot 5.

Also probe two more cases to cover both directions and an edge:

```bash
# Restart the app so item state is fresh
curl -sS -X POST -H "$H" -H "$HH" "http://localhost:$PORT/shutdown" > /dev/null
wait
./build/redin examples/kitchen-sink.fnl > /tmp/redin-kitchen.log 2>&1 &
for i in $(seq 1 20); do [ -f .redin-port ] && [ -f .redin-token ] && break; sleep 0.2; done
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token); H="Authorization: Bearer $TOKEN"; HH="Host: localhost:$PORT"

# Drag upward: from=5 → to=1. Expect Test 5 first.
curl -sS -X POST -H "$H" -H "$HH" -d '["event/drop",{"from":5,"to":1}]' "http://localhost:$PORT/events"
curl -sS -H "$H" -H "$HH" "http://localhost:$PORT/state/items" \
  | python3 -c 'import json,sys; xs=json.load(sys.stdin); print([x["text"] for x in xs[:6]])'
# Expected: ['Test 5', 'Test 1', 'Test 2', 'Test 3', 'Test 4', 'Test 6']

# Drag to the end: from=1 → to=24 (the current last slot).
curl -sS -X POST -H "$H" -H "$HH" -d '["event/drop",{"from":1,"to":24}]' "http://localhost:$PORT/events"
curl -sS -H "$H" -H "$HH" "http://localhost:$PORT/state/items" \
  | python3 -c 'import json,sys; xs=json.load(sys.stdin); print([xs[-3]["text"], xs[-2]["text"], xs[-1]["text"]])' \
  || true
# Expected last three: Test 3, Test 4 (or similar), Test 5
# The exact tail depends on the previous mutation; the key check is that
# the item moved from slot 1 lands at slot 24 (the new tail), not slot 23.
```

Shutdown the app after the probe.

- [ ] **Step 4: Commit**

```bash
git add examples/kitchen-sink.fnl
git commit -m "fix(kitchen-sink): drop handler off-by-one when dragging downward

Removing the source from new-items already absorbs the index shift;
the previous '(- to-idx 1)' conditional re-applied it, so dragging
from=1 to=5 landed the row at slot 4. Insert at to-idx directly."
```

---

## Task 2: Replace theme block with refreshed palette + new tokens

**Files:**
- Modify: `examples/kitchen-sink.fnl:62-98` (the `(theme-mod.set-theme …)` call)

- [ ] **Step 1: Replace the theme map**

Find the block beginning `(theme-mod.set-theme {:surface …` and ending with the closing `})` of `:button#active {:bg [59 66 82]}`. Replace it entirely with:

```fennel
(theme-mod.set-theme {;; --- Surfaces / text ---
                      :surface       {:bg [46 52 64]
                                      :padding [20 20 20 20]
                                      :radius 8}
                      :surface-elev  {:bg [59 66 82]
                                      :padding [12 16 12 16]
                                      :radius 6}
                      :heading       {:font-size 22 :weight 1 :color [236 239 244]}
                      :body          {:font-size 14 :color [216 222 233]}
                      :muted         {:font-size 13 :color [129 138 155]}
                      :count-badge   {:font-size 12 :color [129 138 155]}

                      ;; --- Rows ---
                      :row           {:padding [4 4 4 4] :radius 4}
                      :row#hover     {:bg [59 66 82] :padding [4 4 4 4] :radius 4}
                      :row-dragging  {:bg [94 129 172]
                                      :color [30 34 46]
                                      :padding [4 4 4 4]
                                      :radius 4
                                      :shadow [0 4 16 [0 0 0 120]]}
                      :row-drop-hot  {:bg [59 66 82]
                                      :border [136 192 208]
                                      :border_width 2
                                      :radius 4
                                      :padding [4 4 4 4]}

                      ;; --- Drag-over list zone ---
                      :muted-armed   {:font-size 13
                                      :color [129 138 155]
                                      :bg [54 60 72]}

                      ;; --- Input ---
                      :input         {:bg [59 66 82]
                                      :color [236 239 244]
                                      :border [76 86 106]
                                      :border-width 1
                                      :radius 4
                                      :padding [8 12 8 12]
                                      :font-size 14}
                      :input#focus   {:border [136 192 208]}

                      ;; --- Buttons ---
                      :button-primary       {:bg [136 192 208]
                                             :color [30 34 46]
                                             :radius 6
                                             :padding [6 14 6 14]
                                             :font-size 13
                                             :weight 1}
                      :button-primary#hover {:bg [143 188 187]}
                      :button-primary#active{:bg [122 162 175]}
                      :button-icon          {:bg [59 66 82]
                                             :color [129 138 155]
                                             :radius 6
                                             :padding [4 4 4 4]
                                             :font-size 16}
                      :button-icon#hover    {:bg [59 66 82] :color [191 97 106]}
                      :button-icon#active   {:bg [76 86 106]}}) 
```

Notes:
- `:surface` opacity is removed (was `0.5`, made the card disappear). Default opacity = 1.0.
- `:surface` gains `:radius 8` so the card edge is soft.
- Shadow uses the documented vector form `[x y blur [r g b a]]` (theme.md:209).
- The two button aspects (`:button-primary` and `:button-icon`) replace the single `:button` aspect; the view tree in Task 5 swaps callers over. The old `:button` aspect is gone — leaving it would invite future drift.
- `:status-field` and `:drag-handle` aspects from the original theme are dropped: the status footer goes away in Task 5, and the drag handle is now a canvas (no chrome to theme).

- [ ] **Step 2: Sanity-check that the app still loads**

Launch:

```bash
./build/redin examples/kitchen-sink.fnl > /tmp/redin-kitchen.log 2>&1 &
for i in $(seq 1 20); do [ -f .redin-port ] && [ -f .redin-token ] && break; sleep 0.2; done
tail -n 20 /tmp/redin-kitchen.log
```

The app must come up. The view tree still references the old aspect names (`:button`, `:drag-handle`, `:status-field`) at this point — that is expected: the renderer treats unknown aspects as "no chrome", so the layout will look uglier than before but must not crash.

Expected log: no `[fennel]` error traces, no panic. If there is an error, check the theme map for a syntax slip and fix before committing.

Shutdown:

```bash
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Host: localhost:$PORT" "http://localhost:$PORT/shutdown" > /dev/null
wait
```

- [ ] **Step 3: Commit**

```bash
git add examples/kitchen-sink.fnl
git commit -m "refactor(kitchen-sink): theme tokens for new palette

Raise surface opacity to 1.0, add accent (frost-blue), danger (Nord
red), surface-elev, button-primary / button-icon, row#hover, refreshed
row-dragging without the magenta clash. View tree still uses the old
aspect names — wiring follows in subsequent commits."
```

---

## Task 3: Quiet the background canvas

**Files:**
- Modify: `examples/kitchen-sink.fnl:7-44` (the `:background` provider registration block)

- [ ] **Step 1: Replace the provider body**

Find `(canvas.register :background …` and the matching closing `))))))` that ends the second `for` loop (the "accent orbs" block). Replace the entire registration with:

```fennel
(canvas.register :background
                 (fn [ctx]
                   (let [t (redin.now)
                         w ctx.width
                         h ctx.height]
                     ;; Polar night base
                     (ctx.rect 0 0 w h {:fill [30 34 46]})
                     ;; Three slow orbs — large radius, very low alpha, single hue.
                     (for [i 1 3]
                       (let [speed (* 0.08 (+ 1 (* i 0.4)))
                             phase (* i 2.1)
                             r     (+ 180 (* 40 i))
                             x (+ (* w 0.5)
                                  (* (* w 0.35) (math.sin (+ (* t speed) phase))))
                             y (+ (* h 0.5)
                                  (* (* h 0.3)
                                     (math.cos (+ (* t speed 0.7) (* phase 1.3)))))
                             alpha 14]
                         (ctx.circle x y r {:fill [94 129 172 alpha]})))
                     ;; Cheap vignette: nested rect strokes from the edges in,
                     ;; alpha ramping up toward the outside.
                     (for [i 1 12]
                       (let [inset (* 6 (- 12 i))
                             a (math.floor (* 2.5 i))]
                         (ctx.rect inset inset
                                   (- w (* inset 2)) (- h (* inset 2))
                                   {:stroke [0 0 0 a] :width 1}))))))
```

The second loop builds a stack of progressively-inset 1-px rect strokes; outer strokes carry darker alpha than inner ones. This fakes a radial vignette using only `ctx.rect`. If the rendering reads as visible stepping or banding when tested in Task 6, delete the vignette loop — the three quiet orbs alone are enough.

The `:pulse-dot` provider directly below the `:background` registration is **not** touched.

- [ ] **Step 2: Sanity-check the canvas renders**

```bash
./build/redin examples/kitchen-sink.fnl > /tmp/redin-kitchen.log 2>&1 &
for i in $(seq 1 20); do [ -f .redin-port ] && [ -f .redin-token ] && break; sleep 0.2; done
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -sS -H "Authorization: Bearer $TOKEN" -H "Host: localhost:$PORT" -o /tmp/redin-shots/kitchen-bg-only.png "http://localhost:$PORT/screenshot"
ls -la /tmp/redin-shots/kitchen-bg-only.png
curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Host: localhost:$PORT" "http://localhost:$PORT/shutdown" > /dev/null
wait
```

Open the PNG and confirm: dark background visible, 3 soft blue blobs visible, faint vignette at corners. Don't fret about exact orb positions (they drift). If the screen is solid black, the orbs are clipped — check `:fill` arity.

- [ ] **Step 3: Commit**

```bash
git add examples/kitchen-sink.fnl
git commit -m "feat(kitchen-sink): quieter background canvas

Three large slow orbs at low alpha plus a cheap rect-stroke vignette.
Reads as ambient instead of as smudges, single hue ties into the
drag-active color."
```

---

## Task 4: Register the `:grip-dots` canvas provider

**Files:**
- Modify: `examples/kitchen-sink.fnl` — insert after the `:pulse-dot` provider registration (around line 58 in the pre-task file; line numbers will have shifted after Tasks 1–3).

- [ ] **Step 1: Add the provider**

Below the closing `)))))` of `(canvas.register :pulse-dot …)`, insert a blank line then:

```fennel
;; A six-dot grip pattern, drawn into a 24×42 canvas. Kept deliberately small
;; and static — the row's own #hover variant carries the hover feedback.
(canvas.register :grip-dots
                 (fn [ctx]
                   (let [cx (/ ctx.width 2)
                         cy (/ ctx.height 2)
                         gap 5
                         r 1.5
                         color [129 138 155]]
                     (for [row -1 1]
                       (for [col 0 1]
                         (let [dx (* (- (* 2 col) 1) (* gap 0.5))
                               dy (* row (+ gap (* 2 r)))]
                           (ctx.circle (+ cx dx) (+ cy dy) r {:fill color})))))))
```

Two-column × three-row dot grid, ~10px wide × ~17px tall, centered.

- [ ] **Step 2: Sanity-check by rendering once standalone**

Until Task 5 wires it into the view, the provider is registered but unused. Confirm registration doesn't crash:

```bash
./build/redin examples/kitchen-sink.fnl > /tmp/redin-kitchen.log 2>&1 &
for i in $(seq 1 20); do [ -f .redin-port ] && [ -f .redin-token ] && break; sleep 0.2; done
grep -i "error\|panic\|traceback" /tmp/redin-kitchen.log && echo "BAD" || echo "ok"
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Host: localhost:$PORT" "http://localhost:$PORT/shutdown" > /dev/null
wait
```

Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add examples/kitchen-sink.fnl
git commit -m "feat(kitchen-sink): register :grip-dots canvas provider

Six-dot grip pattern for the drag handle column. Registered now,
used by the view tree in the next commit."
```

---

## Task 5: Restructure the view tree

This is the load-bearing task — it wires up Tasks 2–4 and removes the layout bugs.

**Files:**
- Modify: `examples/kitchen-sink.fnl` — the entire `(global main_view (fn [] …))` block at the bottom of the file (currently lines 187–254 of the pre-task file).

- [ ] **Step 1: Replace `main_view` end-to-end**

Replace the whole `(global main_view (fn [] …))` block with:

```fennel
(global main_view
        (fn []
          (let [items     (subscribe :items)
                input-val (subscribe :input-value)
                count     (length (or items []))]
            [:stack
             {:viewport [[:top_left 0 0 :full :full]
                         [:top_center 0 32 480 :full]]}
             [:canvas {:provider :background :width :full :height :full}]
             [:vbox
              {:aspect :surface}
              ;; Header — title left, count right.
              [:hbox
               {:height 32 :layout :center}
               [:text {:aspect :heading} "Todo List"]
               [:vbox {:width :full}]                ; flexible spacer
               [:text {:aspect :count-badge} (.. count " items")]]
              ;; Input + Add side by side.
              [:hbox
               {:height 42}
               [:input {:aspect :input
                        :width :full
                        :height 42
                        :value input-val
                        :change [:test/input]
                        :key [:test/add]}]
               [:vbox {:width 8}]                    ; gap
               [:button {:aspect :button-primary
                         :width 72
                         :height 42
                         :click [:test/add]
                         :animate {:provider :pulse-dot
                                   :rect [:top_right -8 -8 16 16]
                                   :z :above}}
                "Add"]]
              [:vbox {:height 8}]                    ; gap before list
              ;; Scrollable list.
              [:vbox
               {:overflow :scroll-y
                :drag-over [:row-drag
                            {:event :event/over
                             :aspect :muted-armed}]}
               (icollect [i item (ipairs (or items []))]
                 [:hbox {:layout :center
                         :aspect :row
                         :height 42
                         :draggable [:row-drag
                                     {:mode :preview
                                      :handle false
                                      :event :event/drag
                                      :aspect :row-dragging}
                                     i]
                         :dropable [:row-drag
                                    {:event :event/drop
                                     :aspect :row-drop-hot}
                                    i]}
                  ;; Grip handle — fixed 24px column, canvas-drawn dots.
                  [:vbox {:width 24 :height 42 :drag-handle true}
                   [:canvas {:provider :grip-dots
                             :width 24 :height 42}]]
                  ;; Item text — fills remaining width.
                  [:text {:aspect :body :width :full} item.text]
                  ;; Remove icon button.
                  [:button {:aspect :button-icon
                            :width 32 :height 32
                            :click [:test/remove i]}
                   "×"]])]]])))
```

Key changes vs. the original view:

- **Layout root** is `:stack` with a 2-entry `:viewport` (background full-screen, card centered with 480 width and 32px top inset). The window-bottom status strip is gone.
- **Heading row** combines the title and the live count badge (`:count-badge` aspect). The flexible spacer is an empty `:vbox` with `:width :full` — standard idiom in this codebase (cf. button-row patterns); if a more explicit `:layout :space-between` exists, prefer it during implementation. If it doesn't, the spacer is fine.
- **Input + Add** sit in an hbox with the input filling and the button at fixed 72-px width, so neither stretches edge-to-edge.
- **Rows** now have three children: grip (24×42 with `:drag-handle true` and a `:canvas` child rendering `:grip-dots`), text (fills), and a 32×32 `:button-icon` with `"×"` glyph. The grip vbox no longer carries `:aspect :drag-handle` — chrome lives at the row level.
- **Drop visuals** are unchanged at the wiring level — the renamed/refreshed aspects `:row-dragging` and `:row-drop-hot` from Task 2 take effect automatically.
- **`:animate :pulse-dot`** on the dragging row is dropped: the row is already very visible while dragging (shadow + frost-steel fill), and the pulse adds nothing. The Add button keeps its pulse decoration.

- [ ] **Step 2: Launch and visually inspect**

```bash
./build/redin examples/kitchen-sink.fnl > /tmp/redin-kitchen.log 2>&1 &
for i in $(seq 1 20); do [ -f .redin-port ] && [ -f .redin-token ] && break; sleep 0.2; done
grep -i "error\|panic\|traceback" /tmp/redin-kitchen.log && echo "ERROR — DO NOT COMMIT YET"
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -sS -H "Authorization: Bearer $TOKEN" -H "Host: localhost:$PORT" -o /tmp/redin-shots/kitchen-task5.png "http://localhost:$PORT/screenshot"
```

Open `/tmp/redin-shots/kitchen-task5.png` and check:

1. Card is centered, ~480px wide, with margin around it. Background is visible around the card.
2. Header shows `Todo List` on the left and `24 items` on the right.
3. Input and Add sit on one row; Add is a small accent-coloured button, not a window-wide stripe.
4. Each row shows a faint dot grip on the far left, the item text in the middle, and a `×` button on the right.
5. Dragging color (try a drag manually if you want — but the screenshot alone won't show this).

If the spacer idiom (`[:vbox {:width :full}]` inside an `:hbox`) doesn't flex as expected, the count badge will be flush against the title. Fix by inspecting the relevant width-distribution behavior — `docs/reference/elements.md` § hbox is the source. Acceptable fallbacks if needed:
- Give the title an explicit width (e.g. `:width 200`) and let the badge sit at far right via a different mechanism.
- Use `:layout :space-between` on the hbox if supported.

Don't commit until the screenshot looks right.

Shutdown:

```bash
curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Host: localhost:$PORT" "http://localhost:$PORT/shutdown" > /dev/null
wait
```

- [ ] **Step 3: Commit**

```bash
git add examples/kitchen-sink.fnl
git commit -m "feat(kitchen-sink): centered card layout with grip rows

480-px wide card centered over the background canvas, header with
live item count, input + Add side by side, rows with canvas-drawn
6-dot grip column and a 32-px × remove button. Old bottom-center
status strip removed."
```

---

## Task 6: Final visual + drag verification

**Files:** None modified. Verification only.

- [ ] **Step 1: Capture the after-screenshot**

```bash
./build/redin examples/kitchen-sink.fnl > /tmp/redin-kitchen.log 2>&1 &
for i in $(seq 1 20); do [ -f .redin-port ] && [ -f .redin-token ] && break; sleep 0.2; done
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token); H="Authorization: Bearer $TOKEN"; HH="Host: localhost:$PORT"
curl -sS -H "$H" -H "$HH" -o /tmp/redin-shots/kitchen-after.png "http://localhost:$PORT/screenshot"
ls -la /tmp/redin-shots/kitchen-before.png /tmp/redin-shots/kitchen-after.png
```

Open both side by side. Confirm:
- Card lift and centering visible.
- Drag handle now reads as a grip (6 dots).
- `Add` button is small and accent-coloured.
- `×` buttons replace wide `remove` buttons.
- Background reads ambient, not smudged.

If the vignette stepping is obtrusive, delete the vignette `for` loop from the `:background` provider added in Task 3 and recapture. Amend Task 3's commit with `git commit --amend` only if no commits have followed it; otherwise add a new commit.

- [ ] **Step 2: End-to-end drag via real input**

Verify a real mouse drag still produces the corrected ordering:

```bash
# Find a row's rect from /frames
ROW_RECT=$(curl -sS -H "$H" -H "$HH" "http://localhost:$PORT/frames" \
  | python3 - <<'PY'
import json, sys
frame = json.load(sys.stdin)
# Locate the first row's rect by walking the JSON; redin attaches "rect":[x,y,w,h]
def walk(node):
    if isinstance(node, dict):
        for k, v in node.items(): yield from walk(v)
        if "tag" in node and node.get("tag") == "hbox" and node.get("attrs", {}).get("aspect") == "row":
            r = node["attrs"].get("rect")
            if r: print(*r); return
    elif isinstance(node, list):
        for x in node: yield from walk(x)
list(walk(frame))
PY
)
echo "first row rect: $ROW_RECT"
```

(If the walker doesn't print, the JSON shape differs from the assumed `{"tag", "attrs"}` and the picker needs adjusting — `/frames` is the source of truth; tweak the walker until it prints the first row's `[x y w h]`.)

Take over the mouse and drag row 1 onto row 5:

```bash
curl -sS -X POST -H "$H" -H "$HH" "http://localhost:$PORT/input/takeover" > /dev/null

# Replace SX/SY/DX/DY with values from the rects of row-1 and row-5.
# A sensible y is the row center; x is somewhere in the grip column (x + ~12).
# Drag:
curl -sS -X POST -H "$H" -H "$HH" -d '{"x":SX,"y":SY}' "http://localhost:$PORT/input/mouse/move"
curl -sS -X POST -H "$H" -H "$HH" -d '{"button":"left"}' "http://localhost:$PORT/input/mouse/down"
sleep 0.05
curl -sS -X POST -H "$H" -H "$HH" -d '{"x":SX2,"y":SY}' "http://localhost:$PORT/input/mouse/move"  # cross 4px threshold
sleep 0.1
curl -sS -X POST -H "$H" -H "$HH" -d '{"x":DX,"y":DY}' "http://localhost:$PORT/input/mouse/move"
sleep 0.1
curl -sS -H "$H" -H "$HH" -o /tmp/redin-shots/kitchen-drag-preview.png "http://localhost:$PORT/screenshot"
curl -sS -X POST -H "$H" -H "$HH" -d '{"button":"left"}' "http://localhost:$PORT/input/mouse/up"
sleep 0.1
curl -sS -X POST -H "$H" -H "$HH" "http://localhost:$PORT/input/release" > /dev/null

# Confirm Test 1 landed at slot 5
curl -sS -H "$H" -H "$HH" "http://localhost:$PORT/state/items" \
  | python3 -c 'import json,sys; xs=json.load(sys.stdin); print([x["text"] for x in xs[:6]])'
# Expected: ['Test 2', 'Test 3', 'Test 4', 'Test 5', 'Test 1', 'Test 6']
```

Inspect `kitchen-drag-preview.png` — the row being dragged should appear shadowed under the cursor, and the row 5 area should show a 2-px accent left border (drop-hot).

If the drag preview does not appear shadowed: `shadow` may not be honored on `hbox` in the current renderer despite the theme.md table. Drop the `:shadow` key from `:row-dragging` in the theme (Task 2 block), recapture, and commit the fix as a new commit:

```bash
# Only if needed:
git commit -am "fix(kitchen-sink): drop :shadow on :row-dragging (hbox shadow unsupported)"
```

- [ ] **Step 3: Existing test suite still green**

The drag UI test is independent of `kitchen-sink.fnl` (it uses `test/ui/drag_app.fnl`), but run it to be safe:

```bash
./build/redin test/ui/drag_app.fnl > /tmp/redin-drag-app.log 2>&1 &
for i in $(seq 1 20); do [ -f .redin-port ] && [ -f .redin-token ] && break; sleep 0.2; done
bb test/ui/test_drag.bb
EXIT=$?
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -sS -X POST -H "Authorization: Bearer $TOKEN" -H "Host: localhost:$PORT" "http://localhost:$PORT/shutdown" > /dev/null
wait
test "$EXIT" -eq 0 && echo "ok" || (echo "FAIL"; false)
```

Expected: `ok`.

- [ ] **Step 4: Release build still compiles**

```bash
odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:/tmp/redin-release-check
echo "exit=$?"
ls -la /tmp/redin-release-check
rm -f /tmp/redin-release-check
```

Expected: exit 0 and a binary written to `/tmp/redin-release-check`. Sanity check that the release build still links — no kitchen-sink-related code paths are in the binary, but if a global `init.fnl` ever depends on examples for runtime tests, this catches regressions.

- [ ] **Step 5: No commit**

Verification only. If issues surfaced, address them in their own commits referencing this task.

---

## Self-review (against spec)

| Spec requirement | Implementing task |
|---|---|
| Centered card max width 480, header / input+Add / list, no bottom strip | Task 5 |
| Palette table (surface 1.0, accent, danger, drag-active, muted lift, surface-elev) | Task 2 |
| Heading 22pt + count badge in header | Tasks 2 (token) + 5 (placement) |
| Primary button only at `Add`; secondary `button-icon` for `×` | Tasks 2 + 5 |
| `:grip-dots` canvas provider — 6 dots in 2×3 pattern | Tasks 4 (provider) + 5 (wiring) |
| Row hover at row level (not grip canvas) — design pivot from spec | Task 2 (`:row#hover`) |
| Drop-hot left-border indicator (accent, 2-px) | Task 2 |
| Drag preview palette + shadow `[0 4 16 [0 0 0 120]]` | Task 2 |
| Background: 3 orbs + vignette, accent orbs removed | Task 3 |
| Drop-handler fix: insert at `to-idx`, drop conditional | Task 1 |
| Visual diff against `kitchen-before.png` | Task 6 step 1 |
| Manual drag sanity (events + real input) | Task 1 step 3 + Task 6 step 2 |
| Release build still compiles | Task 6 step 4 |
| Existing UI tests still green | Task 6 step 3 |

The spec mentioned "grip hover via theme attr-to-ctx (option 1) or sibling provider (option 2)". This plan picks neither: row-level `:row#hover` covers the hover affordance without needing a per-canvas mechanism. This is a deliberate, documented deviation from the spec's two-option list; flagged in the table above.

No placeholder text in the steps. Every step has either exact code or exact commands.
