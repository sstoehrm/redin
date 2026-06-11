# treedo Growth Stages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The treedo tree grows through six hand-drawn stages with the todo count (seed mound at 0 → one-leaf seedling at 1 → full tree at 100) and animates between stages.

**Architecture:** All changes live in `examples/treedo.fnl`. The fixed `TRUNK-H`/`branch-template`/`draw-tree`/`compute-leaf-slots` block becomes a `stages` table of hand-tuned templates plus stage-parameterized draw/slot functions; the `tree-of-life` canvas picks the stage from `(length items)` each frame and eases a uniform scale to 1.0 after a stage swap. Spec: `docs/superpowers/specs/2026-06-10-treedo-growth-design.md`.

**Tech Stack:** Fennel (LuaJIT), redin canvas API, dev-server screenshots for verification. Examples have no automated test convention (approved in spec); verification is screenshot-driven plus keeping the runtime suite green.

---

### Task 1: Stage templates and stage-parameterized drawing

**Files:**
- Modify: `examples/treedo.fnl` — replace the `;; ===== Tree geometry =====` section (the `TRUNK-H` local, `branch-template`, and later the `compute-leaf-slots` + `draw-tree` functions). `paint-branch`, `branch-slots`, and all leaf functions stay unchanged.

- [ ] **Step 1: Replace `TRUNK-H` + `branch-template` with the stage table and selector**

Replace:

```fennel
;; ===== Tree geometry =====
;; Trunk height; branch attach/tip offsets relative to the trunk base
;; (bx, by). Branch entry: [ax-off ay-off tx-off ty-off nslots].
;; 8 branches (4 pairs, low → crown). Total leaf slots = 34.

(local TRUNK-H 320)

(local branch-template
       [[0 -105 -140 -205 5]
        [0 -120  142 -212 5]
        [0 -175 -112 -300 5]
        [0 -188  114 -306 5]
        [0 -245  -64 -358 4]
        [0 -252   66 -360 4]
        [0 -290  -28 -392 3]
        [0 -290   28 -392 3]])
```

with:

```fennel
;; ===== Tree geometry: growth stages =====
;; The tree's size tracks the todo count through hand-tuned stage
;; templates (see docs/superpowers/specs/2026-06-10-treedo-growth-design.md).
;; All offsets are relative to the trunk base (bx, by).
;;   :min       count threshold at which the stage applies
;;   :h         nominal height, used to keep visual height continuous
;;              across stage-swap transitions
;;   :trunk     {:h :w :lit} body height/width and lit-edge width (nil = none)
;;   :thick     branch base thickness for paint-branch
;;   :branches  [[ax ay tx ty nslots] ...] same format as before
;;   :roots     [[x0 y0 x1 y1 thick] ...] paint-branch strokes
;;   :knots     [[dx dy] ...] 5x5 bark-mid markers
;;   :tip-slots [[dx dy] ...] explicit leaf slots (seedling stem tip)
;; S5 reproduces the previous fixed tree exactly at rest (trunk 320x26,
;; 8 branches, 34 slots).

(local stages
  [{:min 0 :h 10 :trunk nil :thick 0
    :branches [] :roots [] :knots [] :tip-slots []}
   {:min 1 :h 36 :trunk {:h 36 :w 4 :lit 1} :thick 0
    :branches []
    :roots [[0 -2 -10 6 3] [0 -2 10 6 3]]
    :knots []
    :tip-slots [[2 -38] [-4 -28]]}
   {:min 5 :h 110 :trunk {:h 110 :w 10 :lit 3} :thick 6
    :branches [[0 -70 -70 -120 3] [0 -78 72 -126 3]]
    :roots [[0 -4 -24 12 5] [0 -4 24 12 5]]
    :knots []
    :tip-slots []}
   {:min 20 :h 200 :trunk {:h 200 :w 16 :lit 4} :thick 8
    :branches [[0 -90 -100 -165 4] [0 -100 102 -170 4]
               [0 -140 -70 -218 3] [0 -146 72 -222 3]]
    :roots [[0 -5 -40 18 6] [0 -5 40 18 6]
            [0 -5 -18 24 4] [0 -5 18 24 4]]
    :knots [[-5 -80]]
    :tip-slots []}
   {:min 50 :h 270 :trunk {:h 270 :w 22 :lit 6} :thick 10
    :branches [[0 -100 -125 -180 5] [0 -112 127 -188 5]
               [0 -160 -95 -260 4] [0 -168 96 -264 4]
               [0 -215 -55 -310 3] [0 -220 56 -312 3]]
    :roots [[0 -6 -52 22 7] [0 -6 52 22 7]
            [0 -6 -24 30 5] [0 -6 24 30 5]]
    :knots [[-7 -100] [-2 -195]]
    :tip-slots []}
   {:min 100 :h 320 :trunk {:h 320 :w 26 :lit 7} :thick 11
    :branches [[0 -105 -140 -205 5] [0 -120 142 -212 5]
               [0 -175 -112 -300 5] [0 -188 114 -306 5]
               [0 -245 -64 -358 4] [0 -252 66 -360 4]
               [0 -290 -28 -392 3] [0 -290 28 -392 3]]
    :roots [[0 -6 -60 26 8] [0 -6 60 26 8]
            [0 -6 -28 34 6] [0 -6 28 34 6]]
    :knots [[-8 -120] [-2 -230]]
    :tip-slots []}])

;; Stages are ascending by :min; the last band the count reaches wins.
(fn stage-for-count [n]
  (var found (. stages 1))
  (each [_ st (ipairs stages)]
    (when (>= n st.min)
      (set found st)))
  found)
```

