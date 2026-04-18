(require '[redin-test :refer :all])

;; -- Theme plumbing --

(deftest line-height-reaches-host
  (let [theme (get-theme)]
    (assert (= 1.0 (double (get-in theme [:tight :line-height])))
            (str "tight aspect should expose line-height=1.0, got: "
                 (pr-str (get-in theme [:tight :line-height]))))
    (assert (< (Math/abs (- 2.2 (double (get-in theme [:loose :line-height])))) 1e-3)
            (str "loose aspect should expose line-height=2.2, got: "
                 (pr-str (get-in theme [:loose :line-height]))))
    (assert (nil? (get-in theme [:default-lh :line-height]))
            "aspects without line-height should not expose it")))

(deftest line-height-put-roundtrips
  (set-theme {:surface {:bg [20 20 28] :padding [16 16 16 16]}
              :body    {:font-size 16 :color [236 239 244]}
              :tight   {:font-size 16 :color [236 239 244] :line-height 1.25}
              :loose   {:font-size 16 :color [236 239 244] :line-height 3.0}})
  (wait-ms 100)
  (let [theme (get-theme)]
    (assert (= 1.25 (double (get-in theme [:tight :line-height]))))
    (assert (= 3.0  (double (get-in theme [:loose :line-height]))))))

;; -- Frame structure --

(deftest both-fixed-cells-present
  (assert-element {:tag :text :id :fixed-tight})
  (assert-element {:tag :text :id :fixed-loose}))

(deftest all-growing-cells-present
  (assert-element {:tag :text :id :grow-tight})
  (assert-element {:tag :text :id :grow-loose})
  (assert-element {:tag :text :id :grow-default}))

;; -- Visual proof: screenshot the app so failures can be diffed. --

(deftest screenshot-captures
  (let [bytes (screenshot "/tmp/redin-line-height.png")
        [w h] (screenshot-dims bytes)]
    (assert (pos? w) "screenshot should have nonzero width")
    (assert (pos? h) "screenshot should have nonzero height")))
