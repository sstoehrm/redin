;; treedo — dusk-forest-glade pixel-art todo example.
;;
;; A single cohesive scene: a large "tree of life" stands as the hero in a
;; textured forest glade under a graded twilight sky (moon, stars, distant
;; treeline), with the todo list as a translucent field-journal card resting
;; on the right. Each todo is a leaf; adding sprouts one, removing drops one.
;;
;; The list seeds TREEDO_ITEMS todos (default 100). Crank it up to stress
;; the render/layout/scroll and leaf-canopy paths under a profile build:
;;   TREEDO_ITEMS=10000 ./build/redin examples/treedo.fnl   # then GET /profile

(local dataflow (require :dataflow))
(local theme-mod (require :theme))
(local canvas (require :canvas))

;; ===== Palette (pixel-art dusk forest) =====

(local pal {:night-soil   [22 28 22]
            :bark-dark    [54 38 28]
            :bark-mid     [96 70 48]
            :moss         [70 92 58]
            :leaf-deep    [54 110 56]
            :leaf-mid     [120 170 70]
            :leaf-bright  [200 220 110]
            :sunset-gold  [228 188 90]
            :mushroom     [180 60 70]
            :bone-white   [232 224 196]
            ;; twilight-sky set
            :sky-top      [24 22 46]
            :sky-mid      [58 46 80]
            :sky-low      [150 96 92]
            :horizon-glow [228 168 96]
            :moon         [244 238 214]
            :star         [210 214 196]
            :silhouette   [30 30 46]
            :grass        [58 86 50]
            :ground-top   [44 50 32]
            :ground-bot   [22 26 18]})

;; ===== Small numeric helpers =====

(fn lcg [seed]
  (% (+ (* seed 1103515245) 12345) 2147483648))

(fn lerp-col [a b t]
  [(math.floor (+ (. a 1) (* (- (. b 1) (. a 1)) t)))
   (math.floor (+ (. a 2) (* (- (. b 2) (. a 2)) t)))
   (math.floor (+ (. a 3) (* (- (. b 3) (. a 3)) t)))])

;; Multi-stop colour gradient. `stops` = [[t0 col0] [t1 col1] ...] ascending.
(fn grad [stops t]
  (let [tc (math.max 0 (math.min 1 t))]
    (var result (. (. stops 1) 2))
    (var done false)
    (for [i 1 (- (length stops) 1)]
      (when (not done)
        (let [s0 (. stops i)
              s1 (. stops (+ i 1))
              t0 (. s0 1)
              t1 (. s1 1)]
          (when (and (>= tc t0) (<= tc t1))
            (let [lt (if (> (- t1 t0) 0) (/ (- tc t0) (- t1 t0)) 0)]
              (set result (lerp-col (. s0 2) (. s1 2) lt))
              (set done true))))))
    result))

;; Both full-window canvases share this horizon so ground + trunk-base align.
(fn horizon-y [h] (math.floor (* h 0.64)))

(local sky-stops [[0.0  (. pal :horizon-glow)]
                  [0.10 (. pal :sky-low)]
                  [0.40 (. pal :sky-mid)]
                  [1.0  (. pal :sky-top)]])

;; ===== Tree geometry: growth stages =====
;; The tree's size tracks the todo count through hand-tuned stage
;; templates (see docs/superpowers/specs/2026-06-10-treedo-growth-design.md).
;; All offsets are relative to the trunk base (bx, by).
;;   :min       count threshold at which the stage applies
;;   :h         nominal height, used to keep visual height continuous
;;              across stage-swap transitions
;;   :trunk     {:h :w :lit} body height/width and lit-edge width (nil = none)
;;   :thick     branch base thickness for paint-branch
;;   :branches  [[ax ay tx ty nslots] ...] attach/tip offsets + slot count
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

;; ===== Drawing primitives =====

;; A branch/root drawn as discrete tapered chunks (chunky pixel-art feel):
;; base-thick at the attach point shrinking to 4px at the tip.
(fn paint-branch [ctx x0 y0 x1 y1 base-thick]
  ;; Step every ~4px along the branch so chunks overlap into a solid limb
  ;; (a fixed step count leaves gaps on long branches → dotted-stick look).
  (let [dx (- x1 x0)
        dy (- y1 y0)
        dist (math.sqrt (+ (* dx dx) (* dy dy)))
        steps (math.max 6 (math.floor (/ dist 4)))]
    (for [i 0 steps]
      (let [t (/ i steps)
            x (math.floor (+ x0 (* dx t)))
            y (math.floor (+ y0 (* dy t)))
            thick (math.max 4 (- base-thick (math.floor (* t (- base-thick 4)))))]
        (ctx.rect x y thick thick {:fill (. pal :bark-dark)})
        (ctx.rect (+ x thick -2) y 2 thick {:fill (. pal :bark-mid)})))))

