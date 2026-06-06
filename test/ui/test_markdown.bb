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

;; The md/copy-button theme sets bg [60 60 70].  Because the button
;; carries no explicit :width it fills the full-width md/copy-bar hbox,
;; so the copy-bar row renders solid [60 60 70] edge to edge.
;; The probe x-coordinate (100) is well inside both the card and the bar,
;; so the pixel is card-bg [40 44 52] where there is no copy bar and
;; button-bg [60 60 70] where the bar + button are rendered.
;;
;; NOTE: /frames exposes the original Lua view tree (pre-lowering).
;; The lowered NodeButton is an Odin-side construct that does not appear
;; as a child node in the frame JSON.  We therefore verify button
;; presence via the screenshot pixel at the copy-bar row, using the
;; known theme colours: card-bg [40 44 52], button-bg [60 60 70].
(def copy-button-bg [60 60 70])
(def card-bg        [40 44 52])

(deftest copyable-block-renders-copy-button
  ;; The :id :md-copy block has {:copyable true}; the lowering emits an
  ;; md/copy-bar hbox with a full-width md/copy-button child as its first
  ;; child (before the content paragraphs).  The button bg [60 60 70] fills
  ;; the entire width of the bar row.  We probe one pixel ~20px below the
  ;; block's top edge (inside the copy-bar, which starts after 16px card
  ;; padding) and assert it matches the copy-button colour.
  (let [md   (find-element {:id :md-copy})
        r    (rect-of md)]
    (assert r (str "md-copy wrapper must have a rect; got " (pr-str (frame-attrs md))))
    (let [probe-x 100
          probe-y (int (+ (:y r) 20))
          png     (screenshot)
          px      (vec (screenshot-pixel png probe-x probe-y))]
      (assert (= copy-button-bg px)
              (str "expected copy-button bg " copy-button-bg
                   " at (" probe-x "," probe-y ") inside the copyable block; got " px
                   ".  Block rect=" (pr-str r))))))

(deftest non-copyable-block-has-no-copy-button
  ;; The :id :md block is NOT copyable.  The same relative row inside that
  ;; block (y = block-top + 20) sits in the heading area where no copy bar
  ;; is rendered, so the pixel must NOT be the copy-button colour.
  (let [md   (find-element {:id :md})
        r    (rect-of md)]
    (assert r (str "md wrapper must have a rect; got " (pr-str (frame-attrs md))))
    (let [probe-x 100
          probe-y (int (+ (:y r) 20))
          png     (screenshot)
          px      (vec (screenshot-pixel png probe-x probe-y))]
      (assert (not= copy-button-bg px)
              (str "non-copyable block must NOT render copy-button bg " copy-button-bg
                   " at (" probe-x "," probe-y "); got " px
                   ".  Block rect=" (pr-str r))))))

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
