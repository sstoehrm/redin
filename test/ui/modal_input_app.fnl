;; Test app for an input inside a :modal that sits over tall selectable
;; page text (review C11). The page text's rect covers the modal's
;; input, so a text-selection hit test that accepts *any* selectable
;; node under the pointer (instead of the deepest winner) would start a
;; selection on the page text and drop the input's focus.
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:input   {:bg [59 66 82] :color [236 239 244] :padding [8 12 8 12] :font-size 14}
   :body    {:font-size 14 :color [0 0 0]}
   :overlay {:bg [0 0 0] :opacity 0.5}
   :dialog  {:bg [200 200 200] :padding [24 24 24 24]}})

(dataflow.init {:v "hello"})

(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :event/reset (fn [db _] (assoc db :v "hello")))
(reg-handler :event/chg (fn [db [_ ctx]] (assoc db :v ctx.value)))

(reg-sub :v (fn [db] (get db :v)))

(global main_view
  (fn []
    [:vbox {}
     [:text {:id :page :aspect :body :height 700}
      (string.rep "page text line\n" 45)]
     [:modal {:aspect :overlay}
      [:vbox {:aspect :dialog :width 300 :height 200 :layout :center}
       [:input {:id :modal-input :aspect :input :width 250 :height 40
                :value (subscribe :v) :change [:event/chg]}]]]]))
