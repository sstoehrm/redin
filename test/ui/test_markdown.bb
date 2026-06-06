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

;; #112 — note on copy-button presence coverage:
;; There is intentionally no UI assertion that the Copy button is *present*.
;; The lowered NodeButton does not appear in /frames (which exposes the
;; pre-lowering tree), and the markdown wrapper is a fill-height node, so its
;; /frames rect carries no signal about the copy bar. Pixel-probing the
;; rendered button is unreliable in dev builds — it is right-aligned in the
;; top-right corner where the F3 profile overlay also draws — and slow
;; (Babashka's PNG decoder is O(rows)). Button presence/shape is therefore
;; verified authoritatively by the lowering unit tests in
;; src/redin/markdown/lower_test.odin (test_lower_copyable_emits_copy_button,
;; test_lower_copy_button_has_compact_dimensions, test_lower_not_copyable_*).
;; The UI suite covers the other half of #112 below: markdown text is not
;; selectable. The copyable render path is still exercised by
;; markdown-renders-without-error (which screenshots a copyable block).

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
