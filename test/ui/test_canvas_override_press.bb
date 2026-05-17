(require '[redin-test :refer :all])

;; Regression test for #139. Before the fix, pressing a button via the
;; takeover input path while the app contains a canvas silently drops
;; the press: the canvas's push_canvas_input_state polls
;; is_mouse_button_pressed during render_tick, which consumes the
;; override's one-shot pending_press_left flag before apply_listeners
;; sees the MouseEvent.

(defn- btn-rect []
  (rect-of (find-element {:tag :button :aspect :btn})))

(defn- center-of []
  (let [{:keys [x y w h]} (btn-rect)]
    [(int (+ x (/ w 2))) (int (+ y (/ h 2)))]))

(deftest takeover-press-fires-click-with-canvas
  (let [[cx cy] (center-of)
        before  (get-state "clicks")]
    (assert (= 0 before)
            (str "Pre-condition: clicks should start at 0; got " before))
    (input-takeover)
    (try
      (input-mouse-move cx cy)
      (wait-ms 100)
      (input-mouse-down :left)
      (wait-ms 100)
      (input-mouse-up :left)
      (wait-for (state= "clicks" 1) {:timeout 2000})
      (finally
        (input-release)))))
