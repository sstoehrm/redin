;; Test app for :gap on vbox/hbox. No aspects anywhere so no padding
;; enters the math — every rect below is exact.
;;
;;   v  (gap 10): three h=20 children stacked at y 0 / 30 / 60
;;   h  (gap 10): three w=30 children at x 0 / 40 / 80
;;   c  (gap 10, :layout :center, h 100): group = 20+10+20 = 50
;;   s  (gap 10, scroll-y, h 50): sv is an unsized vbox with its own
;;      gap 10 → intrinsic 30+10+30 = 70; total = 30+70+30+2*10 = 150
(local dataflow (require :dataflow))

(dataflow.init {})
(global redin_get_state (. dataflow :_get-raw-db))

(global main_view
  (fn []
    [:vbox {}
     [:vbox {:id :v :gap 10 :height 90}
      [:button {:id :v1 :height 20} "a"]
      [:button {:id :v2 :height 20} "b"]
      [:button {:id :v3 :height 20} "c"]]
     [:hbox {:id :h :gap 10 :height 30}
      [:button {:id :h1 :width 30 :height 20} "d"]
      [:button {:id :h2 :width 30 :height 20} "e"]
      [:button {:id :h3 :width 30 :height 20} "f"]]
     [:vbox {:id :c :layout :center :gap 10 :height 100}
      [:button {:id :c1 :height 20} "g"]
      [:button {:id :c2 :height 20} "h"]]
     [:vbox {:id :s :overflow :scroll-y :gap 10 :height 50}
      [:button {:id :s1 :height 30} "i"]
      [:vbox {:id :sv :gap 10}
       [:button {:id :sv1 :height 30} "j"]
       [:button {:id :sv2 :height 30} "k"]]
      [:button {:id :s3 :height 30} "l"]]]))
