(ns html2redin.css
  (:require [clojure.string :as str]
            [html2redin.lines :as lines]))

(def supported-pseudo {"hover" :hover "focus" :focus "active" :active})

(defn- strip-comments [s] (str/replace s #"(?s)/\*.*?\*/" " "))

(defn- skip-block
  "Return index just past the brace-balanced block starting at the first {
   at/after i, or past the next ; if no block."
  [s i]
  (let [open (str/index-of s "{" i)
        semi (str/index-of s ";" i)]
    (cond
      (and semi (or (nil? open) (< semi open))) (inc semi)
      (nil? open) (count s)
      :else (loop [j (inc open), depth 1]
              (cond
                (>= j (count s)) j
                (= (nth s j) \{) (recur (inc j) (inc depth))
                (= (nth s j) \}) (if (= depth 1) (inc j) (recur (inc j) (dec depth)))
                :else (recur (inc j) depth))))))

(defn- parse-compound [s]
  ;; "div.card#x:hover" -> {:compound {...} :pseudo :hover} or nil if unsupported
  (let [[_ tag trailer] (re-matches #"([a-zA-Z][\w-]*|\*)?((?:[.#:][\w-]+)*)" s)]
    (when (and (or tag (seq trailer)) (= s (str (or tag "") trailer)))
      (loop [parts (re-seq #"[.#:][\w-]+" (or trailer ""))
             classes #{} id nil pseudo nil ok true]
        (if-let [[p & more] (seq parts)]
          (case (first p)
            \. (recur more (conj classes (subs p 1)) id pseudo ok)
            \# (recur more classes (subs p 1) pseudo ok)
            \: (if-let [ps (supported-pseudo (subs p 1))]
                 (recur more classes id ps ok)
                 (recur more classes id pseudo false)))
          (when ok
            {:compound {:tag (when (and tag (not= tag "*")) (str/lower-case tag))
                        :classes classes :id id}
             :pseudo pseudo}))))))

(defn- parse-selector [sel]
  ;; -> {:compounds [...] :combinators [...] :pseudo ...} or nil
  (let [tokens (-> sel str/trim
                   (str/replace #"\s*>\s*" " > ")
                   (str/split #"\s+"))]
    (loop [ts tokens, compounds [], combinators [], pending-comb nil]
      (if-let [[t & more] (seq ts)]
        (if (= t ">")
          (recur more compounds combinators :child)
          (when-let [{:keys [compound pseudo]} (parse-compound t)]
            (when (or (nil? pseudo) (empty? more))  ; pseudo only on rightmost
              (recur more
                     (conj compounds (assoc compound ::pseudo pseudo))
                     (if (seq compounds) (conj combinators (or pending-comb :descendant)) combinators)
                     nil))))
        (let [pseudo (::pseudo (peek compounds))]
          {:compounds (mapv #(dissoc % ::pseudo) compounds)
           :combinators combinators
           :pseudo pseudo})))))

(defn- specificity [{:keys [compounds pseudo]}]
  [(count (keep :id compounds))
   (+ (reduce + (map (comp count :classes) compounds)) (if pseudo 1 0))
   (count (keep :tag compounds))])

(defn- parse-decls [s]
  (vec (for [d (str/split s #";")
             :let [d (str/trim d)
                   [_ p v] (re-matches #"(?s)([\w-]+)\s*:\s*(.+)" d)]
             :when p
             :let [imp (boolean (re-find #"!important\s*$" v))
                   v (str/trim (str/replace v #"!important\s*$" ""))]]
         [(keyword (str/lower-case p)) v imp])))

(defn parse
  "Parse one stylesheet. Returns {:rules [...] :warnings [...]}."
  [src text]
  (let [text (strip-comments text)
        nls (lines/index text)
        warnings (atom [])]
    (loop [i 0, order 0, rules []]
      (let [i (loop [j i] (if (and (< j (count text))
                                   (or (Character/isWhitespace (nth text j))
                                       (= (nth text j) \;)))
                            (recur (inc j)) j))]
        (if (>= i (count text))
          {:rules rules :warnings @warnings}
          (let [line (lines/line-of nls i)]
            (if (= (nth text i) \@)
              ;; Name the at-rule from a bounded window — `(str/split (subs
              ;; text i) ...)` copied and scanned the whole remainder per
              ;; @-rule, going quadratic on rule-dense input (#277 M2).
              (do (swap! warnings conj
                         (str src ":" line " warning: "
                              (re-find #"^[^\s{]*"
                                       (subs text i (min (count text) (+ i 64))))
                              " block skipped"))
                  (recur (skip-block text i) order rules))
              (let [open (str/index-of text "{" i)]
                (if (nil? open)
                  {:rules rules :warnings @warnings}
                  (let [close (skip-block text i)
                        sel-text (str/trim (subs text i open))
                        decls (parse-decls (subs text (inc open) (dec close)))
                        parsed (for [sel (str/split sel-text #",")]
                                 [(str/trim sel) (parse-selector sel)])
                        good (for [[_ p] parsed :when p] p)
                        _ (doseq [[raw p] parsed :when (nil? p)]
                            (swap! warnings conj
                                   (str src ":" line " warning: selector \"" raw
                                        "\" not supported — rule skipped")))
                        new-rules (map-indexed
                                   (fn [k sel]
                                     (merge sel
                                            {:decls decls
                                             :specificity (specificity sel)
                                             :order (+ order k)
                                             :source src :line line}))
                                   good)]
                    (recur close (+ order (count good)) (into rules new-rules))))))))))))
