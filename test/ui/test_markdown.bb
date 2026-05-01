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
