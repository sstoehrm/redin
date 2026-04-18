(require '[redin-test :refer :all]
         '[babashka.process :as bp]
         '[clojure.string :as str])

;; -- Theme plumbing --

(deftest shadow-reaches-host
  (let [theme (get-theme)
        sv    (get-in theme [:shadow-card :shadow])]
    (assert (vector? sv)
            (str "shadow-card should have :shadow, got: " (pr-str sv)))
    (assert (= [6 8 12] (mapv #(int (double %)) (subvec sv 0 3)))
            (str "shadow offsets/blur should round-trip, got: "
                 (pr-str (subvec sv 0 3))))
    (assert (= [0 0 0 200] (get sv 3))
            (str "shadow color should round-trip, got: " (pr-str (get sv 3))))
    (assert (nil? (get-in theme [:plain-card :shadow]))
            "plain-card should not expose shadow")))

(deftest shadow-put-roundtrips
  (set-theme
    {:surface     {:bg [255 255 255] :padding [40 40 40 40]}
     :plain-card  {:bg [60 130 220] :padding [24 24 24 24] :radius 8}
     :shadow-card {:bg [60 130 220] :padding [24 24 24 24] :radius 8
                   :shadow [4 4 2 [10 20 30 255]]}
     :shadow-btn  {:bg [230 90 90] :color [255 255 255] :radius 6
                   :padding [10 18 10 18]
                   :shadow [3 3 6 [0 0 0 180]]}
     :label       {:font-size 16 :color [240 240 240]}})
  (wait-ms 100)
  (let [theme (get-theme)
        sv    (get-in theme [:shadow-card :shadow])]
    (assert (= [4 4 2] (mapv #(int (double %)) (subvec sv 0 3))))
    (assert (= [10 20 30 255] (get sv 3)))))

;; -- Frame structure --

(deftest all-boxes-present
  (assert-element {:tag :vbox :id :plain-box})
  (assert-element {:tag :vbox :id :shadow-box})
  (assert-element {:tag :button :id :shadow-btn}))

;; -- Pixel proof that the shadow actually renders. --
;;
;; Babashka has no image-io, so we shell out to ImageMagick `convert` to
;; sample individual pixels. If `convert` is missing on the runner, the
;; pixel test is skipped rather than failing.

(def ^:private convert-available?
  (try (-> (bp/sh ["convert" "-version"]) :exit zero?) (catch Throwable _ false)))

(defn- pixel-rgb
  "Return [r g b] for the pixel at (x, y) of the PNG at `path`."
  [path x y]
  (let [{:keys [out exit]}
        (bp/sh ["convert" path
                "-crop" (format "1x1+%d+%d" x y)
                "-format" "%[pixel:p{0,0}]"
                "info:"])]
    (when-not (zero? exit)
      (throw (ex-info "convert failed" {:path path :x x :y y})))
    (let [m (re-find #"(?i)srgba?\(([^)]+)\)" (str/trim out))]
      (when-not m (throw (ex-info "unexpected convert output" {:out out})))
      (->> (str/split (second m) #",")
           (take 3)
           (mapv #(Integer/parseInt (str/trim %)))))))

(defn- approx-white? [[r g b]]
  (and (> r 240) (> g 240) (> b 240)))

(deftest shadow-darkens-surface-around-box
  (if-not convert-available?
    (println "  [skip] ImageMagick `convert` not available — pixel test skipped")
    (do
      ;; Restore the original theme for this test (the earlier PUT overwrote it).
      (set-theme
        {:surface     {:bg [255 255 255] :padding [40 40 40 40]}
         :plain-card  {:bg [60 130 220] :padding [24 24 24 24] :radius 8}
         :shadow-card {:bg [60 130 220] :padding [24 24 24 24] :radius 8
                       :shadow [6 8 12 [0 0 0 200]]}
         :shadow-btn  {:bg [230 90 90] :color [255 255 255] :radius 6
                       :padding [10 18 10 18]
                       :shadow [3 3 6 [0 0 0 180]]}
         :label       {:font-size 16 :color [240 240 240]}})
      (wait-ms 200)
      (let [path "/tmp/redin-shadow.png"
            bytes (screenshot path)
            [iw ih] (screenshot-dims bytes)
            [win-w _] (window-size)
            scale (double (/ iw win-w))
            ;; Outer vbox uses :layout :top_center, so each 180-wide child
            ;; is centered horizontally: right edge ≈ win-w/2 + 90. Sample
            ;; 5 logical px past the right edge, where the shadow's offset
            ;; (+6) + blur (12) still reaches but the box does not.
            edge-x (+ (/ win-w 2) 90)
            sx (int (* scale (+ edge-x 5)))
            plain-y  (int (* scale 90))   ;; middle of plain-box
            shadow-y (int (* scale 190))  ;; middle of shadow-box
            plain-px  (pixel-rgb path sx plain-y)
            shadow-px (pixel-rgb path sx shadow-y)]
        (println (str "  [probe] image=" iw "x" ih " scale=" scale
                      " plain=" plain-px " shadow=" shadow-px))
        (assert (approx-white? plain-px)
                (str "pixel next to plain-card should be surface white, got: "
                     (pr-str plain-px)))
        (assert (not (approx-white? shadow-px))
                (str "pixel next to shadow-card should be darkened by shadow, got: "
                     (pr-str shadow-px)))))))
