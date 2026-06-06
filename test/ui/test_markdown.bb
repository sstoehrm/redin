(require '[redin-test :refer :all]
         '[clojure.java.io :as io])

(defn- ensure-artifacts-dir []
  (let [d (io/file "test/ui/artifacts")]
    (when-not (.exists d) (.mkdirs d))))

(deftest markdown-element-exists
  (let [n (find-element {:id :md})]
    (assert n "markdown element must exist at :id :md")
    (assert (= "markdown" (first n))
            (str "expected tag :markdown; got " (pr-str (first n))))))

(deftest markdown-attrs-pass-through
  (let [n (find-element {:id :md})
        attrs (second n)]
    (let [asp (:aspect attrs)]
      (assert (or (= "card" asp) (= :card asp))
              (str "expected :aspect :card on the markdown wrapper; got " (pr-str asp))))))

(deftest markdown-source-preserved
  (let [n (find-element {:id :md})
        ;; Source string is at position 3 of the table.
        source (when (> (count n) 2) (nth n 2))]
    (assert (string? source)
            (str "expected the markdown source as the third element; got " (pr-str source)))
    (assert (re-find #"# Title" source)
            "expected source to start with the heading we wrote")))

(deftest markdown-renders-without-error
  (ensure-artifacts-dir)
  (wait-ms 100)
  (screenshot "test/ui/artifacts/markdown_render.png"))

(deftest sibling-after-markdown-has-correct-rect
  ;; Regression: the bridge emits N flat-array entries for one
  ;; [:markdown] element, but the /frames walker (which sees the
  ;; original Fennel tree) only advances dfs_idx by 1. Without a
  ;; skip-count side-channel, every sibling after a [:markdown]
  ;; receives an inside-the-markdown rect.
  (let [md (find-element {:id :md})
        sn (find-element {:id :sentinel})
        mr (rect-of md)
        sr (rect-of sn)]
    (assert sr (str "sentinel must have a rect; got " (pr-str (frame-attrs sn))))
    (assert mr (str "markdown wrapper must have a rect; got " (pr-str (frame-attrs md))))
    (let [md-bottom (+ (:y mr) (:h mr))]
      (assert (>= (:y sr) md-bottom)
              (str "sentinel y (" (:y sr) ") must be at or below markdown bottom ("
                   md-bottom "); rects are desynced. md=" (pr-str mr)
                   " sentinel=" (pr-str sr))))
    ;; The explicit :height 40 must show up — without the fix the
    ;; sentinel inherits a rect from inside the lowered subtree
    ;; (typically a paragraph, ~27px line height).
    (assert (= 40.0 (double (:h sr)))
            (str "sentinel height should be 40 (its explicit height), got "
                 (:h sr) "; rect=" (pr-str sr)))))

;; #112: the copyable block renders a COMPACT, RIGHT-ALIGNED Copy button
;; (theme bg [60 60 70]) above its content. /frames exposes only the
;; pre-lowering tree, so the lowered NodeButton never appears as a frame
;; node; we verify geometry via screenshot pixels instead.
;;
;; Probe layout (calibrated against actual render):
;;   row-y   = block-top + 18  → top edge of the button, above any text glyphs
;;   right-x = block-right - 30 → solidly inside the ~72px right-aligned button
;;   left-x  = block-x + 40    → left side of the bar row, never covered by the button
;;
;; At row-y the button bg [60 60 70] is unobstructed by anti-aliased text,
;; giving a clean pixel match. The card background [40 44 52] fills left-x.
(def copy-button-bg [60 60 70])

(deftest copyable-block-renders-copy-button
  (let [md (find-element {:id :md-copy})
        r  (rect-of md)]
    (assert r (str "md-copy wrapper must have a rect; got " (pr-str (frame-attrs md))))
    (let [png     (screenshot)
          row-y   (int (+ (:y r) 18))              ;; top of button, above text glyphs
          right-x (int (- (+ (:x r) (:w r)) 30))  ;; solidly inside the right-aligned button
          left-x  (int (+ (:x r) 40))             ;; left of bar row, never covered by button
          right-px (vec (screenshot-pixel png right-x row-y))
          left-px  (vec (screenshot-pixel png left-x  row-y))]
      (assert (= copy-button-bg right-px)
              (str "expected compact Copy button (bg " copy-button-bg ") near the right edge at ("
                   right-x "," row-y "); got " right-px ". rect=" (pr-str r)))
      ;; Compactness: the button must NOT span the full width, so the left
      ;; side of the same row must not be the button colour.
      (assert (not= copy-button-bg left-px)
              (str "Copy button must be compact (not full-width): left of the row at ("
                   left-x "," row-y ") should not be button bg; got " left-px)))))

(deftest non-copyable-block-has-no-copy-button
  ;; The :id :md block is NOT copyable: probing the same right-edge row that
  ;; holds the button in the copyable block must not show the button colour.
  (let [md (find-element {:id :md})
        r  (rect-of md)]
    (assert r (str "md wrapper must have a rect; got " (pr-str (frame-attrs md))))
    (let [png     (screenshot)
          row-y   (int (+ (:y r) 18))
          right-x (int (- (+ (:x r) (:w r)) 30))
          px      (vec (screenshot-pixel png right-x row-y))]
      (assert (not= copy-button-bg px)
              (str "non-copyable block must NOT render the Copy button bg " copy-button-bg
                   " at (" right-x "," row-y "); got " px ". rect=" (pr-str r))))))

(deftest clicking-markdown-text-does-not-select
  ;; Lowered markdown text is non-selectable: clicking inside the rendered
  ;; body must leave /selection at {kind:none}, not start a text selection.
  (let [md (find-element {:id :md})
        r  (rect-of md)]
    (assert r (str "markdown wrapper must have a rect; got " (pr-str (frame-attrs md))))
    ;; Click low in the block (body area) to land on paragraph text.
    (click (int (+ (:x r) 20)) (int (+ (:y r) (* 0.7 (:h r)))))
    (wait-ms 120)
    (let [s (get-selection)]
      (assert (= "none" (:kind s))
              (str "markdown text must not be selectable; got selection " (pr-str s))))))
