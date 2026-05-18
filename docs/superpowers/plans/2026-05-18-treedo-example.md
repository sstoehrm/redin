# treedo Example Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `examples/treedo.fnl` — a forest-themed pixel-art todo app that exercises the canvas API, the `:animate` decoration, and drag-and-drop reorder.

**Architecture:** Single-file Fennel example, modeled on `examples/kitchen-sink.fnl`. Four canvas providers (background, tree, vine, grip), a forest-themed aspect set, and `:born` / `falling-leaves` state slices added on top of the standard items list.

**Tech Stack:** Fennel, redin's canvas + theme + dataflow API. No framework Odin changes.

**Spec:** `docs/superpowers/specs/2026-05-18-treedo-example-design.md`

---

## File Structure

- **Create:** `examples/treedo.fnl` — single-file showcase app.
- **Modify:** none.
- **Test:** no automated test file (matches the kitchen-sink convention; spec § "Out of scope"). Verification is via `./build-dev.sh && ./build/redin examples/treedo.fnl` plus dev-server probes.

The file is built up incrementally so each task is a runnable, committable milestone.

---

## Verification primitives

Every task ends by running the binary and checking observable state. The dev-server build (`./build-dev.sh`) needs to be run **once** at the start of Task 1; later tasks reuse the same binary since they only edit Fennel (hot-reload picks up changes, but a manual relaunch is simplest for verification).

Helper snippet — running the app, capturing a screenshot, and inspecting state:

```bash
# launch in background
./build/redin examples/treedo.fnl &
APP=$!
# wait for dev server
until [ -f .redin-port ]; do sleep 0.1; done
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
H="Authorization: Bearer $TOKEN"

# verify whatever the task wants…
curl -s -H "$H" http://localhost:$PORT/state | head -c 400
curl -s -H "$H" http://localhost:$PORT/screenshot -o /tmp/treedo-shot.png

# shut down
curl -s -X POST -H "$H" http://localhost:$PORT/shutdown
wait $APP 2>/dev/null
```

---

## Task 1: Scaffold + theme + minimal frame

**Files:**
- Create: `examples/treedo.fnl`

- [ ] **Step 1: Build the dev binary**

```bash
./build-dev.sh
```

Expected: produces `./build/redin`, no errors.

- [ ] **Step 2: Write the initial scaffold**

Create `examples/treedo.fnl` with imports, palette, theme, empty state, no view yet:

```fennel
;; treedo — forest-themed pixel-art todo example.

(local dataflow (require :dataflow))
(local theme-mod (require :theme))
(local canvas (require :canvas))

;; ===== Palette (pixel-art forest) =====

(local pal {:night-soil  [22 28 22]
            :bark-dark   [54 38 28]
            :bark-mid    [96 70 48]
            :moss        [70 92 58]
            :leaf-deep   [54 110 56]
            :leaf-mid    [120 170 70]
            :leaf-bright [200 220 110]
            :sunset-gold [228 188 90]
            :mushroom    [180 60 70]
            :bone-white  [232 224 196]})

;; ===== Theme =====

(theme-mod.set-theme
  {:canopy        {:bg [38 46 38] :padding [20 20 20 20] :radius 8}
   :heading       {:font-size 22 :weight 1 :color (. pal :bone-white)}
   :body          {:font-size 14 :color (. pal :bone-white)}
   :count-badge   {:font-size 12 :color (. pal :sunset-gold)}

   :trail         {:padding [4 4 4 4]}
   :trail#hover   {:bg (. pal :moss) :padding [4 4 4 4]}
   :row-vining    {:bg (. pal :leaf-mid)
                   :color (. pal :night-soil)
                   :padding [4 4 4 4]
                   :shadow [0 4 16 [0 0 0 140]]}
   :row-drop-hot  {:bg [90 130 60] :padding [4 4 4 4]}
   :muted-armed   {:bg [48 56 48]}

   :bark          {:bg (. pal :bark-dark)
                   :color (. pal :bone-white)
                   :border (. pal :bark-mid)
                   :border-width 1
                   :radius 4
                   :padding [8 12 8 12]
                   :font-size 14}
   :bark#focus    {:border (. pal :leaf-bright)}

   :leaf          {:bg (. pal :leaf-bright)
                   :color (. pal :night-soil)
                   :radius 6
                   :padding [6 14 6 14]
                   :font-size 13
                   :weight 1}
   :leaf#hover    {:bg [215 230 120]}
   :leaf#active   {:bg [180 200 90]}

   :mushroom         {:bg (. pal :bark-dark) :color [160 150 130]
                      :radius 6 :padding [4 4 4 4] :font-size 16}
   :mushroom#hover   {:color (. pal :mushroom)}
   :mushroom#active  {:bg (. pal :bark-mid)}})

;; ===== State =====

(global redin_get_state (. dataflow :_get-raw-db))

(dataflow.init {:items []
                :input-value ""
                :drag-start-time nil
                :falling-leaves []})

;; ===== Subscriptions =====

(reg-sub :items (fn [db] (get db :items [])))
(reg-sub :input-value (fn [db] (get db :input-value "")))
(reg-sub :drag-start-time (fn [db] (get db :drag-start-time)))
(reg-sub :falling-leaves (fn [db] (get db :falling-leaves [])))

;; ===== View =====

(global main_view
        (fn []
          (let [items (subscribe :items)
                count (length items)]
            [:stack
             {:viewport [[:top_left 0 0 :full :full]
                         [:top_center 0 32 480 :full]]}
             [:vbox {:aspect :canopy}
              [:hbox {:height 32 :layout :center}
               [:text {:aspect :heading} "treedo"]
               [:vbox {:width :full}]
               [:text {:aspect :count-badge} (.. count " items")]]]])))
```

