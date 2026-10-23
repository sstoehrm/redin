;; Test app for intrinsic (content) height inside scroll-y containers.
;; No aspects anywhere, so no padding enters the math.
;;
;;   s   (scroll-y): a vbox holding a vertically-margined text and a plain
;;       text, then a sibling. The margined text must be exactly one line
;;       tall (margin reserved once, outside its rect) — review C12: the
;;       margin used to be added twice through a shared cache slot.
;;   s2  (scroll-y): an hbox with a fixed 1240px image and a fill text.
;;       The fill text is laid out at the remaining 40px, so the hbox's
;;       intrinsic height must be measured at 40px too, not at inner_w/n.
;;   ref: the same text laid out at 40px in an ordinary (non-scroll) vbox,
;;       giving the expected wrapped height without hardcoding fonts.
(local dataflow (require :dataflow))

(dataflow.init {})
(global redin_get_state (. dataflow :_get-raw-db))

(local wrap-text "alpha beta gamma delta")

(global main_view
  (fn []
    [:vbox {}
     [:vbox {:id :s :overflow :scroll-y :height 200}
      [:vbox {:id :inner}
       [:text {:id :t1 :margin [10 0 10 0]} "first"]
       [:text {:id :t2} "second"]]
      [:text {:id :after} "after"]]
     [:vbox {:id :s2 :overflow :scroll-y :height 200}
      [:hbox {:id :row}
       [:image {:id :img :width 1240 :height 20}]
       [:text {:id :wrap} wrap-text]]
      [:text {:id :after2} "after"]]
     [:hbox {:height 200}
      [:image {:width 1240 :height 20}]
      [:vbox {}
       [:text {:id :ref} wrap-text]]]]))
