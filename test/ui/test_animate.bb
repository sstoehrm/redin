(require '[redin-test :refer :all])

;; Test 1: the button itself renders (sanity — proves the fixture loaded).
(deftest host-button-exists
  (let [host (find-element {:tag :button :attrs {:id "host"}})]
    (assert (some? host) "Host button should appear in the frame tree")))

;; Test 2: the animate provider runs at frame rate. After ~500ms, the
;; provider should have ticked many times. Pre-implementation this
;; counter stays at 0 because the framework doesn't recognize :animate
;; and never dispatches to the provider.
(deftest animate-provider-runs-each-frame
  (dispatch ["ev/host-click"]) ; reset path warm-up
  (wait-ms 500)
  (let [count (get-state "tick-count")]
    (assert (> count 10)
            (str "Expected the animate provider to have ticked > 10 times in 500ms; got "
                 count))))

;; Click-through is structural, not behavioural: the decoration's rect
;; never enters node_rects, so the existing hit-test path can't
;; possibly intercept clicks meant for the host. We verify this in the
;; render code review (search for node_rects in the :animate dispatch
;; path — there should be no append) rather than via a bb test, since
;; redin-test doesn't expose the rendered rect of an element.
