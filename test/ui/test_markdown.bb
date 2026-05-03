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
