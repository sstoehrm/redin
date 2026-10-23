;; Test app for intrinsic (content) height inside scroll-y containers.
;; No aspects anywhere, so no padding enters the math.
;;
;;   s   (scroll-y): a vbox holding a vertically-margined text and a plain
;;       text, then a sibling. The margined text must be exactly one line
;;       tall (margin reserved once, outside its rect) — review C12: the
;;       margin used to be added twice through a shared cache slot.
(local dataflow (require :dataflow))

(dataflow.init {})
(global redin_get_state (. dataflow :_get-raw-db))

(global main_view
  (fn []
    [:vbox {}
     [:vbox {:id :s :overflow :scroll-y :height 200}
      [:vbox {:id :inner}
       [:text {:id :t1 :margin [10 0 10 0]} "first"]
       [:text {:id :t2} "second"]]
      [:text {:id :after} "after"]]]))