;; A pixel-art conifer: stacked narrowing rows from `base` upward.
(fn conifer [ctx cx base th col]
  (let [rows (math.max 3 (math.floor (/ th 3)))]
    (for [r 0 rows]
      (let [yy (- base (* r 3))
            half (+ 1 (math.floor (* (/ (- rows r) rows) (/ th 2.4))))]
        (ctx.rect (- cx half) yy (* 2 half) 3 {:fill col})))
    (ctx.rect (- cx 1) base 2 4 {:fill col})))

;; ===== Leaves =====

(local leaf-cycle [(. pal :leaf-deep)
                   (. pal :leaf-mid)
                   (. pal :leaf-bright)])

;; One leaf: dark outline, body fill, bright highlight pixel. `lean`
;; decides which side it grows toward; `lw`/`lh` set its size.
(fn draw-one-leaf [ctx x y body lean lw lh]
  (let [dx (if (= lean :right) 0 (- 4 lw))]
    (ctx.rect (+ x dx)   y       lw       lh       {:fill (. pal :leaf-deep)})
    (ctx.rect (+ x dx 1) (+ y 1) (- lw 2) (- lh 2) {:fill body})
    (ctx.rect (+ x dx 2) (+ y 1) 3        2        {:fill (. pal :leaf-bright)})))

;; A full leaf is a small CLUSTER (main + two satellites) so each todo
;; reads as a leafy bunch and the canopy looks alive even with few items.
(fn draw-leaf [ctx x y body lean]
  (draw-one-leaf ctx (- x 6) (+ y 5) (. pal :leaf-deep) :left  10 7)
  (draw-one-leaf ctx (+ x 8) (+ y 4) (. pal :leaf-mid)  :right 10 7)
  (draw-one-leaf ctx x       y       body               lean   14 9))

(fn draw-leaf-fading [ctx x y body lean alpha]
  (let [dx (if (= lean :right) 0 -10)
        with-a (fn [c] [(. c 1) (. c 2) (. c 3) alpha])]
    (ctx.rect (+ x dx)     y       14 9 {:fill (with-a (. pal :leaf-deep))})
    (ctx.rect (+ x dx 1)   (+ y 1) 12 7 {:fill (with-a body)})
    (ctx.rect (+ x dx 2)   (+ y 1) 3  2 {:fill (with-a (. pal :leaf-bright))})))

;; Leaf at `growth` ∈ [0,1]. Below full size we draw a chunky bud in four
;; discrete stages for the pixel-art pop.
(fn draw-leaf-growing [ctx x y body lean growth]
  (let [stage (math.min 4 (math.floor (+ 1 (* growth 4))))]
    (if (>= stage 4)
        (draw-leaf ctx x y body lean)
        (let [size (* stage 3)
              dx-full (if (= lean :right) 0 -10)
              cx (+ x dx-full 7)
              bx (- cx (math.floor (/ size 2)))]
          (ctx.rect bx y size size {:fill body})))))

;; ===== Leaf-slot ordering =====
;; Slots run inner→tip along each branch. We then interleave ring-by-ring
;; ACROSS branches (ring 0 = innermost slot of every branch, ring 1 = next…)
;; so leaves fill the canopy evenly instead of loading one branch first.

(fn branch-slots [ax ay tx ty n]
  (let [out []]
    (for [i 0 (- n 1)]
      (let [f (+ 0.5 (* (if (> n 1) (/ i (- n 1)) 0) 0.62))
            jx (if (= 0 (% i 2)) 6 -6)
            sx (+ (math.floor (+ ax (* (- tx ax) f))) jx)
            sy (math.floor (+ ay (* (- ty ay) f)))]
        (table.insert out [sx sy])))
    out))

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