- [ ] **Step 3: Launch + verify**

```bash
./build/redin examples/treedo.fnl &
APP=$!; until [ -f .redin-port ]; do sleep 0.1; done
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/state
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/shutdown
wait $APP 2>/dev/null
```

Expected: `/state` returns `{"items":[],"input-value":"","drag-start-time":null,"falling-leaves":[]}` (or equivalent). No errors on stdout/stderr.

- [ ] **Step 4: Commit**

```bash
git add examples/treedo.fnl
git commit -m "feat(example): treedo scaffold — forest theme + empty state"
```

---

## Task 2: Input + Add + remove + scrollable list

**Files:**
- Modify: `examples/treedo.fnl`

- [ ] **Step 1: Add handlers**

Insert after the subscriptions block, before the view:

```fennel
;; ===== Handlers =====

(reg-handler :test/input
             (fn [db event]
               (let [ctx (. event 2)]
                 (assoc db :input-value (or ctx.value "")))
               db))

(reg-handler :test/add
             (fn [db event]
               (let [val (get db :input-value "")]
                 (when (> (string.len val) 0)
                   (update db :items
                           (fn [items]
                             (table.insert items {:text val :born (redin.now)})
                             items))
                   (assoc db :input-value "")))
               db))

(reg-handler :test/remove
             (fn [db event]
               (let [idx (. event 2)
                     items (get db :items [])]
                 (when (and idx (> idx 0) (<= idx (length items)))
                   (update db :items
                           (fn [items]
                             (icollect [i item (ipairs items)]
                               (when (not= i idx) item))))
                   (update db :falling-leaves
                           (fn [leaves]
                             (table.insert leaves {:slot (- idx 1)
                                                   :spawn (redin.now)})
                             leaves))))
               db))
```

- [ ] **Step 2: Expand the view to include input + list**

Replace the `main_view` global with:

```fennel
(global main_view
        (fn []
          (let [items     (subscribe :items)
                input-val (subscribe :input-value)
                count     (length items)]
            [:stack
             {:viewport [[:top_left 0 0 :full :full]
                         [:top_center 0 32 480 :full]]}
             [:vbox {:aspect :canopy}
              [:hbox {:height 32 :layout :center}
               [:text {:aspect :heading} "treedo"]
               [:vbox {:width :full}]
               [:text {:aspect :count-badge} (.. count " items")]]
              [:vbox {:height 16}]
              [:hbox {:height 42}
               [:input {:aspect :bark
                        :width :full
                        :height 42
                        :value input-val
                        :change [:test/input]
                        :key [:test/add]}]
               [:vbox {:width 8}]
               [:button {:aspect :leaf
                         :width 72
                         :height 42
                         :click [:test/add]} "Plant"]]
              [:vbox {:height 12}]
              [:vbox {:overflow :scroll-y}
               (icollect [i item (ipairs items)]
                 [:hbox {:layout :center :aspect :trail :height 42}
                  [:text {:aspect :body :width :full} item.text]
                  [:button {:aspect :mushroom
                            :width 32 :height 32
                            :click [:test/remove i]} "x"]])]]])))
```

- [ ] **Step 3: Verify add/remove via dev server**

```bash
./build/redin examples/treedo.fnl &
APP=$!; until [ -f .redin-port ]; do sleep 0.1; done
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
H="Authorization: Bearer $TOKEN"

# add one via the input pipeline
curl -s -X POST -H "$H" -d '["test/input",{"value":"acorn"}]' http://localhost:$PORT/events
curl -s -X POST -H "$H" -d '["test/add"]' http://localhost:$PORT/events
curl -s -H "$H" http://localhost:$PORT/state/items

curl -s -X POST -H "$H" http://localhost:$PORT/shutdown
wait $APP 2>/dev/null
```

Expected: `/state/items` returns an array containing `{"text":"acorn","born":<number>}`.

- [ ] **Step 4: Commit**

```bash
git add examples/treedo.fnl
git commit -m "feat(example): treedo input + add/remove with :born timestamp"
```

---

## Task 3: Background canvas `:forest-floor`

**Files:**
- Modify: `examples/treedo.fnl`

- [ ] **Step 1: Register the background provider**

Insert immediately after the palette block, before the theme:

