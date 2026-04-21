;; Nested-listener resolution test. The kitchen-sink pattern: a button
;; (with :click) inside a hbox (with :draggable). Clicking the button must
;; fire the click listener, not the ancestor's drag path.
;;
;; Layout (no :layout attr): root vbox is full window. The draggable hbox
;; fills vbox width (anchor_h=0). Inside the hbox, the button has explicit
;; width=100 and lives at x=0..100, y=0..80. Inner-button center ≈ (50,40).
;; Click anywhere else at y<80 lands on the hbox background (no click
;; listener there).
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:surface {:bg [30 30 30]}
   :drag    {:bg [70 90 70]}
   :btn     {:bg [120 120 180] :color [240 240 240]}
   :body    {:font-size 14 :color [220 220 220]}})

(dataflow.init {:last nil :drag-count 0})
(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :event/drag-inner-click
  (fn [db _] (assoc db :last "drag-inner")))

(reg-handler :event/drag-start
  (fn [db _]
    (assoc (assoc db :last "drag-start")
           :drag-count (+ 1 (get db :drag-count 0)))))

(reg-handler :event/reset
  (fn [db _] (assoc (assoc db :last nil) :drag-count 0)))

(reg-sub :last (fn [db] (get db :last)))
(reg-sub :drag-count (fn [db] (get db :drag-count 0)))

(global main_view
  (fn []
    [:vbox {:aspect :surface}
     [:hbox {:id :drag-row
             :aspect :drag
             :height 80
             :draggable [:row :event/drag-start 1]}
      [:button {:id :drag-inner
                :aspect :btn
                :width 100 :height 60
                :click [:event/drag-inner-click]}
       "DragInner"]]]))