Slot-count sanity (matches the spec table): S1 = 2 tip slots, S2 = 3+3 = 6, S3 = 4+4+3+3 = 14, S4 = 5+5+4+4+3+3 = 24, S5 = 5+5+5+5+4+4+3+3 = 34.

- [ ] **Step 2: Replace `compute-leaf-slots` and `draw-tree` with stage-parameterized versions**

Replace the existing `compute-leaf-slots` function (keep `branch-slots` above it) with:

```fennel
;; Slots for a stage at scale s: explicit tip slots first, then the
;; branch slots ring-interleaved across branches (ring 0 = innermost
;; slot of every branch) so the canopy fills evenly.
(fn compute-stage-slots [stage bx by s]
  (let [out []]
    (each [_ t (ipairs stage.tip-slots)]
      (table.insert out [(math.floor (+ bx (* (. t 1) s)))
                         (math.floor (+ by (* (. t 2) s)))]))
    (let [per []]
      (each [_ b (ipairs stage.branches)]
        (table.insert per (branch-slots (+ bx (* (. b 1) s)) (+ by (* (. b 2) s))
                                        (+ bx (* (. b 3) s)) (+ by (* (. b 4) s))
                                        (. b 5))))
      (for [ring 0 4]
        (each [_ slots (ipairs per)]
          (when (. slots (+ ring 1))
            (table.insert out (. slots (+ ring 1)))))))
    out))
```

Replace the existing `draw-tree` function with:

```fennel
;; Draw one stage template at uniform scale s anchored at the trunk
;; base (bx, by). At s=1 every stage renders at its hand-drawn size.
(fn draw-stage [ctx bx by stage s]
  (each [_ r (ipairs stage.roots)]
    (paint-branch ctx (+ bx (* (. r 1) s)) (+ by (* (. r 2) s))
                  (+ bx (* (. r 3) s)) (+ by (* (. r 4) s))
                  (math.max 2 (math.floor (* (. r 5) s)))))
  (when stage.trunk
    (let [tr stage.trunk
          th (math.max 2 (math.floor (* tr.h s)))
          tw (math.max 2 (math.floor (* tr.w s)))
          lit (math.floor (* tr.lit s))]
      (ctx.rect (- bx (math.floor (/ tw 2))) (- by th) tw th
                {:fill (. pal :bark-dark)})
      (when (> lit 0)
        (ctx.rect (- (+ bx (math.ceil (/ tw 2))) lit) (- by th) lit th
                  {:fill (. pal :bark-mid)}))))
  (each [_ k (ipairs stage.knots)]
    (ctx.rect (math.floor (+ bx (* (. k 1) s)))
              (math.floor (+ by (* (. k 2) s))) 5 5
              {:fill (. pal :bark-mid)}))
  (each [_ b (ipairs stage.branches)]
    (paint-branch ctx (+ bx (* (. b 1) s)) (+ by (* (. b 2) s))
                  (+ bx (* (. b 3) s)) (+ by (* (. b 4) s))
                  (math.max 3 (math.floor (* stage.thick s))))))

;; Empty-list marker: a dirt hump with a seed glint where the trunk
;; stood. Scales with s so the seedling visibly settles into it.
(fn draw-seed-mound [ctx bx by s]
  (ctx.rect (math.floor (- bx (* 14 s))) (math.floor (- by (* 4 s)))
            (math.max 4 (math.floor (* 28 s))) (math.max 2 (math.floor (* 8 s)))
            {:fill (. pal :ground-top)})
  (ctx.rect (math.floor (- bx (* 10 s))) (math.floor (- by (* 7 s)))
            (math.max 3 (math.floor (* 20 s))) (math.max 2 (math.floor (* 5 s)))
            {:fill (. pal :bark-dark)})
  (ctx.rect (math.floor (- bx (* 2 s))) (math.floor (- by (* 10 s)))
            (math.max 2 (math.floor (* 5 s))) (math.max 2 (math.floor (* 5 s)))
            {:fill (. pal :sunset-gold)})
  (ctx.rect (math.floor (- bx (* 1 s))) (math.floor (- by (* 9 s)))
            2 2 {:fill (. pal :bone-white)}))
```