```fennel
;; ===== Canvas: forest-floor (static backdrop) =====
;;
;; Deterministic pseudo-random fleck pattern via an LCG seeded with
;; a constant, so the floor renders identically every frame and across
;; runs. Two passes: moss flecks then mushroom dots, then a centered
;; dirt path with sunset-gold stones.

(local FLOOR-MOSS-COUNT 120)
(local FLOOR-MUSHROOM-COUNT 80)

(fn lcg [seed]
  (% (+ (* seed 1103515245) 12345) 2147483648))

(canvas.register
  :forest-floor
  (fn [ctx]
    (let [w ctx.width
          h ctx.height]
      (ctx.rect 0 0 w h {:fill (. pal :night-soil)})
      ;; moss flecks
      (var s 42)
      (for [_ 1 FLOOR-MOSS-COUNT]
        (set s (lcg s))
        (let [x (* 2 (math.floor (/ (% s w) 2)))]
          (set s (lcg s))
          (let [y (* 2 (math.floor (/ (% s h) 2)))]
            (ctx.rect x y 2 2 {:fill (. pal :moss)}))))
      ;; mushroom dots
      (for [_ 1 FLOOR-MUSHROOM-COUNT]
        (set s (lcg s))
        (let [x (* 2 (math.floor (/ (% s w) 2)))]
          (set s (lcg s))
          (let [y (* 2 (math.floor (/ (% s h) 2)))]
            (ctx.rect x y 2 2 {:fill (. pal :mushroom)}))))
      ;; central dirt path (slightly darker band)
      (let [px (- (math.floor (/ w 2)) 30)]
        (ctx.rect px 0 60 h {:fill [18 22 18]})
        ;; sunset-gold stones every 24px
        (for [i 0 (math.floor (/ h 24))]
          (let [sy (* i 24)
                sx (+ px 26)]
            (ctx.rect sx sy 8 4 {:fill (. pal :sunset-gold)})))))))
```

- [ ] **Step 2: Add it as a viewport layer**

In `main_view`, change the `:stack` so the floor sits underneath the panel:

```fennel
            [:stack
             {:viewport [[:top_left 0 0 :full :full]
                         [:top_center 0 32 480 :full]]}
             [:canvas {:provider :forest-floor :width :full :height :full}]
             [:vbox {:aspect :canopy}
              ...]]
```

(Insert the new `[:canvas ...]` line as the first child of `:stack`.)

- [ ] **Step 3: Verify**

Launch + take a screenshot:

```bash
./build/redin examples/treedo.fnl &
APP=$!; until [ -f .redin-port ]; do sleep 0.1; done
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/screenshot -o /tmp/treedo-floor.png
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/shutdown
wait $APP 2>/dev/null
```

Expected: `/tmp/treedo-floor.png` shows a dark forest backdrop with moss + mushroom flecks and a vertical path band running down the centre. Eyeball-check that flecks look pixel-snapped (no smudgy anti-aliasing).

- [ ] **Step 4: Commit**

```bash
git add examples/treedo.fnl
git commit -m "feat(example): treedo forest-floor background canvas"
```

---

## Task 4: Tree trunk + branches + slot table

**Files:**
- Modify: `examples/treedo.fnl`

- [ ] **Step 1: Define the slot table**

Insert after the palette, before the canvases (right after the `pal` local):

```fennel
;; ===== Tree geometry =====
;; Canvas size: 240×320. Trunk at x=120, base at y=320.
;; Four diagonal branches; 8 leaf slots per branch = 32 total.

(local leaf-slots
       (let [slots []]
         (for [i 0 7]
           (let [t (/ i 7)]
             (table.insert slots [(- 112 (math.floor (* 72 t)))
                                  (- 200 (math.floor (* 60 t)))])))
         (for [i 0 7]
           (let [t (/ i 7)]
             (table.insert slots [(+ 128 (math.floor (* 72 t)))
                                  (- 200 (math.floor (* 60 t)))])))
         (for [i 0 7]
           (let [t (/ i 7)]
             (table.insert slots [(- 112 (math.floor (* 52 t)))
                                  (- 130 (math.floor (* 50 t)))])))
         (for [i 0 7]
           (let [t (/ i 7)]
             (table.insert slots [(+ 128 (math.floor (* 52 t)))
                                  (- 130 (math.floor (* 50 t)))])))
         slots))
```

- [ ] **Step 2: Register the tree provider with trunk + branches only**

Add after the forest-floor registration:

```fennel
;; ===== Canvas: tree-of-life =====
;; Static trunk + four diagonal branches drawn as rect segments.
;; Leaves come in the next task.

(fn draw-trunk-and-branches [ctx]
  ;; trunk: vertical column 16px wide, base at bottom
  (ctx.rect 112 100 16 220 {:fill (. pal :bark-dark)})
  (ctx.rect 124 100 4  220 {:fill (. pal :bark-mid)})    ; lit edge
  ;; four diagonal branches drawn as a chain of 4×4 rects
  (let [paint (fn [x0 y0 x1 y1]
                (let [steps 18]
                  (for [i 0 steps]
                    (let [t (/ i steps)
                          x (math.floor (+ x0 (* (- x1 x0) t)))
                          y (math.floor (+ y0 (* (- y1 y0) t)))]
                      (ctx.rect x y 6 6 {:fill (. pal :bark-dark)})
                      (ctx.rect (+ x 4) y 2 6 {:fill (. pal :bark-mid)})))))]
    (paint 112 200  40 140)
    (paint 128 200 200 140)
    (paint 112 130  60  80)
    (paint 128 130 180  80)))

(canvas.register
  :tree-of-life
  (fn [ctx]
    (draw-trunk-and-branches ctx)))
```

