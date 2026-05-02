(require '[redin-test :refer :all]
         '[clojure.java.io :as io])

(defn- ensure-artifacts-dir []
  (let [d (io/file "test/ui/artifacts")]
    (when-not (.exists d) (.mkdirs d))))

(deftest markdown-attr-present
  (let [n (find-element {:id :md})]
    (assert n "markdown text node must exist")
    ;; The :markdown attr round-trips through /frames as a boolean true.
    (let [attrs (get n 1)]
      (assert (= true (get attrs :markdown))
              (str ":markdown attr must round-trip; attrs=" (pr-str attrs))))))

(deftest markdown-renders-without-error
  (ensure-artifacts-dir)
  (wait-ms 100)
  (screenshot "test/ui/artifacts/markdown_render.png"))

(deftest md-extended-renders
  (let [el (find-element {:id :md-extended})]
    (assert el "md-extended must exist in /frames")
    (let [r (rect-of el)]
      (assert r "md-extended must have a :rect")
      ;; H1 (font-size 40 × line-height 1.5 = 60px) + H2 (32 × 1.5 = 48px)
      ;; + paragraph (24 × 1.5 = 36px) + paragraph spacing -> >= ~120px.
      ;; Use a conservative threshold of 80 to allow font-metric variance.
      (assert (>= (:h r) 80)
              (str "md-extended rect height should be >= 80, got " (:h r))))))
