(require '[redin-test :refer :all])

;; :margin [t r b l] on leaf nodes reserves space around the element in
;; its parent's layout; the element's own rect (hit-test rect) excludes
;; the margin. Expected rects are documented in margin_app.fnl.

(defn- rect [id] (rect-of (find-element {:id id})))

(deftest vbox-child-margin-offsets-and-shrinks
  (let [{:keys [x y w h]} (rect :b2)]
    (assert (= 30.0 (double y)) (str "b2 y: 20 + top margin 10, got " y))
    (assert (= 40.0 (double x)) (str "b2 x: left margin 40, got " x))
    (assert (= 1220.0 (double w)) (str "b2 w: 1280 - 40 - 20, got " w))
    (assert (= 20.0 (double h)) "b2 keeps its explicit height"))
  (assert (= 80.0 (double (:y (rect :b3)))) "b3: 30 + 20 + bottom margin 30"))

(deftest hbox-child-margin-offsets-main-axis
  (let [{:keys [x y w h]} (rect :i2)]
    (assert (= 55.0 (double x)) "i2 x: 30 + left margin 25")
    (assert (= 105.0 (double y)) "i2 y: 100 + top margin 5")
    (assert (= 30.0 (double w)) "i2 keeps its explicit width")
    ;; hbox children stretch to the container's cross-axis height (50)
    ;; under the default anchor; margins inset that stretched rect.
    (assert (= 40.0 (double h)) "i2 h: 50 - top 5 - bottom 5"))
  (assert (= 100.0 (double (:x (rect :i3)))) "i3: 55 + 30 + right margin 15"))

(deftest cross-axis-centering-uses-outer-width
  (let [{:keys [x w]} (rect :in1)]
    (assert (= 600.0 (double x)) "outer 140 centered at 570, + left margin 30")
    (assert (= 100.0 (double w)) "in1 keeps its explicit width")))

(deftest scroll-intrinsic-includes-margin
  (assert (= 250.0 (double (:y (rect :st)))) "st: 210 + 30 + top margin 10")
  (assert (= 295.0 (double (:y (rect :s2)))) "s2: st bottom + bottom margin 20")
  (let [info (first (vals (scroll-info)))]
    (assert (= 115.0 (double (:total info)))
            (str "scroll total 30 + (10+25+20) + 30, got: " info))))

(deftest stack-child-margin-insets-overlay
  (let [{:keys [x y w h]} (rect :cv)]
    (assert (= 10.0 (double x)))
    (assert (= 260.0 (double y)) "stack starts at 250, + top margin 10")
    (assert (= 1260.0 (double w)))
    (assert (= 530.0 (double h)) "stack fill height 550 - 10 - 10")))