- [ ] **Step 3: Pin the tree canvas into the viewport**

In `main_view`, add a viewport entry and a canvas child:

```fennel
            [:stack
             {:viewport [[:top_left 0 0 :full :full]
                         [:bottom_left 16 -16 240 320]
                         [:top_center 0 32 480 :full]]}
             [:canvas {:provider :forest-floor :width :full :height :full}]
             [:canvas {:provider :tree-of-life :width 240 :height 320}]
             [:vbox {:aspect :canopy}
              ...]]
```

The order of children must match the viewport entries: floor (full), tree (bottom-left), panel (top-center).

- [ ] **Step 4: Verify**

Launch and screenshot:

```bash
./build/redin examples/treedo.fnl &
APP=$!; until [ -f .redin-port ]; do sleep 0.1; done
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/screenshot -o /tmp/treedo-tree.png
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/shutdown
wait $APP 2>/dev/null
```

Expected: the screenshot shows a chunky pixel tree at bottom-left of the window with a trunk and four splayed branches. No leaves yet.

- [ ] **Step 5: Commit**

```bash
git add examples/treedo.fnl
git commit -m "feat(example): treedo tree trunk + branches + 32-slot table"
```

---

## Task 5: Live leaves on the tree

**Files:**
- Modify: `examples/treedo.fnl`

- [ ] **Step 1: Add a leaf-drawing helper**

Add inside the tree section, above `(canvas.register :tree-of-life ...)`:

```fennel
;; Three rotating leaf body colors.
(local leaf-cycle [(. pal :leaf-deep)
                   (. pal :leaf-mid)
                   (. pal :leaf-bright)])

;; Draw one leaf at (x, y), full size, with the given body color.
;; "Lean" alternates by slot parity: even slots lean right, odd left.
(fn draw-leaf [ctx x y body lean]
  (let [dx (if (= lean :right) 0 -8)]
    ;; outline (3×3 cluster of dark green tiles)
    (ctx.rect (+ x dx)     y     12 8 {:fill (. pal :leaf-deep)})
    ;; body fill (slightly inset)
    (ctx.rect (+ x dx 1)   (+ y 1) 10 6 {:fill body})
    ;; highlight pixel
    (ctx.rect (+ x dx 2) (+ y 1) 2 2 {:fill (. pal :leaf-bright)})))
```

- [ ] **Step 2: Render one leaf per item, with sway**

Update the `:tree-of-life` provider:

```fennel
(canvas.register
  :tree-of-life
  (fn [ctx]
    (draw-trunk-and-branches ctx)
    (let [items (subscribe :items)
          now   (redin.now)]
      (each [i _item (ipairs items)]
        (let [slot-idx (% (- i 1) 32)
              slot     (. leaf-slots (+ slot-idx 1))
              sx       (. slot 1)
              sy       (. slot 2)
              sway     (math.floor (* 1 (math.sin (+ (* now 1.3) i))))
              body     (. leaf-cycle (+ 1 (% (- i 1) 3)))
              lean     (if (= (% i 2) 0) :right :left)]
          (draw-leaf ctx (+ sx sway) sy body lean))))))
```

- [ ] **Step 3: Verify leaves track add/remove**

```bash
./build/redin examples/treedo.fnl &
APP=$!; until [ -f .redin-port ]; do sleep 0.1; done
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
H="Authorization: Bearer $TOKEN"

# add three items
for w in oak fern pine; do
  curl -s -X POST -H "$H" -d "[\"test/input\",{\"value\":\"$w\"}]" http://localhost:$PORT/events
  curl -s -X POST -H "$H" -d '["test/add"]' http://localhost:$PORT/events
done
sleep 0.3
curl -s -H "$H" http://localhost:$PORT/screenshot -o /tmp/treedo-leaves-3.png

# remove the middle one
curl -s -X POST -H "$H" -d '["test/remove",2]' http://localhost:$PORT/events
sleep 0.3
curl -s -H "$H" http://localhost:$PORT/screenshot -o /tmp/treedo-leaves-2.png

curl -s -X POST -H "$H" http://localhost:$PORT/shutdown
wait $APP 2>/dev/null
```

Expected: `treedo-leaves-3.png` shows three pixel leaves at slots 0/1/2. `treedo-leaves-2.png` shows two leaves at slots 0/1 (the slot-2 leaf is gone).

- [ ] **Step 4: Commit**

```bash
git add examples/treedo.fnl
git commit -m "feat(example): treedo live leaves per todo with subtle sway"
```

---

## Task 6: Sprout-in animation on add

**Files:**
- Modify: `examples/treedo.fnl`

- [ ] **Step 1: Add a scaled draw helper**

Add below `draw-leaf`:

