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

;; Draws a leaf at `growth` ∈ [0,1] of its full size. Below 1.0 we draw
;; a smaller pixel-art "bud" using fewer big-pixels — four discrete
;; growth stages give the chunky pop.
(fn draw-leaf-growing [ctx x y body lean growth]
  (let [stage (math.min 4 (math.floor (+ 1 (* growth 4))))]
    (if (>= stage 4)
        (draw-leaf ctx x y body lean)
        (let [size (* stage 2)
              dx-full (if (= lean :right) 0 -8)
              cx (+ x dx-full 6)
              bx (- cx (math.floor (/ size 2)))]
          (ctx.rect bx y size size {:fill body})))))

(canvas.register
  :tree-of-life
  (fn [ctx]
    (draw-trunk-and-branches ctx)
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
          (draw-leaf-growing ctx (+ sx sway) sy body lean growth))))))

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

;; ===== View =====

(global main_view
        (fn []
          (let [items     (subscribe :items)
                input-val (subscribe :input-value)
                count     (length items)]
            [:stack
             {:viewport [[:top_left 0 0 :full :full]
                         [:bottom_left 16 -16 240 320]
                         [:top_center 0 32 480 :full]]}
             [:canvas {:provider :forest-floor :width :full :height :full}]
             [:canvas {:provider :tree-of-life :width 240 :height 320}]
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
