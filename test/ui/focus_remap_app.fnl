;; Review C4: per-index state (input focus, scroll offsets) must follow
;; its node when a re-render inserts or removes a node before it.
;;
;; Layout (root vbox children):
;;   banner   — optional; hiding it shifts every later DFS index by one
;;   input A  — :change [:ev/a], optional (removable via :ev/drop-a)
;;   input B  — :change [:ev/b]
;;   pane 1   — scroll-y, 20 rows of 30px in 100px
;;   pane 2   — scroll-y, 20 rows of 30px in 100px
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:input {:bg [59 66 82] :color [236 239 244] :padding [8 12 8 12] :font-size 14}
   :body  {:font-size 14 :color [0 0 0]}
   :pane  {:bg [220 220 220]}
   :row   {:font-size 12 :color [0 0 0]}})

(dataflow.init {:a "alpha" :b "bravo" :show true :show-a true})
(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :ev/reset
  (fn [db _]
    (-> db
        (assoc :a "alpha") (assoc :b "bravo")
        (assoc :show true) (assoc :show-a true))))
(reg-handler :ev/a (fn [db [_ ctx]] (assoc db :a ctx.value)))
(reg-handler :ev/b (fn [db [_ ctx]] (assoc db :b ctx.value)))
(reg-handler :ev/hide (fn [db _] (assoc db :show false)))
(reg-handler :ev/drop-a (fn [db _] (assoc db :show-a false)))

(reg-sub :a (fn [db] (get db :a)))
(reg-sub :b (fn [db] (get db :b)))
(reg-sub :show (fn [db] (get db :show)))
(reg-sub :show-a (fn [db] (get db :show-a)))

(fn pane [id]
  [:vbox {:id id :aspect :pane :width 300 :height 100 :overflow :scroll-y}
   (icollect [i (ipairs [1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20])]
     [:text {:aspect :row :height 30} (.. (tostring id) " row " i)])])

(global main_view
  (fn []
    [:vbox {}
     (when (subscribe :show) [:text {:id :banner :aspect :body :height 30} "banner"])
     (when (subscribe :show-a)
       [:input {:id :ia :aspect :input :width 250 :height 40
                :value (subscribe :a) :change [:ev/a]}])
     [:input {:id :ib :aspect :input :width 250 :height 40
              :value (subscribe :b) :change [:ev/b]}]
     (pane :pane1)
     (pane :pane2)]))