```fennel
;; Draws a leaf at `growth` ∈ [0,1] of its full size. Below 1.0 we draw
;; a smaller pixel-art "bud" using fewer big-pixels — four discrete
;; growth stages give the chunky pop.
(fn draw-leaf-growing [ctx x y body lean growth]
  (let [stage (math.min 4 (math.floor (+ 1 (* growth 4))))]
    (if (>= stage 4)
        (draw-leaf ctx x y body lean)
        ;; smaller cluster: stage square at slot center
        (let [size (* stage 2)
              dx (if (= lean :right) 0 (- (- 0 size)))]
          (ctx.rect (+ x dx 4) y size size {:fill body})))))
```

- [ ] **Step 2: Use it in the tree provider**

Replace the live-leaf rendering block inside `:tree-of-life` with:

```fennel
    (let [items (subscribe :items)
          now   (redin.now)]
      (each [i item (ipairs items)]
        (let [slot-idx (% (- i 1) 32)
              slot     (. leaf-slots (+ slot-idx 1))
              sx       (. slot 1)
              sy       (. slot 2)
              sway     (math.floor (* 1 (math.sin (+ (* now 1.3) i))))
              body     (. leaf-cycle (+ 1 (% (- i 1) 3)))
              lean     (if (= (% i 2) 0) :right :left)
              age      (- now (or item.born 0))
              growth   (math.min 1 (/ age 0.3))]
          (draw-leaf-growing ctx (+ sx sway) sy body lean growth))))
```

- [ ] **Step 3: Verify sprout visible**

```bash
./build/redin examples/treedo.fnl &
APP=$!; until [ -f .redin-port ]; do sleep 0.1; done
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
H="Authorization: Bearer $TOKEN"

curl -s -X POST -H "$H" -d '["test/input",{"value":"sprout"}]' http://localhost:$PORT/events
curl -s -X POST -H "$H" -d '["test/add"]' http://localhost:$PORT/events

# capture mid-sprout (around 100ms after add) and after full-grown
sleep 0.1
curl -s -H "$H" http://localhost:$PORT/screenshot -o /tmp/treedo-sprout-mid.png
sleep 0.4
curl -s -H "$H" http://localhost:$PORT/screenshot -o /tmp/treedo-sprout-full.png

curl -s -X POST -H "$H" http://localhost:$PORT/shutdown
wait $APP 2>/dev/null
```

Expected: `treedo-sprout-mid.png` shows a small bud at slot 0; `treedo-sprout-full.png` shows the full leaf. Compare the two — the bud is visibly smaller than the leaf.

- [ ] **Step 4: Commit**

```bash
git add examples/treedo.fnl
git commit -m "feat(example): treedo sprout-in pixel pop on add"
```

---

## Task 7: Falling leaves + cleanup tick

**Files:**
- Modify: `examples/treedo.fnl`

- [ ] **Step 1: Add the `:tick/clear-fallen` handler**

Add **after** the existing `:test/remove` handler (the Task 2 version, unchanged):

```fennel
;; Periodic prune of falling-leaf entries older than 2 seconds.
;; Re-arms itself via :dispatch-later, so the loop runs forever at
;; ~2s intervals. The handler returns {:db ... :dispatch-later ...}
;; — both keys are required: the runtime only delivers effects when
;; the result table carries :db (src/runtime/dataflow.fnl).
(reg-handler :tick/clear-fallen
             (fn [db event]
               (let [now (redin.now)]
                 {:db (update db :falling-leaves
                              (fn [leaves]
                                (icollect [_ l (ipairs leaves)]
                                  (when (< (- now l.spawn) 2) l))))
                  :dispatch-later {:ms 2000 :dispatch [:tick/clear-fallen]}})))
```

- [ ] **Step 2: Bootstrap the tick**

At the end of the file (after `main_view`), append:

```fennel
;; Bootstrap the falling-leaf cleanup loop. The handler re-arms itself
;; via :dispatch-later, so this single dispatch is enough.
(dispatch [:tick/clear-fallen])
```

- [ ] **Step 3: Add a fading-leaf helper, then draw falling leaves**

Add this helper next to `draw-leaf` (so all three rect fills fade together, not just the body):

```fennel
(fn draw-leaf-fading [ctx x y body lean alpha]
  (let [dx (if (= lean :right) 0 -8)
        outline (. pal :leaf-deep)
        hilight (. pal :leaf-bright)
        with-a (fn [c] [(. c 1) (. c 2) (. c 3) alpha])]
    (ctx.rect (+ x dx)     y       12 8 {:fill (with-a outline)})
    (ctx.rect (+ x dx 1)   (+ y 1) 10 6 {:fill (with-a body)})
    (ctx.rect (+ x dx 2)   (+ y 1) 2  2 {:fill (with-a hilight)})))
```

Then add this block inside the `:tree-of-life` provider, **after** the live-leaf loop:

