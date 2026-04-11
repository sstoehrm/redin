;; Test app for drag-and-drop UI tests
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:surface {:bg [46 52 64] :padding [24 24 24 24]}
   :body    {:font-size 14 :color [216 222 233]}
   :row     {:padding [4 4 4 4]}
   :row#drag {:bg [76 86 106]}
   :row#drag-start {:bg [136 46 106]}})

(dataflow.init
  {:items [{:text "A"} {:text "B"} {:text "C"} {:text "D"}]
   :last-drag nil
   :last-drop nil})

(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :event/drag
  (fn [db event]
    (let [ctx (. event 2)]
      (assoc db :last-drag ctx.value))))

(reg-handler :event/drop
  (fn [db event]
    (let [ctx (. event 2)]
      (assoc db :last-drop {:from ctx.from :to ctx.to})
      ;; Reorder items: move item at :from to position :to
      (let [from-idx ctx.from
            to-idx ctx.to
            items (get db :items [])]
        (when (and from-idx to-idx
                   (> from-idx 0) (<= from-idx (length items))
                   (> to-idx 0) (<= to-idx (length items))
                   (not= from-idx to-idx))
          (let [item (. items from-idx)
                new-items (icollect [i v (ipairs items)]
                            (when (not= i from-idx) v))]
            ;; Insert at to-idx (adjust if removing shifted indices)
            (let [insert-at (if (> from-idx to-idx) to-idx (- to-idx 1))]
              (table.insert new-items (math.min insert-at (+ (length new-items) 1)) item)
              (assoc db :items new-items)))))
      db)))

(reg-handler :event/reset
  (fn [db event]
    (assoc (assoc (assoc db :items [{:text "A"} {:text "B"} {:text "C"} {:text "D"}])
                  :last-drag nil)
           :last-drop nil)))

(reg-sub :items (fn [db] (get db :items [])))
(reg-sub :last-drag (fn [db] (get db :last-drag)))
(reg-sub :last-drop (fn [db] (get db :last-drop)))

(global main_view
  (fn []
    (let [items (subscribe :items)
          last-drag (subscribe :last-drag)
          last-drop (subscribe :last-drop)]
      [:vbox {:aspect :surface}
       [:text {:id :title :aspect :body} "Drag Test"]
       [:text {:id :last-drag-val :aspect :body}
        (.. "drag:" (tostring (or last-drag "")))]
       [:text {:id :last-drop-from :aspect :body}
        (.. "drop-from:" (tostring (or (and last-drop last-drop.from) "")))]
       [:text {:id :last-drop-to :aspect :body}
        (.. "drop-to:" (tostring (or (and last-drop last-drop.to) "")))]
       [:vbox {:id :item-list}
        (icollect [i item (ipairs (or items []))]
          [:hbox {:id (.. :row- (tostring i))
                  :aspect :row
                  :height 42
                  :draggable [:row :event/drag i]
                  :dropable [:row :event/drop i]}
           [:text {:id (.. :item- (tostring i)) :aspect :body} item.text]])]])))