Trunk math check at S5, s=1: `tw=26` → body x = bx-13 width 26; lit x = bx+13-7 = bx+6 width 7 — identical to the previous `draw-tree`. Roots and knots are the previous values verbatim.

- [ ] **Step 3: Compile check**

Run: `fennel --compile examples/treedo.fnl > /dev/null && echo ok` (if the `fennel` CLI is unavailable, defer to Task 2 Step 3 — the app boot is the compile check).
Expected: `ok` (or deferred). NOTE: `tree-of-life` still references the now-deleted `compute-leaf-slots`/`draw-tree` until Task 2 — if compiling here, expect *unknown identifier* errors mentioning only those two names; that is the expected intermediate state, not a Task 1 bug. (Fennel compiles unknown globals permissively, so this may still print `ok`.)

### Task 2: Tween state and canvas wiring

**Files:**
- Modify: `examples/treedo.fnl` — the `;; ===== Canvas: tree-of-life =====` section.

- [ ] **Step 1: Replace the `tree-of-life` canvas registration**

Replace the whole existing `(canvas.register :tree-of-life (fn [ctx] ...))` form with:

```fennel
;; Transition state for the growth stages: which stage is on screen and
;; its current scale. After a stage swap the scale starts at
;; old-visual-height / new-stage-height (visual height stays continuous)
;; and eases to 1.0, where the stage rests at its hand-drawn size.
(var shown-stage nil)
(var shown-scale 1.0)
(var last-tick nil)

(canvas.register
  :tree-of-life
  (fn [ctx]
    (let [w ctx.width
          h ctx.height
          bx (math.floor (* w 0.36))
          by (horizon-y h)
          now (redin.now)
          items (subscribe :items)
          target (stage-for-count (length items))
          dt (- now (or last-tick now))]
      (set last-tick now)
      ;; First frame starts settled: seeding 100 items shows the full
      ;; tree with no startup animation.
      (when (= shown-stage nil)
        (set shown-stage target))
      (when (~= target shown-stage)
        (set shown-scale (/ (* shown-stage.h shown-scale) target.h))
        (set shown-stage target))
      ;; Exponential ease-out, ~0.9s to settle within 1%, then snap.
      (set shown-scale (+ shown-scale (* (- 1 shown-scale) (math.min 1 (* dt 5)))))
      (when (< (math.abs (- 1 shown-scale)) 0.01)
        (set shown-scale 1.0))
      (let [s shown-scale]
        (if (= shown-stage.min 0)
            (draw-seed-mound ctx bx by s)
            (draw-stage ctx bx by shown-stage s))
        (let [slots (compute-stage-slots shown-stage bx by s)
              nslots (length slots)]
          ;; nslots = 0 only at the seed mound; items is empty there and
          ;; falling leaves are skipped (mod 0 is undefined).
          (when (> nslots 0)
            (each [i item (ipairs items)]
              (let [slot-idx (% (- i 1) nslots)
                    slot     (. slots (+ slot-idx 1))
                    sx       (. slot 1)
                    sy       (. slot 2)
                    sway     (math.floor (* 1.5 (math.sin (+ (* now 1.3) i))))
                    body     (. leaf-cycle (+ 1 (% (- i 1) 3)))
                    lean     (if (= (% i 2) 0) :right :left)
                    age      (- now (or item.born 0))
                    growth   (math.min 1 (/ age 0.3))]
                (draw-leaf-growing ctx (+ sx sway) sy body lean growth)))
            (let [fallen (subscribe :falling-leaves)]
              (each [_ entry (ipairs (or fallen []))]
                (let [slot-idx (% entry.slot nslots)
                      slot     (. slots (+ slot-idx 1))
                      sx       (. slot 1)
                      sy       (. slot 2)
                      age      (- now entry.spawn)
                      t        (/ age 1.8)
                      body     (. leaf-cycle (+ 1 (% entry.slot 3)))
                      draw-x   (math.floor (+ sx (* (math.sin (* age 4)) 10)))
                      draw-y   (math.floor (+ sy (* 320 t t)))
                      alpha    (math.max 0 (math.floor (* 255 (- 1 t))))
                      lean     (if (= (% (+ entry.slot 1) 2) 0) :right :left)]
                  (when (< t 1)
                    (draw-leaf-fading ctx draw-x draw-y body lean alpha)))))))))))
```

