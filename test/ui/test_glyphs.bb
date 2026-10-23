(require '[redin-test :refer :all])

;; Glyph coverage of loaded fonts (review C3). See glyphs_app.fnl: every
;; cell is an 80x80 text node; two cells with the same aspect render
;; the same pixels exactly when they draw the same glyph, and raylib
;; draws '?' for any codepoint missing from the atlas.

(defn- glyph-rect [id]
  (rect-of (find-element {:id id})))

(defn- glyph-cell-coords
  "Sample grid (every 2px) inside the cell, relative to its rect origin."
  [{:keys [x y w h]}]
  (for [dy (range 1 (int h) 2) dx (range 1 (int w) 2)]
    [(+ (int x) dx) (+ (int y) dy)]))

(defn- glyph-cells
  "Return {id [[r g b] ...]} for the given cell ids from ONE screenshot."
  [ids]
  (let [rects  (into {} (map (fn [id] [id (glyph-rect id)]) ids))
        coords (mapv #(vec (glyph-cell-coords (rects %))) ids)
        pixels (screenshot-pixels (screenshot) (vec (apply concat coords)))]
    (loop [ids ids coords coords pixels pixels out {}]
      (if (empty? ids)
        out
        (let [n (count (first coords))]
          (recur (rest ids) (rest coords) (drop n pixels)
                 (assoc out (first ids) (vec (take n pixels)))))))))

(defn- ink-count
  "Dark (text-coloured) pixels in the cell: black text on the light
   default background."
  [cell]
  (count (filter (fn [[r g b]] (< (+ r g b) 300)) cell)))

;; Strong pixel differences between two cells (any channel off by > 64).
;; Comparing with a threshold instead of bit-exact equality keeps the
;; test robust to sub-LSB rasteriser rounding that can differ by screen x
;; (llvmpipe vs a real GPU); a different glyph differs by far more
;; (77-125 of the 1600 samples under xvfb/llvmpipe; '?' vs Ω: 0).
(defn- glyph-diff-count [a b]
  (count (filter (fn [[p q]] (some (fn [[x y]] (> (Math/abs (- x y)) 64)) (map vector p q)))
                 (map vector a b))))

(defn- same-glyph? [a b] (<= (glyph-diff-count a b) 4))
(defn- different-glyph? [a b] (>= (glyph-diff-count a b) 30))

;; No resize!: the dev build's profile overlay sits in the top-right
;; corner, so the cells stay at the left of the default-width window.
;; screenshot-pixels only decodes rows up to the largest sampled y (the
;; 80px cell row), which keeps the decode cheap regardless of width.

(deftest glyph-cells-are-laid-out
  (doseq [id [:q :u :euro :dash :omega :fq :fu :fomega]]
    (let [r (glyph-rect id)]
      (assert (and r (= 80.0 (double (:w r))) (= 80.0 (double (:h r))))
              (str id " should be an 80x80 cell, got " r)))))

(deftest question-mark-renders-something
  (let [{:keys [q]} (glyph-cells [:q])]
    (assert (pos? (ink-count q)) "the '?' cell has inked pixels (sanity)")))

(deftest unsupported-codepoint-falls-back-to-question-mark
  ;; Control: U+03A9 is outside the loaded range, so it must render as
  ;; '?'. This proves the pixel comparison detects the fallback.
  (let [{:keys [q omega]} (glyph-cells [:q :omega])]
    (assert (same-glyph? q omega)
            (str "Ω (outside the glyph set) renders as '?'; strong diffs: "
                 (glyph-diff-count q omega)))))

(deftest latin1-and-symbols-render-their-own-glyphs
  (let [{:keys [q u euro dash]} (glyph-cells [:q :u :euro :dash])]
    (assert (different-glyph? q u) "ü must not render as the '?' fallback")
    (assert (different-glyph? q euro) "€ must not render as the '?' fallback")
    (assert (different-glyph? q dash) "— must not render as the '?' fallback")
    (assert (pos? (ink-count u)) "ü draws visible pixels")))

(deftest font-face-fonts-load-the-same-glyph-set
  (let [{:keys [fq fu fomega]} (glyph-cells [:fq :fu :fomega])]
    (assert (pos? (ink-count fq)) "font-face '?' cell has inked pixels")
    (assert (same-glyph? fq fomega)
            (str "control: Ω renders as '?' in the font-face font too; strong diffs: "
                 (glyph-diff-count fq fomega)))
    (assert (different-glyph? fq fu) "ü in a :font-face font must not render as '?'")))
