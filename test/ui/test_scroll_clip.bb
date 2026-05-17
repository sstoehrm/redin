(require '[redin-test :refer :all])

;; Regression test for #142. The scroll-y container holds rows that each
;; contain a canvas. Each canvas's execute_canvas_commands runs its own
;; BeginScissor/EndScissor pair — and raylib's scissor isn't a stack, so
;; EndScissor disables clipping entirely. After the first canvas draws,
;; the list's outer scissor is gone and subsequent row pixels render
;; outside the list bounds.
;;
;; The test scrolls one wheel tick (30px under SCROLL_SPEED=30) and
;; samples a pixel inside the sibling-above-the-list region. The
;; sibling is red; the scrolled-up row is green. If clipping works the
;; pixel stays red. If it doesn't (the bug), the row's green pixels
;; have leaked above the list and the pixel reads green.

(defn- list-rect [] (rect-of (find-element {:tag :vbox :aspect :list})))
(defn- sibling-rect [] (rect-of (find-element {:tag :vbox :aspect :sibling})))

(deftest sibling-and-list-laid-out
  (let [s (sibling-rect)
        l (list-rect)]
    (assert (some? s) "sibling rect should be present")
    (assert (some? l) "list rect should be present")
    (assert (= (:y l) (+ (:y s) (:h s)))
            (str "list should sit directly below sibling; got sibling="
                 s " list=" l))))

(deftest scrolled-row-does-not-overflow-into-sibling
  (let [s (sibling-rect)
        l (list-rect)
        ;; Sample 8px inside the sibling, well above the list boundary.
        sx (int (+ (:x s) (/ (:w s) 2)))
        sy (int (+ (:y s) (/ (:h s) 2)))]
    ;; Baseline: with no scroll, the sample point is unambiguously red.
    (let [[r g b] (screenshot-pixel (screenshot) sx sy)]
      (assert (= [r g b] [220 0 0])
              (str "baseline (no scroll) sibling pixel should be red; got "
                   [r g b])))

    ;; Drive one wheel tick down. SCROLL_SPEED=30 → first row's logical
    ;; y becomes (list.y - 30). The row's canvas would render at that
    ;; y absent scissor clipping.
    (input-scroll (int (+ (:x l) (/ (:w l) 2)))
                  (int (+ (:y l) (/ (:h l) 2)))
                  -1)
    (wait-ms 100)

    (let [[r g b] (screenshot-pixel (screenshot) sx sy)]
      (assert (= [r g b] [220 0 0])
              (str "after scrolling, sibling pixel should still be red "
                   "(scissor must clip the scrolled-up row); got "
                   [r g b])))))