;; Draw one stage template at uniform scale s anchored at the trunk
;; base (bx, by). At s=1 every stage renders at its hand-drawn size.
(fn draw-stage [ctx bx by stage s]
  ;; roots flaring into the ground
  (each [_ r (ipairs stage.roots)]
    (paint-branch ctx (+ bx (* (. r 1) s)) (+ by (* (. r 2) s))
                  (+ bx (* (. r 3) s)) (+ by (* (. r 4) s))
                  (math.max 2 (math.floor (* (. r 5) s)))))
  ;; trunk (lit edge on the right)
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
  ;; knot markers
  (each [_ k (ipairs stage.knots)]
    (ctx.rect (math.floor (+ bx (* (. k 1) s)))
              (math.floor (+ by (* (. k 2) s))) 5 5
              {:fill (. pal :bark-mid)}))
  ;; branches
  (each [_ b (ipairs stage.branches)]
    (paint-branch ctx (+ bx (* (. b 1) s)) (+ by (* (. b 2) s))
                  (+ bx (* (. b 3) s)) (+ by (* (. b 4) s))
                  (math.max 3 (math.floor (* stage.thick s))))))

;; Empty-list marker: a dirt hump with a seed peeking out where the
;; trunk stood. Scales with s so the seedling visibly settles into it.
;; The seed is bone-white — the path below runs gold stones, so a gold
;; seed would vanish against them.
(fn draw-seed-mound [ctx bx by s]
  (ctx.rect (math.floor (- bx (* 18 s))) (math.floor (- by (* 5 s)))
            (math.max 4 (math.floor (* 36 s))) (math.max 2 (math.floor (* 10 s)))
            {:fill (. pal :ground-top)})
  (ctx.rect (math.floor (- bx (* 12 s))) (math.floor (- by (* 9 s)))
            (math.max 3 (math.floor (* 24 s))) (math.max 2 (math.floor (* 7 s)))
            {:fill (. pal :bark-dark)})
  (ctx.rect (math.floor (- bx (* 3 s))) (math.floor (- by (* 13 s)))
            (math.max 2 (math.floor (* 6 s))) (math.max 2 (math.floor (* 6 s)))
            {:fill (. pal :bone-white)})
  (ctx.rect (math.floor (- bx (* 1 s))) (math.floor (- by (* 12 s)))
            2 2 {:fill (. pal :sunset-gold)}))

;; ===== Canvas: forest-scene (full-window backdrop) =====

