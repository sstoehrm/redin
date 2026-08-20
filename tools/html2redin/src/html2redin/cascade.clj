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

(defn- four-sides [raw]
  (let [parts (str/split (str/trim raw) #"\s+")
        [t r b l] (case (count parts)
                    1 (let [[a] parts] [a a a a])
                    2 (let [[a b] parts] [a b a b])
                    3 (let [[a b c] parts] [a b c b])
                    (take 4 parts))]
    [t r b l]))

(defn expand-decl
  "Expand one [prop raw important?] into longhand decls."
  [[prop raw imp]]
  (case prop
    (:margin :padding)
    (let [[t r b l] (four-sides raw)
          base (name prop)]
      [[(keyword (str base "-top")) t imp] [(keyword (str base "-right")) r imp]
       [(keyword (str base "-bottom")) b imp] [(keyword (str base "-left")) l imp]])
    :border
    (let [tokens (str/split (str/trim raw) #"\s+")]
      (vec (concat (when-let [w (some #(when (v/parse-length %) %) tokens)]
                     [[:border-width w imp]])
                   (when-let [c (some #(when (v/parse-color %) %) tokens)]
                     [[:border-color c imp]]))))
    :background
    (if-let [c (some #(when (v/parse-color %) %) (str/split (str/trim raw) #"\s+"))]
      [[:background-color c imp]] [])
    :font
    (let [tokens (str/split (str/trim raw) #"[\s,]+")
          size (some #(when (v/parse-length %) %) tokens)
          weight (some #(when (re-matches #"bold|[1-9]00" %) %) tokens)
          family (last tokens)]
      (vec (concat (when size [[:font-size size imp]])
                   (when weight [[:font-weight weight imp]])
                   (when (and family (not (v/parse-length family))) [[:font-family family imp]]))))
    :gap [[:gap (first (str/split (str/trim raw) #"\s+")) imp]]
    :overflow [[:overflow-y raw imp] [:overflow-x raw imp]]
    ;; default: already a longhand
    [[prop raw imp]]))

(def inherited-props #{:color :font-size :font-family :font-weight :line-height :text-align})

(defn- winning-decls
  "Matched rules -> {prop raw}, honoring !important, specificity, order."
  [matched]
  (let [entries (for [r matched
                      [prop raw imp] (mapcat expand-decl (:decls r))]
                  {:prop prop :raw raw
                   :key [(if imp 1 0) (:specificity r) (:order r)]})]
    (reduce (fn [m {:keys [prop raw key]}]
              (if (or (not (contains? m prop)) (>= (compare key (get-in m [prop :key])) 0))
                (assoc m prop {:raw raw :key key}) m))
            {} entries)))

(defn- style-map [matched]
  (into {} (map (fn [[k v]] [k (:raw v)]) (winning-decls matched))))

(defn resolve-tree
  "Annotate every element with :style/:own-style/:class-style/:variants."
  [tree rules]
  (letfn [(walk [el ancestors inherited]
            (if-not (map? el)
              el
              (let [base (filter #(and (nil? (:pseudo %)) (matches? % el ancestors)) rules)
                    own (style-map base)
                    class-rules (filter #(seq (:classes (peek (:compounds %)))) base)
                    class-style (style-map class-rules)
                    variants (into {}
                               (for [ps [:hover :focus :active]
                                     :let [vr (filter #(and (= ps (:pseudo %))
                                                            (matches? % el ancestors)) rules)]
                                     :when (seq vr)]
                                 [ps (style-map vr)]))
                    style (merge (select-keys inherited inherited-props) own)
                    el' (assoc el :style style :own-style own
                               :class-style class-style :variants variants)]
                (assoc el' :children
                       (mapv #(walk % (conj (vec ancestors) el) style)
                             (:children el))))))]
    {:tree (walk tree [] {}) :warnings []}))
