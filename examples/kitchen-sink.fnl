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
                     ;; Dark base
                     (ctx.rect 0 0 w h {:fill [30 34 46]})
                     ;; Drifting orbs — slow sine/cosine motion, muted colors, low alpha
                     (for [i 1 8]
                       (let [speed (* 0.15 (+ 1 (* i 0.3)))
                             phase (* i 1.7)
                             r (+ 40 (* 30 i))
                             x (+ (* w 0.5)
                                  (* (* w 0.4) (math.sin (+ (* t speed) phase))))
                             y (+ (* h 0.5)
                                  (* (* h 0.35)
                                     (math.cos (+ (* t speed 0.7) (* phase 1.3)))))
                             pulse (+ 0.7
                                      (* 0.3 (math.sin (+ (* t 0.5) phase))))
                             alpha (math.floor (* 18 pulse))]
                         (ctx.circle x y r {:fill [67 76 94 alpha]})))
                     ;; Subtle accent orbs — brighter, smaller
                     (for [i 1 4]
                       (let [speed (* 0.1 (+ 1 (* i 0.5)))
                             phase (* i 2.3)
                             r (+ 20 (* 15 i))
                             x (+ (* w 0.3)
                                  (* (* w 0.5) (math.cos (+ (* t speed) phase))))
                             y (+ (* h 0.4)
                                  (* (* h 0.4)
                                     (math.sin (+ (* t speed 0.8) (* phase 0.9)))))
                             alpha (math.floor (+ 10
                                                  (* 8
                                                     (math.sin (+ (* t 0.4)
                                                                  phase)))))]
                         (ctx.circle x y r {:fill [94 129 172 alpha]}))))))

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

;; ===== Theme =====

(theme-mod.set-theme {:surface {:bg [46 52 64]
                                :padding [24 24 24 24]
                                :opacity 0.5}
                      :heading {:font-size 24 :color [236 239 244] :weight 1}
                      :body {:font-size 14 :color [216 222 233]}
                      :status-field {:font-size 14
                                     :bg [26 32 34]
                                     :color [216 222 233]
                                     :border [255 255 255]
                                     :border_width 2
                                     :radius 4}
                      :row {:padding [4 4 4 4]}
                      :row-dragging {:bg [136 46 106]
                                     :padding [4 4 4 4]
                                     :radius 4}
                      :row-drop-hot {:bg [76 86 106]
                                     :padding [4 4 4 4]}
                      :muted {:font-size 13 :color [76 86 106]}
                      :muted-armed {:font-size 13
                                    :color [76 86 106]
                                    :bg [54 60 72]}
                      :input {:bg [59 66 82]
                              :color [236 239 244]
                              :border [76 86 106]
                              :border-width 1
                              :radius 4
                              :padding [8 12 8 12]
                              :font-size 14}
                      :input#focus {:border [136 192 208]}
                      :button {:bg [76 86 106]
                               :color [236 239 244]
                               :radius 6
                               :padding [6 14 6 14]
                               :font-size 13}
                      :button#hover {:bg [94 105 126]}
                      :button#active {:bg [59 66 82]}})

;; ===== State =====

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

;; ===== Subscriptions =====

(reg-sub :items (fn [db] (get db :items [])))
(reg-sub :input-value (fn [db] (get db :input-value "")))

;; ===== View =====

(global main_view (fn []
                    (let [items (subscribe :items)
                          input-val (subscribe :input-value)]
                      [:vbox
                       {}
                       [:stack
                        {:viewport [[:top_left 0 0 :full :full]
                                    [:top_left 0 0 :full :full]
                                    [:bottom_center 0 0 :1_4 42]]}
                        [:canvas
                         {:provider :background :width :full :height :full}]
                        [:vbox
                         {:aspect :surface}
                         [:text {:aspect :heading :layout :center} "Todo List"]
                         [:input
                          {:aspect :input
                           :width 250
                           :height 42
                           :value input-val
                           :change [:test/input]
                           :key [:test/add]}]
                         [:button
                          {:width 250
                           :height 42
                           :aspect :button
                           :click [:test/add]
                           :animate {:provider :pulse-dot
                                     :rect [:top_right -8 -8 16 16]
                                     :z :above}}
                          "Add"]
                         [:vbox
                          {:overflow :scroll-y
                           :aspect :muted
                           :drag-over [:row-drag
                                       {:event :event/over
                                        :aspect :muted-armed}]}
                          (icollect [i item (ipairs (or items []))]
                            [:hbox
                             {:layout :center
                              :aspect :row
                              :height 42
                              :draggable [:row-drag
                                          {:mode :preview
                                           :event :event/drag
                                           :aspect :row-dragging
                                           :animate {:provider :pulse-dot
                                                     :rect [:top_right -6 -6 12 12]
                                                     :z :above}}
                                          i]
                              :dropable [:row-drag
                                         {:event :event/drop
                                          :aspect :row-drop-hot}
                                         i]}
                             [:text {:aspect :body} item.text]
                             [:button
                              {:width 250
                               :aspect :button
                               :click [:test/remove i]}
                              "remove"]])]]
                        [:hbox
                         {:height 42 :aspect :status-field :layout :center}
                         [:text
                          {:aspect :body :layout :center}
                          (.. "Todos: " (length items))]]]])))