```fennel
      (let [fallen (subscribe :falling-leaves)]
        (each [_ entry (ipairs (or fallen []))]
          (let [slot-idx (% entry.slot 32)
                slot     (. leaf-slots (+ slot-idx 1))
                sx       (. slot 1)
                sy       (. slot 2)
                age      (- now entry.spawn)
                t        (/ age 1.6)
                body     (. leaf-cycle (+ 1 (% entry.slot 3)))
                draw-x   (math.floor (+ sx (* (math.sin (* age 4)) 8)))
                draw-y   (math.floor (+ sy (* 250 t t)))
                alpha    (math.max 0 (math.floor (* 255 (- 1 t))))
                lean     (if (= (% (+ entry.slot 1) 2) 0) :right :left)]
            (when (< t 1)
              (draw-leaf-fading ctx draw-x draw-y body lean alpha)))))
```

- [ ] **Step 4: Verify a falling leaf is observable + the tick prunes it**

```bash
./build/redin examples/treedo.fnl &
APP=$!; until [ -f .redin-port ]; do sleep 0.1; done
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
H="Authorization: Bearer $TOKEN"

# add two
for w in maple birch; do
  curl -s -X POST -H "$H" -d "[\"test/input\",{\"value\":\"$w\"}]" http://localhost:$PORT/events
  curl -s -X POST -H "$H" -d '["test/add"]' http://localhost:$PORT/events
done
sleep 0.3
# remove the first
curl -s -X POST -H "$H" -d '["test/remove",1]' http://localhost:$PORT/events
sleep 0.1
echo "immediately after remove (1 entry):"
curl -s -H "$H" http://localhost:$PORT/state/falling-leaves
curl -s -H "$H" http://localhost:$PORT/screenshot -o /tmp/treedo-falling.png

# The first :tick/clear-fallen fires ~2s after module load. By then the
# entry is ~1.7s old — not yet stale. The SECOND tick fires at ~4s;
# entry is then ~3.7s old → pruned.
sleep 4.5
echo "after ~4.6s (expect empty — 2nd tick pruned):"
curl -s -H "$H" http://localhost:$PORT/state/falling-leaves

curl -s -X POST -H "$H" http://localhost:$PORT/shutdown
wait $APP 2>/dev/null
```

Expected: immediately after the remove, `/state/falling-leaves` has one entry; the screenshot shows a leaf below the original slot position (falling). After ~4.5s, the second cleanup tick has fired and the entry is gone. App must not hang — requires the `redin.now`-based dispatch-later scheduler from #146.

- [ ] **Step 5: Commit**

```bash
git add examples/treedo.fnl
git commit -m "feat(example): treedo falling-leaf animation on remove"
```

---

## Task 8: Drag-and-drop reorder

**Files:**
- Modify: `examples/treedo.fnl`

- [ ] **Step 1: Add the drag handlers**

Add after `:tick/clear-fallen`:

```fennel
(reg-handler :event/drag
             (fn [db event] db))

(reg-handler :event/over
             (fn [db event] db))

(reg-handler :event/drop
             (fn [db event]
               (let [ctx (. event 2)
                     from-idx ctx.from
                     to-idx   ctx.to
                     items    (get db :items [])]
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

- [ ] **Step 2: Wire drag attributes into each row**

In `main_view`, replace the row-emitting `icollect` block with:

```fennel
              [:vbox
               {:overflow :scroll-y
                :drag-over [:row-drag {:event :event/over :aspect :muted-armed}]}
               (icollect [i item (ipairs items)]
                 [:hbox {:layout :center :aspect :trail :height 42
                         :draggable [:row-drag
                                     {:mode :preview
                                      :handle false
                                      :event :event/drag
                                      :aspect :row-vining}
                                     i]
                         :dropable [:row-drag
                                    {:event :event/drop
                                     :aspect :row-drop-hot}
                                    i]}
                  [:vbox {:width 24 :height 42 :drag-handle true}]
                  [:text {:aspect :body :width :full} item.text]
                  [:button {:aspect :mushroom
                            :width 32 :height 32
                            :click [:test/remove i]} "x"]])]
```

(The 24px grip column is just an empty handle in this task; canvas dots come in Task 10.)

- [ ] **Step 3: Verify reorder works**

Use the mouse-takeover endpoints to drag row 1 down to row 3's position.

```bash
./build/redin examples/treedo.fnl &
APP=$!; until [ -f .redin-port ]; do sleep 0.1; done
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
H="Authorization: Bearer $TOKEN"

for w in alpha beta gamma; do
  curl -s -X POST -H "$H" -d "[\"test/input\",{\"value\":\"$w\"}]" http://localhost:$PORT/events
  curl -s -X POST -H "$H" -d '["test/add"]' http://localhost:$PORT/events
done

# Find row 1's rect from /frames and drag it down ~80px (row height + gap).
# Simpler: directly dispatch the drop event to confirm wiring.
curl -s -X POST -H "$H" -d '["event/drop",{"from":1,"to":3}]' http://localhost:$PORT/events
curl -s -H "$H" http://localhost:$PORT/state/items

curl -s -X POST -H "$H" http://localhost:$PORT/shutdown
wait $APP 2>/dev/null
```

Expected: `/state/items` order becomes `[beta, gamma, alpha]` (alpha moved from 1 → 3).

- [ ] **Step 4: Commit**

```bash
git add examples/treedo.fnl
git commit -m "feat(example): treedo drag-and-drop row reorder"
```

---

## Task 9: Vine animation on drag

**Files:**
- Modify: `examples/treedo.fnl`

- [ ] **Step 1: Track drag-start-time in the drag handler**

Replace the `:event/drag` and `:event/drop` handlers from Task 8:

```fennel
(reg-handler :event/drag
             (fn [db event]
               (assoc db :drag-start-time (redin.now))))

