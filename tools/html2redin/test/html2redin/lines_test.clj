(ns html2redin.lines-test
  (:require [clojure.test :refer [deftest is]]
            [html2redin.lines :as lines]))

(defn- naive-line-of [text idx]
  (inc (count (filter #(= % \newline) (subs text 0 idx)))))

(deftest line-of-matches-naive-scan-at-every-offset
  (let [text "a\nbb\n\nccc\nd"
        nls (lines/index text)]
    (doseq [idx (range (inc (count text)))]
      (is (= (naive-line-of text idx) (lines/line-of nls idx))
          (str "offset " idx)))))

(deftest line-of-edge-cases
  (is (= 1 (lines/line-of (lines/index "") 0)))
  (is (= 1 (lines/line-of (lines/index "no newlines") 5)))
  (let [nls (lines/index "\n\n\n")]
    (is (= 1 (lines/line-of nls 0)))   ; the newline char itself is on its line
    (is (= 4 (lines/line-of nls 3)))))
