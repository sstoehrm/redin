;; Test app for drag-and-drop UI tests (v2 API)
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:surface       {:bg [46 52 64] :padding [24 24 24 24]}
   :body          {:font-size 14 :color [216 222 233]}
   :row           {:padding [4 4 4 4]}
   :row-dragging  {:bg [136 46 106] :padding [4 4 4 4] :radius 4}
   :row-drop-hot  {:bg [76 86 106] :padding [4 4 4 4]}
   :muted         {:font-size 13 :color [76 86 106]}
   :muted-armed   {:font-size 13 :color [76 86 106] :bg [54 60 72]}})

(dataflow.init
  {:items [{:text "A" :kind :sword}
           {:text "B" :kind :shield}
           {:text "C" :kind :sword}
           {:text "D" :kind :shield}]
   :last-drag nil
   :last-drop nil
   :last-over nil})

(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :event/drag
  (fn [db event]
    (let [ctx (. event 2)]
      (assoc db :last-drag ctx.value))))

(reg-handler :event/over
  (fn [db event]
    (let [ctx (. event 2)]
      (assoc db :last-over ctx.phase))))

(reg-handler :event/drop
  (fn [db event]
    (let [ctx (. event 2)
          from-idx ctx.from
          to-idx   ctx.to
          items    (get db :items [])]
      (assoc db :last-drop {:from from-idx :to to-idx})
      (when (and from-idx to-idx
                 (> from-idx 0) (<= from-idx (length items))
                 (> to-idx 0)   (<= to-idx (length items))
                 (not= from-idx to-idx))
        (let [item (. items from-idx)
              new-items (icollect [i v (ipairs items)]
                          (when (not= i from-idx) v))]
          (let [insert-at (if (> from-idx to-idx) to-idx (- to-idx 1))]
            (table.insert new-items (math.min insert-at (+ (length new-items) 1)) item)
            (assoc db :items new-items))))
      db)))

(reg-handler :event/reset
  (fn [db event]
    (-> db
        (assoc :items [{:text "A" :kind :sword}
                       {:text "B" :kind :shield}
                       {:text "C" :kind :sword}
                       {:text "D" :kind :shield}])
        (assoc :last-drag nil)
        (assoc :last-drop nil)
        (assoc :last-over nil))))

(reg-sub :items     (fn [db] (get db :items [])))
(reg-sub :last-drag (fn [db] (get db :last-drag)))
(reg-sub :last-drop (fn [db] (get db :last-drop)))
(reg-sub :last-over (fn [db] (get db :last-over)))

(global main_view
  (fn []
    (let [items (subscribe :items)]
      [:vbox {:aspect :surface}
       [:text {:id :title :aspect :body} "Drag Test v2"]
       [:vbox {:id :item-list
               :aspect :muted
               :drag-over [:item {:event :event/over :aspect :muted-armed}]}
        (icollect [i item (ipairs (or items []))]
          [:hbox {:id (.. :row- (tostring i))
                  :aspect :row
                  :height 42
                  :draggable [[:item item.kind]
                              {:mode :preview
                               :event :event/drag
                               :aspect :row-dragging}
                              i]
                  :dropable [[:item item.kind]
                             {:event :event/drop
                              :aspect :row-drop-hot}
                             i]}
           [:text {:id (.. :item- (tostring i)) :aspect :body} item.text]])]
       [:vbox {:id :handle-row-demo :aspect :muted}
        [:hbox {:id :handle-row
                :aspect :muted :height 42
                :draggable [:demo
                            {:mode :preview
                             :handle false
                             :event :event/drag
                             :aspect :row-dragging} 99]}
         [:vbox {:id :handle-grip
                 :width 24 :height 24
                 :aspect :muted
                 :drag-handle true}]
         [:text {:id :handle-row-text :aspect :body} "drag me by the grip"]]]
       ])))
