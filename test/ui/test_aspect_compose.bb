(require '[redin-test :refer :all])

;; Review C13: `:aspect [:a :b]` used to read as "" (completely
;; unthemed). Pixel-check the composed results.

(defn- compose-rect [id]
  (rect-of (find-element {:id id})))

(defn- inside [{:keys [x y h]}]
  ;; A point inside the rect near its left edge: the dev build's profile
  ;; overlay (REDIN_PROFILE, 180x110 at the top-right) covers the middle
  ;; of a 300px-wide window.
  [(int (+ x 20)) (int (+ y (/ h 2)))])

(deftest composed-rects-exist
  (resize! 300 200)
  (wait-ms 200)
  (doseq [id [:rule :later-wins :missing-part :composed-btn]]
    (assert (some? (compose-rect id)) (str id " should have a rect"))))

(deftest composed-aspects-draw
  (let [png (screenshot)
        [rule later missing btn]
        (screenshot-pixels png (mapv (comp inside compose-rect)
                                     [:rule :later-wins :missing-part :composed-btn]))]
    (assert (= rule [220 0 0]) (str "[:red :hr-rule] should draw red, got " rule))
    (assert (= later [0 0 200]) (str "[:base :tint] later wins -> tint, got " later))
    (assert (= missing [220 0 0]) (str "[:nope :red] missing part is {} -> red, got " missing))
    (assert (= btn [190 30 30]) (str "[:btn :danger] at rest -> danger bg, got " btn))))

(deftest composed-hover-variant-applies
  ;; btn < danger < btn#hover < danger#hover: btn#hover's bg beats
  ;; danger's base bg; danger#hover sets no bg.
  (input-takeover)
  (try
    (let [r (compose-rect :composed-btn)
          [cx cy] (inside r)]
      (input-mouse-move cx cy)
      (wait-ms 150)
      (let [[px] (screenshot-pixels (screenshot) [[(+ (:x r) 4) (+ (:y r) 4)]])]
        (assert (= px [30 150 30]) (str "hovered composed button -> btn#hover bg, got " px))))
    (finally
      (input-mouse-move 299 199)
      (input-release))))

(deftest aspects-endpoint-hides-synthetic-keys
  (let [theme (get-theme)]
    (assert (contains? theme :red) "app aspects are still reported")
    (assert (not-any? #(re-find #" " (name %)) (keys theme))
            (str "synthetic composed keys must not leak into /aspects: " (keys theme)))))

(deftest theme-swap-recomposes-without-rerender
  ;; PUT /aspects replaces the host theme; composed entries must be
  ;; rebuilt from the new components (the view itself is unchanged).
  (set-theme {:surface {:bg [255 255 255]}
              :red     {:bg [10 20 30]}
              :hr-rule {:bg [40 50 60]}})
  (wait-ms 300)
  (let [[rule] (screenshot-pixels (screenshot) [(inside (compose-rect :rule))])]
    (assert (= rule [40 50 60]) (str "[:red :hr-rule] after theme swap -> hr-rule bg, got " rule))))
