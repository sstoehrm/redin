;; Test app for :margin on leaf nodes (text/image/input/button/canvas).
;; No aspects anywhere so no padding enters the math — every rect below
;; is exact at the 1280x800 test window. Margin format is [t r b l],
;; matching theme padding.
;;
;;   v  (y 0):   b2 margin [10 20 30 40] → y 30, x 40, w 1220; b3 y 80
;;   h  (y 100): i2 margin [5 15 5 25]   → x 55, y 105; i3 x 100
;;   cx (y 150, cross-center): in1 w=100, margin [0 10 0 30] → outer 140,
;;        outer x (1280-140)/2 = 570 → inner x 600
;;   s  (y 210, scroll-y): st h=25, margin [10 0 20 0] → outer 55,
;;        st y 250, s2 y 295, scroll total 30+55+30 = 115
;;   k  (stack, fill → y 250 h 550): cv margin [10 10 10 10]
;;        → x 10, y 260, w 1260, h 530
(local dataflow (require :dataflow))

(dataflow.init {})
(global redin_get_state (. dataflow :_get-raw-db))

(global main_view
  (fn []
    [:vbox {}
     [:vbox {:id :v :height 100}
      [:button {:id :b1 :height 20} "a"]
      [:button {:id :b2 :height 20 :margin [10 20 30 40]} "b"]
      [:button {:id :b3 :height 20} "c"]]
     [:hbox {:id :h :height 50}
      [:image {:id :i1 :width 30 :height 20}]
      [:image {:id :i2 :width 30 :height 20 :margin [5 15 5 25]}]
      [:image {:id :i3 :width 30 :height 20}]]
     [:vbox {:id :cx :layout :top_center :height 60}
      [:input {:id :in1 :width 100 :height 30 :margin [0 10 0 30]}]]
     [:vbox {:id :s :overflow :scroll-y :height 40}
      [:button {:id :s1 :height 30} "d"]
      [:text {:id :st :height 25 :margin [10 0 20 0]} "t"]
      [:button {:id :s2 :height 30} "e"]]
     [:stack {:id :k}
      [:canvas {:id :cv :margin [10 10 10 10]}]]]))
