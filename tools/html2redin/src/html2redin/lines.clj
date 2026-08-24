(ns html2redin.lines
  "O(1)-per-lookup line numbering over a precomputed newline index.

  Audit #277 M2: the previous per-call `(count (filter newline? (subs text
  0 idx)))` rescanned the input from byte 0 for every opening tag, entity,
  and CSS rule, going quadratic on adversarial (or just large) inputs.
  Build the index once per document, then each lookup is a binary search."
  (:require [clojure.string :as str]))

(defn index
  "Vector of the offsets of every newline in text, ascending."
  [text]
  (loop [i 0, acc []]
    (if-let [j (str/index-of text "\n" i)]
      (recur (inc j) (conj acc j))
      acc)))

(defn line-of
  "1-based line number of offset idx, given (index text): one more than
  the count of newlines at offsets strictly below idx."
  [nl-index idx]
  (loop [lo 0, hi (count nl-index)]
    (if (< lo hi)
      (let [mid (quot (+ lo hi) 2)]
        (if (< (nth nl-index mid) idx)
          (recur (inc mid) hi)
          (recur lo mid)))
      (inc lo))))
