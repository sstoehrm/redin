(require '[redin-test :refer :all])

;; Padded-scrollbar regression: on a container with padding the drawn
;; thumb (inside the content rect) and the clickable thumb must coincide.
;; Geometry (see scrollbar_padded_app.fnl):
;;   content gutter: y=70..270 (200px), bar at x=1256..1260
;;   total 900, max_scroll 700, thumb_h ≈ 44.4 → at off=0 thumb y=70..114
;; All interactions below target the DRAWN bar position; before the fix
;; the hit zone sat at the outer rect's right edge (x≈1272..1284,
;; y=50..290), so none of these presses registered.

(defn- list-info [] (first (vals (scroll-info))))
(defn- offset [] (:off (list-info)))

(defn- thumb-rect
  "Expected drawn-thumb y-range derived from /scroll-info and the
   fixture's content-rect geometry."
  []
  (let [{:keys [total off]} (list-info)
        gutter-y0 70
        gutter-h  200
        thumb-h   (max 20 (* gutter-h (/ gutter-h total)))
        max-scr   (- total gutter-h)
        thumb-y   (+ gutter-y0
                     (if (pos? max-scr)
                       (* (/ off max-scr) (- gutter-h thumb-h))
                       0))]
    {:y0 thumb-y :y1 (+ thumb-y thumb-h)}))

(deftest scroll-info-reports-padded-list
  (let [{:keys [total off]} (list-info)]
    (assert (== 0 off) (str "fresh app: scroll offset should be 0; got " off))
    (assert (== 900 total) (str "expected total=900; got " total))))

(deftest cursor-on-drawn-thumb-is-resize-ns
  (input-takeover)
  (try
    (let [{:keys [y0 y1]} (thumb-rect)
          ty (int (+ y0 (/ (- y1 y0) 2)))]
      (input-mouse-move 1258 ty)
      (wait-ms 100)
      (let [k (cursor-kind)]
        (assert (= k :resize-ns)
                (str "cursor over the drawn thumb should be :resize-ns; got " k))))
    (finally
      (input-release))))

(deftest drag-drawn-thumb-changes-scroll
  (input-takeover)
  (try
    (let [{:keys [y0 y1]} (thumb-rect)
          ty (int (+ y0 (/ (- y1 y0) 2)))]
      (input-mouse-move 1258 ty)
      (wait-ms 100)
      (input-mouse-down :left)
      (wait-ms 100)
      ;; 50px drag → 50 / (200 - 44.4) * 700 ≈ 225.
      (input-mouse-move 1258 (+ ty 50))
      (wait-ms 100)
      (let [off (offset)]
        (assert (and (> off 200) (< off 250))
                (str "after 50px drag on the drawn thumb, offset should be ~225; got "
                     off)))
      (input-mouse-up :left))
    (finally
      (input-release))))

(deftest click-below-drawn-thumb-pages-down
  ;; Reset scroll offset to 0 first.
  (input-scroll 640 150 100)
  (wait-ms 100)
  (input-takeover)
  (try
    (let [{:keys [y1]} (thumb-rect)
          cy (int (+ y1 10))]
      (input-mouse-move 1258 cy)
      (wait-ms 100)
      (input-mouse-down :left)
      (wait-ms 100)
      (input-mouse-up :left)
      (wait-ms 100)
      ;; Page-down advances by one content-height (200px).
      (let [off (offset)]
        (assert (and (>= off 190) (<= off 210))
                (str "page-down should advance by ~200 (content height); got "
                     off))))
    (finally
      (input-release))))
