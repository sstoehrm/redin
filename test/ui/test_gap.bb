(require '[redin-test :refer :all])

;; :gap N on vbox/hbox inserts N px between consecutive children (n-1
;; gaps). Expected rects are documented in gap_app.fnl; everything is
;; aspect-free so no padding shifts the math.

(defn- y-of [id] (:y (rect-of (find-element {:id id}))))
(defn- x-of [id] (:x (rect-of (find-element {:id id}))))

(deftest vbox-gap-separates-children
  (assert-element {:id :v1})
  (assert (= 0.0 (double (y-of :v1))) "v1 at container top")
  (assert (= 30.0 (double (y-of :v2))) "v2 = 20 height + 10 gap")
  (assert (= 60.0 (double (y-of :v3))) "v3 = 2 * (20 + 10)"))

(deftest hbox-gap-separates-children
  (assert (= 0.0 (double (x-of :h1))) "h1 at container left")
  (assert (= 40.0 (double (x-of :h2))) "h2 = 30 width + 10 gap")
  (assert (= 80.0 (double (x-of :h3))) "h3 = 2 * (30 + 10)"))

(deftest gap-counts-toward-centering
  ;; c starts at y 120, height 100; group = 20+10+20 = 50.
  (assert (= 145.0 (double (y-of :c1))) "c1 = 120 + (100-50)/2")
  (assert (= 175.0 (double (y-of :c2))) "c2 = c1 + 20 + 10"))

(deftest nested-vbox-intrinsic-height-includes-gap
  ;; sv has no :height; inside the scroll-y parent its intrinsic height
  ;; must include its own gap: 30 + 10 + 30.
  (assert (= 70.0 (double (:h (rect-of (find-element {:id :sv})))))))

(deftest scroll-total-includes-gaps
  ;; s is the only scrollable node: total = 30 + 70 + 30 + 2*10.
  (let [info (first (vals (scroll-info)))]
    (assert (= 150.0 (double (:total info)))
            (str "scroll total should include gaps, got: " info))))
