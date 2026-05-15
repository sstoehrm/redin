;; Kitchen-sink example — todo list with themed UI.

(local dataflow (require :dataflow))
(local theme-mod (require :theme))
(local canvas (require :canvas))

;; ===== Background animation =====

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
                                   {:stroke [0 0 0 a] :stroke-width 1}))))))

;; ===== Micro-animation =====
;; A small pulsing dot used as an :animate decoration on the Add button —
;; demonstrates how a canvas provider can be anchored to the corner of any
;; element via the :animate attribute (see docs/core-api.md § Animation).

(canvas.register :pulse-dot
                 (fn [ctx]
                   (let [t (redin.now)
                         pulse (+ 0.5 (* 0.5 (math.sin (* t 3))))
                         r (+ 4 (* 2 pulse))
                         alpha (math.floor (+ 150 (* 105 pulse)))]
                     (ctx.circle (/ ctx.width 2) (/ ctx.height 2) r
                                 {:fill [235 203 139 alpha]}))))

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

;; ===== Theme =====

(theme-mod.set-theme {;; --- Surfaces / text ---
                      :surface       {:bg [46 52 64]
                                      :padding [20 20 20 20]
                                      :radius 8}
                      :heading       {:font-size 22 :weight 1 :color [236 239 244]}
                      :body          {:font-size 14 :color [216 222 233]}
                      :count-badge   {:font-size 12 :color [129 138 155]}

                      ;; --- Rows ---
                      :row           {:padding [4 4 4 4]}
                      :row#hover     {:bg [59 66 82] :padding [4 4 4 4]}
                      :row-dragging  {:bg [94 129 172]
                                      :color [30 34 46]
                                      :padding [4 4 4 4]
                                      :shadow [0 4 16 [0 0 0 120]]}
                      :row-drop-hot  {:bg [75 110 135]
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
                      :button-primary#active {:bg [122 162 175]}
                      :button-icon          {:bg [59 66 82]
                                             :color [129 138 155]
                                             :radius 6
                                             :padding [4 4 4 4]
                                             :font-size 16}
                      :button-icon#hover    {:color [191 97 106]}
                      :button-icon#active   {:bg [76 86 106]}})

;; ===== State =====

(global redin_get_state (. dataflow :_get-raw-db))

(dataflow.init {:items [{:text "Test 1"}
                        {:text "Test 2"}
                        {:text "Test 3"}
                        {:text "Test 4"}
                        {:text "Test 5"}
                        {:text "Test 6"}
                        {:text "Test 7"}
                        {:text "Test 8"}
                        {:text "Test 9"}
                        {:text "Test 10"}
                        {:text "Test 11"}
                        {:text "Test 12"}
                        {:text "Test 13"}
                        {:text "Test 14"}
                        {:text "Test 15"}
                        {:text "Test 16"}
                        {:text "Test 17"}
                        {:text "Test 18"}
                        {:text "Test 19"}
                        {:text "Test 20"}
                        {:text "Test 21"}
                        {:text "Test 22"}
                        {:text "Test 23"}
                        {:text "Test 24"}]
                :input-value ""})

;; ===== Handlers =====

(reg-handler :test/input (fn [db event]
                           (let [ctx (. event 2)]
                             (assoc db :input-value (or ctx.value "")))
                           db))

(reg-handler :test/add (fn [db event]
                         (let [val (get db :input-value "")]
                           (when (> (string.len val) 0)
                             (update db :items
                                     (fn [items]
                                       (table.insert items {:text val})
                                       items))
                             (assoc db :input-value "")))
                         db))

(reg-handler :test/remove (fn [db event]
                            (let [idx (. event 2)]
                              (when idx
                                (update db :items
                                        (fn [items]
                                          (icollect [i item (ipairs items)]
                                            (when (not= i idx) item))))))
                            db))

(reg-handler :event/drag (fn [db event] db))

(reg-handler :event/over (fn [db event] db))

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

;; ===== Subscriptions =====

(reg-sub :items (fn [db] (get db :items [])))
(reg-sub :input-value (fn [db] (get db :input-value "")))

;; ===== View =====

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
               [:vbox {:width :full}] ; flex spacer
               [:text {:aspect :count-badge} (.. count " items")]]
              [:vbox {:height 16}]                                 ; 16px gap before input
              ;; Input + Add side by side.
              [:hbox
               {:height 42}
               [:input {:aspect :input
                        :width :full
                        :height 42
                        :value input-val
                        :change [:test/input]
                        :key [:test/add]}]
               [:vbox {:width 8}] ; 8px gap
               [:button {:aspect :button-primary
                         :width 72
                         :height 42
                         :click [:test/add]
                         :animate {:provider :pulse-dot
                                   :rect [:top_right -8 -8 16 16]
                                   :z :above}}
                "Add"]]
              [:vbox {:height 12}]                                  ; 12px gap before list
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
                   "x"]])]]])))