(canvas.register
  :forest-scene
  (fn [ctx]
    (let [w ctx.width
          h ctx.height
          horizon (horizon-y h)
          now (redin.now)
          band-h 6
          back-col (lerp-col (. pal :silhouette) (. pal :sky-low) 0.45)
          front-col (. pal :silhouette)]
      ;; --- sky gradient (banded) ---
      (var y 0)
      (while (< y horizon)
        (ctx.rect 0 y w band-h {:fill (grad sky-stops (/ (- horizon y) horizon))})
        (set y (+ y band-h)))
      ;; --- stars (upper sky; a few twinkle) ---
      (let [star-top (math.floor (* horizon 0.78))]
        (var s 991)
        (for [_ 1 70]
          (set s (lcg s))
          (let [sx (* 2 (math.floor (/ (% s w) 2)))]
            (set s (lcg s))
            (let [sy (* 2 (math.floor (/ (% s star-top) 2)))]
              (set s (lcg s))
              (let [tw (% s 100)
                    a (if (< tw 35)
                          (math.floor (+ 110 (* 130 (math.abs (math.sin (+ now (/ sx 40)))))))
                          210)]
                (ctx.rect sx sy 2 2 {:fill [210 214 196 a]}))))))
      ;; --- moon + halo (high-left, behind the canopy) ---
      (let [mx (math.floor (* w 0.2))
            my (math.floor (* horizon 0.42))]
        (ctx.circle mx my 34 {:fill [244 238 214 16]})
        (ctx.circle mx my 26 {:fill [244 238 214 28]})
        (ctx.circle mx my 18 {:fill (. pal :moon)})
        (ctx.circle (- mx 5) (- my 4) 4 {:fill [228 222 198]}))
      ;; --- distant treeline (two depth layers) ---
      (for [i 0 11]
        (conifer ctx (math.floor (* w (/ (+ i 0.3) 12))) horizon
                 (+ 26 (% (* i 37) 16)) back-col))
      (for [i 0 8]
        (conifer ctx (math.floor (* w (/ (+ i 0.7) 9))) (+ horizon 6)
                 (+ 34 (% (* i 53) 20)) front-col))
      ;; --- ground gradient ---
      (var gy horizon)
      (while (< gy h)
        (ctx.rect 0 gy w band-h
                  {:fill (lerp-col (. pal :ground-top) (. pal :ground-bot)
                                   (/ (- gy horizon) (math.max 1 (- h horizon))))})
        (set gy (+ gy band-h)))
      ;; --- dirt path leading to the trunk, with sunset-gold stones ---
      (let [px (- (math.floor (* w 0.36)) 28)]
        (ctx.rect px horizon 56 (- h horizon) {:fill [26 24 18 120]})
        (var i 0)
        (var sy horizon)
        (while (< sy h)
          (ctx.rect (+ px 24 (if (= 0 (% i 2)) -8 8)) sy 8 4 {:fill (. pal :sunset-gold)})
          (set sy (+ sy 26))
          (set i (+ i 1))))
      ;; --- floor texture: moss flecks, capped mushrooms, grass tufts ---
      (var s 42)
      (let [gh (math.max 1 (- h horizon))]
        (for [_ 1 220]
          (set s (lcg s))
          (let [x (* 2 (math.floor (/ (% s w) 2)))]
            (set s (lcg s))
            (let [yy (+ horizon (* 2 (math.floor (/ (% s gh) 2))))]
              (ctx.rect x yy 2 2 {:fill (. pal :moss)})))))
      (let [gh (math.max 1 (- h horizon 30))]
        (for [_ 1 26]
          (set s (lcg s))
          (let [mx (% s w)]
            (set s (lcg s))
            (let [my (+ horizon 20 (% s gh))]
              (ctx.rect mx my 3 5 {:fill (. pal :bone-white)})
              (ctx.rect (- mx 2) (- my 3) 7 4 {:fill (. pal :mushroom)})
              (ctx.rect (- mx 1) (- my 2) 2 1 {:fill [232 200 200]})))))
      (let [front-top (math.floor (* h 0.82))
            front-h (math.max 1 (math.floor (* h 0.16)))]
        (for [_ 1 60]
          (set s (lcg s))
          (let [gx (% s w)]
            (set s (lcg s))
            (let [gyy (+ front-top (% s front-h))]
              (ctx.rect gx       gyy       1 5 {:fill (. pal :grass)})
              (ctx.rect (- gx 2) (+ gyy 1) 1 4 {:fill (. pal :grass)})
              (ctx.rect (+ gx 2) (+ gyy 1) 1 4 {:fill (. pal :grass)})))))
      ;; --- fireflies (subtle, drifting) ---
      (for [i 1 7]
        (let [fx (math.floor (+ (* w (/ i 8)) (* 50 (math.sin (+ (* now 0.7) (* i 1.7))))))
              fy (math.floor (+ (* h 0.7) (* 40 (math.sin (+ (* now 0.5) (* i 2.3))))))
              a (math.floor (+ 90 (* 120 (math.abs (math.sin (+ (* now 2.2) i))))))]
          (ctx.circle fx fy 3 {:fill [200 220 110 (math.floor (/ a 5))]})
          (ctx.circle fx fy 1.5 {:fill [220 235 140 a]}))))))

;; ===== Canvas: tree-of-life (full-window hero) =====

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

;; ===== Canvas: vine (drag overlay) =====
;; Wraps the dragged row's preview with a growing vine + hanging tendrils.