(reg-handler :event/drop
             (fn [db event]
               (let [ctx (. event 2)
                     from-idx ctx.from
                     to-idx   ctx.to
                     items    (get db :items [])]
                 (when (and from-idx to-idx
                            (> from-idx 0) (<= from-idx (length items))
                            (> to-idx   0) (<= to-idx   (length items))
                            (not= from-idx to-idx))
                   (let [item (. items from-idx)
                         new-items (icollect [i v (ipairs items)]
                                     (when (not= i from-idx) v))]
                     (table.insert new-items to-idx item)
                     (assoc db :items new-items)))
                 (assoc db :drag-start-time nil))
               db))
```

- [ ] **Step 2: Register the vine provider**

Add after the `:tree-of-life` provider:

```fennel
;; ===== Canvas: vine (drag overlay) =====
;; Decoration on :draggable {:animate ...}. The host gates this to the
;; drag preview only, so we always know we're being drawn around a
;; cloned, dragged row.

(canvas.register
  :vine
  (fn [ctx]
    (let [w ctx.width
          h ctx.height
          start (subscribe :drag-start-time)
          now (redin.now)
          age (if start (- now start) 0)
          growth (math.min 1 (* age 2.5))
          perimeter (* 2 (+ w h))
          drawn-len (* perimeter growth)
          step 4]
      (var dist 0)
      (var tuft-i 0)
      (each [i edge (ipairs [[0 0 1 0]      ; top
                             [w 0 0 1]      ; right
                             [w h -1 0]     ; bottom
                             [0 h 0 -1]])]  ; left
        (let [ex (. edge 1)
              ey (. edge 2)
              dx (. edge 3)
              dy (. edge 4)
              len (if (= 0 dx) h w)]
          (var t 0)
          (while (and (< t len) (< dist drawn-len))
            (let [px (math.floor (+ ex (* dx t)))
                  py (math.floor (+ ey (* dy t)))]
              (ctx.rect px py 3 3 {:fill (. pal :leaf-deep)})
              (when (= 0 (% tuft-i 6))
                (let [bob (if (>= growth 1)
                              (math.floor (* 1 (math.sin (+ (* now 2) tuft-i))))
                              0)]
                  (ctx.rect (- px 1) (+ py bob -1) 5 5
                            {:fill (. pal :leaf-mid)})
                  (ctx.rect (+ px 1) (+ py bob)   1 1
                            {:fill (. pal :leaf-bright)})))
              (set tuft-i (+ tuft-i 1))
              (set dist (+ dist step))
              (set t (+ t step)))))))))
```

- [ ] **Step 3: Attach the vine as an `:animate` decoration on the draggable**

In the `:draggable` map of the row hbox, add `:animate` next to `:aspect`:

```fennel
                         :draggable [:row-drag
                                     {:mode :preview
                                      :handle false
                                      :event :event/drag
                                      :aspect :row-vining
                                      :animate {:provider :vine
                                                :rect [:top_left -6 -6 :full :full]
                                                :z :above}}
                                     i]
```

- [ ] **Step 4: Verify vine appears under takeover-driven drag**

Use the takeover pipeline to actually start a drag (rather than firing the event directly — `:animate` only renders while there is a live preview).

```bash
./build/redin examples/treedo.fnl &
APP=$!; until [ -f .redin-port ]; do sleep 0.1; done
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
H="Authorization: Bearer $TOKEN"

for w in willow elm rowan; do
  curl -s -X POST -H "$H" -d "[\"test/input\",{\"value\":\"$w\"}]" http://localhost:$PORT/events
  curl -s -X POST -H "$H" -d '["test/add"]' http://localhost:$PORT/events
done
sleep 0.2

