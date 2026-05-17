(require '[redin-test :refer :all])

;; Tests for #143: draggable scrollbar.
;;
;; Geometry (see scrollbar_drag_app.fnl):
;;   gutter:     y=50..250 (200px tall, list height)
;;   bar width:  4px visible, hit-zone +4 each side (effective 12px)
;;   total:      900px content
;;   max_scroll: 900 - 200 = 700
;;   thumb_h:    200 * (200/900) ≈ 44.4 → 45 after clamp/round
;;
;; The window is 1280 wide; the scroll-y bar sits at x = 1280-4 = 1276.

(defn- list-idx
  "Find the scrollable list's node idx from /scroll-info — it's the
   only key in the map at boot."
  []
  (let [info (scroll-info)
        ks   (keys info)]
    (when (= 1 (count ks))
      (Long/parseLong (name (first ks))))))

(defn- list-info [] (let [info (scroll-info)] (first (vals info))))

(defn- offset [] (:off (list-info)))

(defn- thumb-rect
  "Compute the bar's expected y-range from /scroll-info. Pure derivation
   from total/off and the known container dims."
  []
  (let [{:keys [total off]} (list-info)
        gutter-y0 50
        gutter-h  200
        ratio     (/ gutter-h total)
        thumb-h   (max 20 (* gutter-h ratio))
        max-scr   (- total gutter-h)
        thumb-y   (+ gutter-y0
                     (if (pos? max-scr)
                       (* (/ off max-scr) (- gutter-h thumb-h))
                       0))]
    {:y0 thumb-y :y1 (+ thumb-y thumb-h) :h thumb-h}))

(deftest scroll-info-reports-list
  (assert (some? (list-idx)) "scrollable list should appear in /scroll-info")
  (let [{:keys [total off]} (list-info)]
    (assert (== 0 off) (str "fresh app: scroll offset should be 0; got " off))
    (assert (== 900 total) (str "expected total=900; got " total))))

(deftest cursor-on-thumb-is-resize-ns
  ;; Hover the cursor over the thumb (cursor center at y=72ish — gutter
  ;; top + half-thumb). Cursor should swap to resize-ns.
  (input-takeover)
  (try
    (let [{:keys [y0 y1]} (thumb-rect)
          ty (int (+ y0 (/ (- y1 y0) 2)))]
      (input-mouse-move 1278 ty)
      (wait-ms 100)
      (let [k (cursor-kind)]
        (assert (= k :resize-ns)
                (str "cursor over thumb should be :resize-ns; got " k))))
    (finally
      (input-release))))

(deftest drag-thumb-changes-scroll
  (input-takeover)
  (try
    (let [{:keys [y0 y1]} (thumb-rect)
          ty (int (+ y0 (/ (- y1 y0) 2)))]
      (input-mouse-move 1278 ty)
      (wait-ms 100)
      (input-mouse-down :left)
      (wait-ms 100)
      ;; Drag the thumb 50px down. Expected delta in scroll_offset:
      ;;   50 / (gutter_h - thumb_h) * max_scroll
      ;;   = 50 / (200 - 44.44) * 700 ≈ 225
      (input-mouse-move 1278 (+ ty 50))
      (wait-ms 100)
      (let [off (offset)]
        (assert (and (> off 200) (< off 250))
                (str "after 50px drag, offset should be ~225; got " off)))
      (input-mouse-up :left))
    (finally
      (input-release))))

(deftest click-below-thumb-pages-down
  ;; Reset scroll offset to 0 (positive delta-y scrolls content up/back).
  (input-scroll 640 150 100)
  (wait-ms 100)
  (input-takeover)
  (try
    (let [{:keys [y1]} (thumb-rect)
          ;; 10px below the thumb's bottom edge — inside the gutter,
          ;; outside the thumb.
          cy (int (+ y1 10))]
      (input-mouse-move 1278 cy)
      (wait-ms 100)
      (input-mouse-down :left)
      (wait-ms 100)
      (input-mouse-up :left)
      (wait-ms 100)
      ;; Page-down adds one container-height (200px) to offset, clamped
      ;; to max_scroll=700.
      (let [off (offset)]
        (assert (and (>= off 190) (<= off 210))
                (str "page-down should advance by ~200; got " off))))
    (finally
      (input-release))))

(deftest click-above-thumb-pages-up
  (input-takeover)
  (try
    ;; Set up: scroll to the middle first via /input/scroll.
    (input-scroll 640 150 -10)
    (wait-ms 100)
    (let [start-off (offset)
          {:keys [y0]} (thumb-rect)
          ;; 10px above the thumb's top edge — inside the gutter,
          ;; outside the thumb.
          cy (int (- y0 10))]
      (assert (> start-off 100) (str "setup: offset should be >100; got " start-off))
      (input-mouse-move 1278 cy)
      (wait-ms 100)
      (input-mouse-down :left)
      (wait-ms 100)
      (input-mouse-up :left)
      (wait-ms 100)
      (let [off (offset)]
        (assert (= off (max 0 (- start-off 200)))
                (str "page-up should retreat by 200; got " off))))
    (finally
      (input-release))))

(deftest drag-survives-cursor-off-gutter
  ;; Reset to zero offset first so the assertion is unambiguous.
  (input-scroll 640 150 100)
  (wait-ms 100)
  (input-takeover)
  (try
    (let [{:keys [y0 y1]} (thumb-rect)
          ty (int (+ y0 (/ (- y1 y0) 2)))]
      (input-mouse-move 1278 ty)
      (wait-ms 100)
      (input-mouse-down :left)
      (wait-ms 100)
      ;; Drag down 30px, then move cursor far left (off the gutter).
      ;; The drag should keep tracking the cursor's y, ignoring x.
      (input-mouse-move 1278 (+ ty 30))
      (wait-ms 50)
      (input-mouse-move 100 (+ ty 60))
      (wait-ms 100)
      (let [off (offset)]
        (assert (> off 200)
                (str "drag should continue when cursor leaves gutter horizontally; got "
                     off)))
      (input-mouse-up :left))
    (finally
      (input-release))))
