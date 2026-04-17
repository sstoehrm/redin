;; Test app for window resize. Places four buttons using a viewport
;; stack with different anchors; each anchor type must adapt as the
;; window is resized.
;;
;;   1 = top-left fixed offset (should stay at the same pixel position)
;;   2 = centered (should follow window center)
;;   3 = bottom-right (should hug the bottom-right corner)
;;   4 = fractional position (should sit at 1/4 W, 3/4 H)
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:pick {:bg [100 100 140] :color [240 240 240]
          :radius 3 :padding [4 8 4 8] :font-size 14}})

(dataflow.init {:picked 0})
(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :event/pick
  (fn [db event]
    (let [which (. event 2)]
      (assoc db :picked which))))

(reg-sub :picked (fn [db] (get db :picked 0)))

(global main_view
  (fn []
    (let [_ (subscribe :picked)]
      [:stack {:viewport [[:top_left     10 10 100 40]
                          [:center        0  0 100 40]
                          [:bottom_right  0  0 100 40]
                          [:top_left    :1_4 :3_4 100 40]]}
       [:button {:id :btn-tl :aspect :pick :click [:event/pick 1]} "tl"]
       [:button {:id :btn-c  :aspect :pick :click [:event/pick 2]} "c"]
       [:button {:id :btn-br :aspect :pick :click [:event/pick 3]} "br"]
       [:button {:id :btn-f  :aspect :pick :click [:event/pick 4]} "f"]])))
