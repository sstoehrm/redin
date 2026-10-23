(require '[redin-test :refer :all])

;; Review C4: focused_idx and the scroll-offset maps are DFS indices.
;; Hiding the banner shifts every later index by one; before the fix the
;; focused index then named input B (End + Backspace edited :b while the
;; user was typing in A) and pane 1's scroll offset was left behind on
;; the index pane 1 no longer had.

(defn- reset-app! []
  (dispatch ["ev/reset"])
  (wait-for (state= "show" true) {:timeout 2000})
  (wait-for (element-exists? {:tag :text :id :banner}) {:timeout 2000}))

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

(defn- pane-offsets
  "Scroll offsets of the scrollable panes in DFS order (pane 1, pane 2)."
  []
  (->> (scroll-info)
       (map (fn [[k v]] [(Long/parseLong (name k)) (:off v)]))
       (sort-by first)
       (mapv second)))

(deftest focus-follows-input-when-earlier-sibling-removed
  (reset-app!)
  (click-center! (find-element {:tag :input :id :ia}))
  (dispatch ["ev/hide"])
  (wait-for (no-element? {:tag :text :id :banner}) {:timeout 2000})
  (wait-ms 100)
  (input-key :end)
  (wait-ms 80)
  (input-key :backspace)
  (wait-for (state= "a" "alph") {:timeout 2000})
  (assert (= "bravo" (get-state "b"))
          (str "input B must be untouched; got " (pr-str (get-state "b")))))

(deftest focus-dropped-when-focused-input-removed
  (reset-app!)
  (click-center! (find-element {:tag :input :id :ia}))
  (dispatch ["ev/drop-a"])
  (wait-for (no-element? {:tag :input :id :ia}) {:timeout 2000})
  (wait-ms 100)
  (input-key :end)
  (wait-ms 80)
  (input-key :backspace)
  (wait-ms 300)
  (assert (= "bravo" (get-state "b"))
          (str "keys after the focused input vanished must not edit input B; got "
               (pr-str (get-state "b")))))

(deftest scroll-offset-follows-pane-when-earlier-sibling-removed
  (reset-app!)
  (let [{:keys [x y w h]} (rect-of (find-element {:id :pane1}))]
    (input-scroll (int (+ x (/ w 2))) (int (+ y (/ h 2))) -3))
  (wait-for {:desc "pane 1 scrolled"
             :check-fn #(pos? (first (pane-offsets)))}
            {:timeout 2000})
  (let [[p1 p2] (pane-offsets)]
    (assert (zero? p2) (str "setup: pane 2 should be unscrolled; got " p2))
    (dispatch ["ev/hide"])
    (wait-for (no-element? {:tag :text :id :banner}) {:timeout 2000})
    (wait-ms 150)
    (let [[q1 q2] (pane-offsets)]
      (assert (== p1 q1) (str "pane 1 must keep its offset " p1 "; got " q1))
      (assert (zero? q2) (str "pane 2 must not inherit an offset; got " q2)))))