(canvas.register
  :vine
  (fn [ctx]
    (let [w ctx.width
          h ctx.height
          start (subscribe :drag-start-time)
          now (redin.now)
          age (if start (- now start) 0)
          growth (math.min 1 age)
          halo-x 4
          halo-y 4
          halo-w (- w (* 2 halo-x))
          halo-h 50
          perimeter (* 2 (+ halo-w halo-h))
          drawn-len (* perimeter growth)
          step 6
          stem-size 6
          tuft-size 12
          tuft-every 5]
      (var dist 0)
      (var tuft-i 0)
      (each [_ edge (ipairs [[halo-x halo-y 1 0]
                             [(+ halo-x halo-w) halo-y 0 1]
                             [(+ halo-x halo-w) (+ halo-y halo-h) -1 0]
                             [halo-x (+ halo-y halo-h) 0 -1]])]
        (let [ex (. edge 1)
              ey (. edge 2)
              dx (. edge 3)
              dy (. edge 4)
              len (if (= 0 dx) halo-h halo-w)]
          (var t 0)
          (while (and (< t len) (< dist drawn-len))
            (let [px (math.floor (+ ex (* dx t)))
                  py (math.floor (+ ey (* dy t)))]
              (ctx.rect px py stem-size stem-size {:fill (. pal :leaf-deep)})
              (ctx.rect (+ px 2) (+ py 2) 2 2 {:fill (. pal :leaf-mid)})
              (when (= 0 (% tuft-i tuft-every))
                (let [bob (if (>= growth 1)
                              (math.floor (* 2 (math.sin (+ now tuft-i))))
                              0)
                      tx (- px 2)
                      ty (+ py bob -3)]
                  (ctx.rect tx ty tuft-size tuft-size {:fill (. pal :leaf-deep)})
                  (ctx.rect (+ tx 2) (+ ty 2) (- tuft-size 4) (- tuft-size 4)
                            {:fill (. pal :leaf-mid)})
                  (ctx.rect (+ tx 4) (+ ty 3) 3 3 {:fill (. pal :leaf-bright)})))
              (set tuft-i (+ tuft-i 1))
              (set dist (+ dist step))
              (set t (+ t step))))))
      (when (>= growth 1)
        (let [drop-top (+ halo-y halo-h)
              drop-room (- h drop-top)
              reach (math.floor (* (math.min 1 (- age 1)) drop-room))
              steps (math.floor (/ reach 4))
              cols [(+ halo-x 20)
                    (+ halo-x (math.floor (/ halo-w 3)))
                    (+ halo-x (math.floor (/ (* halo-w 2) 3)))
                    (+ halo-x halo-w -20)]]
          (each [col-i cx (ipairs cols)]
            (let [sway-amp (math.sin (+ (* now 1.2) col-i))]
              (for [j 0 steps]
                (let [ty (+ drop-top (* j 4))
                      tx (+ cx (math.floor (* sway-amp (* j 0.6))))]
                  (ctx.rect tx ty 5 5 {:fill (. pal :leaf-deep)})
                  (ctx.rect (+ tx 1) (+ ty 1) 2 2 {:fill (. pal :leaf-mid)})
                  (when (and (= (% j 3) 0) (> j 0))
                    (let [side (if (= (% (+ col-i j) 2) 0) 5 -8)]
                      (ctx.rect (+ tx side) (+ ty 1) 8 6 {:fill (. pal :leaf-deep)})
                      (ctx.rect (+ tx side 1) (+ ty 2) 6 4 {:fill (. pal :leaf-mid)})
                      (ctx.rect (+ tx side 2) (+ ty 2) 2 2 {:fill (. pal :leaf-bright)})))))
              (when (> steps 2)
                (let [ty (+ drop-top (* steps 4))
                      tx (+ cx (math.floor (* sway-amp (* steps 0.6))))]
                  (ctx.rect (- tx 4) ty 12 8 {:fill (. pal :leaf-deep)})
                  (ctx.rect (- tx 3) (+ ty 1) 10 6 {:fill (. pal :leaf-mid)})
                  (ctx.rect (- tx 1) (+ ty 2) 3 3 {:fill (. pal :leaf-bright)}))))))))))

;; ===== Canvas: vine-grip (leaf-bud drag handle / bullet) =====

(canvas.register
  :vine-grip
  (fn [ctx]
    (let [cx (/ ctx.width 2)
          cy (/ ctx.height 2)]
      ;; stem
      (ctx.rect (- cx 1) cy 2 8 {:fill (. pal :leaf-deep)})
      ;; bud leaf
      (ctx.rect (- cx 5) (- cy 6) 10 8 {:fill (. pal :leaf-deep)})
      (ctx.rect (- cx 4) (- cy 5) 8  6 {:fill (. pal :leaf-mid)})
      (ctx.rect (- cx 2) (- cy 4) 2  2 {:fill (. pal :leaf-bright)}))))

;; ===== Theme =====

