(require '[redin-test :refer :all])

;; Review C11: clicking an input inside a :modal must focus it even when
;; tall selectable page text lies behind the modal. The text-selection
;; hit test used to accept any selectable text under the pointer, start a
;; selection on the page text, and force focused_idx = -1 — so typing and
;; Backspace went nowhere.

(defn- click-center! [el]
  (let [{:keys [x y w h]} (rect-of el)]
    (input-takeover)
    (try
      (input-mouse-move (int (+ x (/ w 2))) (int (+ y (/ h 2))))
      (wait-ms 80)
      (input-mouse-down :left)
      (wait-ms 80)
      (input-mouse-up :left)
      (wait-ms 80)
      (finally
        (input-release)))))

(deftest page-text-covers-modal-input
  ;; Sanity: the precondition of the bug — the page text's rect contains
  ;; the modal input's centre.
  (let [page (rect-of (find-element {:tag :text :id :page}))
        inp  (rect-of (find-element {:tag :input :id :modal-input}))
        cx   (+ (:x inp) (/ (:w inp) 2))
        cy   (+ (:y inp) (/ (:h inp) 2))]
    (assert (and (<= (:x page) cx (+ (:x page) (:w page)))
                 (<= (:y page) cy (+ (:y page) (:h page))))
            (str "page text " page " should cover input centre " [cx cy]))))

(deftest click-input-in-modal-over-text-keeps-focus
  (dispatch ["event/reset"])
  (wait-for (state= "v" "hello") {:timeout 2000})
  (click-center! (find-element {:tag :input :id :modal-input}))
  (input-key :end)
  (wait-ms 80)
  (input-key :backspace)
  (wait-for (state= "v" "hell") {:timeout 2000})
  (let [sel (get-selection)]
    (assert (not= "text" (:kind sel))
            (str "click on the modal input must not start a page-text selection; got " sel))))
