(ns html2redin.cascade
  (:require [clojure.string :as str]
            [html2redin.values :as v]))

(defn el-classes [el]
  (set (remove str/blank? (str/split (get-in el [:attrs "class"] "") #"\s+"))))

(defn- compound-matches? [{:keys [tag classes id]} el]
  (and (or (nil? tag) (= tag (name (:tag el))))
       (or (nil? id) (= id (get-in el [:attrs "id"])))
       (every? (el-classes el) classes)))

(defn- match-from
  "comps/combs remaining (right-to-left), anc = ancestors still available."
  [comps combs anc]
  (cond
    (empty? comps) true
    (empty? anc) false
    :else
    (let [c (first comps) comb (first combs)]
      (case comb
        :child (and (compound-matches? c (peek anc))
                    (match-from (rest comps) (rest combs) (pop anc)))
        :descendant
        (boolean (some #(and (compound-matches? c (nth anc %))
                             (match-from (rest comps) (rest combs) (subvec anc 0 %)))
                       (range (dec (count anc)) -1 -1)))))))

(defn matches?
  "Does rule match element (with `ancestors`, outermost first)?"
  [{:keys [compounds combinators]} el ancestors]
  (and (compound-matches? (peek compounds) el)
       (match-from (rest (rseq compounds)) (seq (rseq combinators)) (vec ancestors))))