# Find row 1's rect from /frames so we can press inside it.
ROW1_RECT=$(curl -s -H "$H" http://localhost:$PORT/frames \
            | python3 -c 'import sys,json
fr=json.load(sys.stdin)
def find(n):
  if n.get("attrs",{}).get("aspect")=="trail":
    return n["attrs"]["rect"]
  for c in n.get("children",[]):
    r=find(c)
    if r: return r
print(find(fr))')
echo "row1 rect: $ROW1_RECT"
# Pull x,y,w,h via a tiny python parse (rect is "[x, y, w, h]")
RX=$(python3 -c "import json,sys;r=json.loads('$ROW1_RECT');print(int(r[0]+r[2]/2))")
RY=$(python3 -c "import json,sys;r=json.loads('$ROW1_RECT');print(int(r[1]+r[3]/2))")
RY2=$((RY+80))

curl -s -X POST -H "$H" http://localhost:$PORT/input/takeover
curl -s -X POST -H "$H" -d "{\"x\":$RX,\"y\":$RY}" http://localhost:$PORT/input/mouse/move
curl -s -X POST -H "$H" -d '{"button":"left"}'   http://localhost:$PORT/input/mouse/down
curl -s -X POST -H "$H" -d "{\"x\":$RX,\"y\":$RY2}" http://localhost:$PORT/input/mouse/move
sleep 0.5    ; # vine should be ~fully grown by now
curl -s -H "$H" http://localhost:$PORT/screenshot -o /tmp/treedo-vine.png
curl -s -X POST -H "$H" -d '{"button":"left"}'   http://localhost:$PORT/input/mouse/up
curl -s -X POST -H "$H" http://localhost:$PORT/input/release

curl -s -X POST -H "$H" http://localhost:$PORT/shutdown
wait $APP 2>/dev/null
```

Expected: `treedo-vine.png` shows the dragged row preview floating near the cursor with a green vine wrapping its border and tufts at intervals. `/state/drag-start-time` was non-null during the drag.

- [ ] **Step 5: Commit**

```bash
git add examples/treedo.fnl
git commit -m "feat(example): treedo vine animation around dragged row"
```

---

## Task 10: Grip handle canvas + final acceptance

**Files:**
- Modify: `examples/treedo.fnl`

- [ ] **Step 1: Register the grip canvas**

Add after the `:vine` registration:

```fennel
;; A vertical run of 3 small mushroom dots — the grab affordance.
(canvas.register
  :vine-grip
  (fn [ctx]
    (let [cx (/ ctx.width 2)
          cy (/ ctx.height 2)]
      (for [row -1 1]
        (let [y (math.floor (+ cy (* row 8)))]
          (ctx.rect (- cx 3) y 2 2 {:fill (. pal :moss)})
          (ctx.rect (+ cx 1) y 2 2 {:fill (. pal :moss)}))))))
```

- [ ] **Step 2: Drop a canvas into the row's grip column**

In `main_view`, replace the empty grip vbox inside the row block with:

```fennel
                  [:vbox {:width 24 :height 42 :drag-handle true}
                   [:canvas {:provider :vine-grip :width 24 :height 42}]]
```

- [ ] **Step 3: Seed a few sample items**

So that the example looks alive on first launch — replace the empty list in `dataflow.init` with:

```fennel
(dataflow.init {:items [{:text "Plant the seed"      :born 0}
                        {:text "Water the sapling"   :born 0}
                        {:text "Watch the canopy grow" :born 0}
                        {:text "Sweep the leaves"    :born 0}]
                :input-value ""
                :drag-start-time nil
                :falling-leaves []})
```

(`:born 0` keeps seeded items past the sprout window, so they appear full-size at launch.)

- [ ] **Step 4: Full visual smoke**

```bash
./build/redin examples/treedo.fnl &
APP=$!; until [ -f .redin-port ]; do sleep 0.1; done
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
H="Authorization: Bearer $TOKEN"
curl -s -H "$H" http://localhost:$PORT/screenshot -o /tmp/treedo-final.png
curl -s -X POST -H "$H" http://localhost:$PORT/shutdown
wait $APP 2>/dev/null
```

Visually verify in `/tmp/treedo-final.png`:
- Forest-floor backdrop with flecks + path.
- Pixel tree at bottom-left with four leaves (one per seeded item).
- Top-center panel with title "treedo", "4 items" badge, input, "Plant" button, and four rows each with a grip column, item text, and "x" remove.
- Style is pixel-snapped (no smudgy curves).

- [ ] **Step 5: Memory check**

The dev build (`./build-dev.sh`) already has REDIN_TRACK_MEM baked in, so a clean shutdown should print no leaks.

```bash
./build/redin examples/treedo.fnl 2>&1 | tee /tmp/treedo-mem.log &
APP=$!; until [ -f .redin-port ]; do sleep 0.1; done
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
H="Authorization: Bearer $TOKEN"
# exercise add/remove/drag once each
curl -s -X POST -H "$H" -d '["test/input",{"value":"x"}]' http://localhost:$PORT/events
curl -s -X POST -H "$H" -d '["test/add"]' http://localhost:$PORT/events
curl -s -X POST -H "$H" -d '["test/remove",1]' http://localhost:$PORT/events
curl -s -X POST -H "$H" http://localhost:$PORT/shutdown
wait $APP 2>/dev/null
grep -iE 'leak|outstanding' /tmp/treedo-mem.log || echo "no leaks"
```

Expected: `no leaks` (or grep output empty).

- [ ] **Step 6: Commit**

```bash
git add examples/treedo.fnl
git commit -m "feat(example): treedo grip canvas + seeded items + acceptance pass"
```

---

## Done

After Task 10, `examples/treedo.fnl` is a self-contained ~250-line file that demonstrates:

- Pixel-art canvas drawing from scripting (`forest-floor`, `tree-of-life`, `vine`, `vine-grip`).
- State-driven canvas (tree leaves track `:items`; vine tracks `:drag-start-time`).
- Animation via the `:animate` decoration on `:draggable`.
- Drag-and-drop reorder.
- `dispatch-later` for a periodic cleanup tick.
- A coherent themed look (forest aspects, no `#` cascade abuse).
