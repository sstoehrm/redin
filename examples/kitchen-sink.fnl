;; Kitchen-sink example — todo list with themed UI.

(local dataflow (require :dataflow))
(local theme-mod (require :theme))

;; ===== Theme =====

(theme-mod.set-theme {:surface {:bg [46 52 64] :padding [24 24 24 24]}
                      :heading {:font-size 24 :color [236 239 244] :weight 1}
                      :body {:font-size 14 :color [216 222 233]}
                      :row {:padding [4 4 4 4]}
                      :row#drag {:bg [76 86 106]}
                      :row#drag-start {:bg [136 46 106]}
                      :muted {:font-size 13 :color [76 86 106]}
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

(reg-handler :event/drop
  (fn [db event]
    (let [ctx (. event 2)
          from-idx ctx.from
          to-idx ctx.to
          items (get db :items [])]
      (when (and from-idx to-idx
                 (> from-idx 0) (<= from-idx (length items))
                 (> to-idx 0) (<= to-idx (length items))
                 (not= from-idx to-idx))
        (let [item (. items from-idx)
              new-items (icollect [i v (ipairs items)]
                          (when (not= i from-idx) v))]
          (let [insert-at (if (> from-idx to-idx) to-idx (- to-idx 1))]
            (table.insert new-items (math.min insert-at (+ (length new-items) 1)) item)
            (assoc db :items new-items)))))
    db))

;; ===== Subscriptions =====

(reg-sub :items (fn [db] (get db :items [])))
(reg-sub :input-value (fn [db] (get db :input-value "")))

;; ===== View =====

(global main_view
        (fn []
          (let [items (subscribe :items)
                input-val (subscribe :input-value)]
            [:vbox
             {}
             [:stack
              {:viewport [[0 0 :full :full] [:1_2 :1_2 :1_4 42]]}
              [:vbox
               {:aspect :surface :layout :center}
               [:text {:aspect :heading :layout :center} "Todo List"]
               [:input
                {:aspect :input
                 :width 250
                 :height 42
                 :value input-val
                 :change [:test/input]
                 :key [:test/add]}]
               [:button
                {:width 250 :height 42 :aspect :button :click [:test/add]}
                "Add"]
               [:vbox
                {:overflow :scroll-y :aspect :muted}
                (icollect [i item (ipairs (or items []))]
                  [:hbox
                   {:layout :center
                    :aspect :row
                    :height 42
                    :draggable [:row :event/drag i]
                    :dropable [:row :event/drop i]}
                   [:text {:aspect :body} item.text]
                   [:button
                    {:width 250 :aspect :button :click [:test/remove i]}
                    "remove"]])]]
              [:hbox
               {:height 42 :aspect :body}
               [:text {:aspect :body} (.. "Todos: " (length items))]]]])))