(theme-mod.set-theme
  {:canopy        {:bg [30 38 32]
                   :padding [20 22 20 22]
                   :radius 10
                   :opacity 0.9
                   :shadow [0 8 28 [0 0 0 160]]}
   :heading       {:font-size 24 :weight 1 :color (. pal :bone-white)}
   :body          {:font-size 14 :color (. pal :bone-white)}
   :count-badge   {:font-size 12 :weight 1 :color (. pal :night-soil)
                   :bg (. pal :sunset-gold) :radius 9 :padding [3 10 3 10]}

   :trail         {:padding [6 8 6 8] :radius 6}
   :trail#hover   {:bg (. pal :moss) :padding [6 8 6 8] :radius 6}
   :row-vining    {:bg (. pal :leaf-mid)
                   :color (. pal :night-soil)
                   :padding [6 8 6 8]
                   :radius 6
                   :shadow [0 4 16 [0 0 0 140]]}
   :row-drop-hot  {:bg [90 130 60] :padding [6 8 6 8] :radius 6}
   :muted-armed   {:bg [40 50 42 180] :radius 6}

   :bark          {:bg (. pal :bark-dark)
                   :color (. pal :bone-white)
                   :border (. pal :bark-mid)
                   :border-width 1
                   :radius 6
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

;; Seed count from TREEDO_ITEMS (default 100). The four named todos lead;
;; the rest are generated. born=0 renders every seeded leaf at full growth
;; (no per-frame growth animation skew when profiling).
(local starter ["Plant the seed"
                "Water the sapling"
                "Watch the canopy grow"
                "Sweep the leaves"])

(local seed-count (or (tonumber (os.getenv "TREEDO_ITEMS")) 100))

(local seed-items
       (let [out []]
         (for [i 1 seed-count]
           (table.insert out {:text (or (. starter i) (.. "Todo item #" i))
                              :born 0}))
         out))

(dataflow.init {:items seed-items
                :input-value ""
                :drag-start-time nil
                :falling-leaves []})

;; ===== Subscriptions =====

(reg-sub :items (fn [db] (get db :items [])))
(reg-sub :input-value (fn [db] (get db :input-value "")))
(reg-sub :drag-start-time (fn [db] (get db :drag-start-time)))
(reg-sub :falling-leaves (fn [db] (get db :falling-leaves [])))

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

;; Periodic prune of falling-leaf entries older than 2 seconds; re-arms
;; itself via :dispatch-later, so the loop runs forever at ~2s intervals.
(reg-handler :tick/clear-fallen
             (fn [db event]
               (let [now (redin.now)]
                 {:db (update db :falling-leaves
                              (fn [leaves]
                                (icollect [_ l (ipairs leaves)]
                                  (when (< (- now l.spawn) 2) l))))
                  :dispatch-later {:ms 2000 :dispatch [:tick/clear-fallen]}})))

(reg-handler :event/drag
             (fn [db event]
               (assoc db :drag-start-time (redin.now))))

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
               (assoc db :drag-start-time nil)))

;; ===== View =====

(global main_view
        (fn []
          (let [items     (subscribe :items)
                input-val (subscribe :input-value)
                count     (length items)]
            [:stack
             {:viewport [[:top_left 0 0 :full :full]
                         [:top_left 0 0 :full :full]
                         [:center_right -40 0 440 :2_3]]}
             [:canvas {:provider :forest-scene :width :full :height :full}]
             [:canvas {:provider :tree-of-life :width :full :height :full}]
             [:vbox {:aspect :canopy}
              [:hbox {:height 30 :layout :center}
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
              [:vbox
               {:height :full
                :overflow :scroll-y
                :drag-over [:row-drag {:event :event/over :aspect :muted-armed}]}
               (icollect [i item (ipairs items)]
                 [:hbox {:layout :center :aspect :trail :height 42
                         :draggable [:row-drag
                                     {:mode :preview
                                      :handle false
                                      :event :event/drag
                                      :aspect :row-vining
                                      :animate {:provider :vine
                                                :rect [:top_left -8 -8 416 120]
                                                :z :above}}
                                     i]
                         :dropable [:row-drag
                                    {:event :event/drop
                                     :aspect :row-drop-hot}
                                    i]}
                  [:vbox {:width 24 :height 42 :drag-handle true}
                   [:canvas {:provider :vine-grip :width 24 :height 42}]]
                  [:text {:aspect :body :width :full} item.text]
                  [:button {:aspect :mushroom
                            :width 32 :height 32
                            :click [:test/remove i]} "x"]])]]])))

;; Bootstrap the falling-leaf cleanup loop.
(dispatch [:tick/clear-fallen])