The leaf and falling-leaf loops are byte-identical to the previous code except for the `nslots > 0` guard and slots coming from `compute-stage-slots`.

- [ ] **Step 2: Grep for dangling references**

Run: `grep -n 'TRUNK-H\|branch-template\|compute-leaf-slots\|draw-tree' examples/treedo.fnl`
Expected: no output (all four names removed).

- [ ] **Step 3: Boot check**

Run (dev build assumed present from `./build-dev.sh`):
```bash
rm -f .redin-port .redin-token
TREEDO_ITEMS=1 xvfb-run -a -s "-screen 0 1280x800x24" ./build/redin examples/treedo.fnl > /tmp/treedo-s1.log 2>&1 &
for i in $(seq 1 50); do [ -f .redin-port ] && break; sleep 0.2; done
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/state/items | head -c 200; echo
```
Expected: JSON with one item; `/tmp/treedo-s1.log` free of Fennel compile errors. Leave the app running for Task 3 Step 1.

### Task 3: Visual verification

**Files:** none modified — screenshots into `test/ui/artifacts/` (gitignored).

- [ ] **Step 1: Rest-stage screenshots**

For each `N` in `0 1 5 20 50 100` (reuse the running app for N=1):
```bash
rm -f .redin-port .redin-token
TREEDO_ITEMS=$N xvfb-run -a -s "-screen 0 1280x800x24" ./build/redin examples/treedo.fnl > /tmp/treedo-$N.log 2>&1 &
for i in $(seq 1 50); do [ -f .redin-port ] && break; sleep 0.2; done
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
sleep 1
curl -s -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/screenshot -o test/ui/artifacts/growth-$N.png
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/shutdown > /dev/null
```
Read each PNG and check: 0 = mound only, no tree; 1 = short stem with exactly one leaf cluster; 5 = thin sprout, 2 branches; 20 = mid tree, 4 branches; 50 = large tree, 6 branches; 100 = the familiar full tree. Tune stage template numbers and re-screenshot until each stage reads well (this is the hand-tuning loop the spec calls for).

- [ ] **Step 2: Transition screenshots (grow and shrink)**

Boot with `TREEDO_ITEMS=4` (top of the seedling band), then:
```bash
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token); AUTH="Authorization: Bearer $TOKEN"
curl -s -X POST -H "$AUTH" -d '["test/input",{"value":"grow"}]' http://localhost:$PORT/events > /dev/null
curl -s -X POST -H "$AUTH" -d '["test/add"]' http://localhost:$PORT/events > /dev/null
curl -s -H "$AUTH" http://localhost:$PORT/screenshot -o test/ui/artifacts/growth-tween-up.png   # mid-tween, ~0.3s in
sleep 2
curl -s -X POST -H "$AUTH" -d '["test/remove",5]' http://localhost:$PORT/events > /dev/null
curl -s -H "$AUTH" http://localhost:$PORT/screenshot -o test/ui/artifacts/growth-tween-down.png
sleep 2
curl -s -H "$AUTH" http://localhost:$PORT/screenshot -o test/ui/artifacts/growth-settled.png
```
Read the PNGs: `tween-up` shows the sprout template smaller than its rest size (scaling up); `tween-down` shows the seedling larger than rest (settling down); `settled` matches the N=4 rest look. Also remove all 4 remaining todos and screenshot the mound to confirm the shrink-to-mound path and that the last falling leaf doesn't crash (nslots=0 guard).

- [ ] **Step 3: Runtime suite stays green**

Run: `luajit test/lua/runner.lua test/lua/test_*.fnl 2>&1 | tail -1`
Expected: `147 passed, 0 failed`.

### Task 4: Commit and PR

- [ ] **Step 1: Commit**

```bash
git add examples/treedo.fnl
git commit -m "feat(treedo): tree grows through hand-drawn stages with the todo count

Six stages (seed mound at 0, one-leaf seedling at 1, sprout/young/
mature, full tree at 100+) with an eased scale tween between bands.
Spec: docs/superpowers/specs/2026-06-10-treedo-growth-design.md

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 2: Push and open PR**

```bash
git push -u origin feat/treedo-growth-stages
gh pr create --title "feat(treedo): growth stages tied to todo count" --body "<summary + stage table + screenshots>"
```
