(ns html2redin.emit
  (:require [clojure.string :as str]))

(defn- fmt-num [n]
  (if (and (number? n) (== n (Math/floor (double n))) (not (ratio? n)))
    (str (long n)) (str n)))

;; The generated .fnl is *code* that redin loads and runs, so emission is the
;; last line of defence against injection (review S1): every keyword printed
;; must be a plain Fennel keyword -- identifier characters, optionally one
;; `#state` suffix (theme variants like :button#hover). Anything else (spaces,
;; parens, quotes, `:`, `.`, an empty name, a namespace) throws instead of
;; being printed raw, whichever upstream path produced it.
(def ^:private safe-keyword-re #"[A-Za-z0-9_][A-Za-z0-9_-]*(?:#[A-Za-z0-9_-]+)?")

(defn fmt-keyword [k]
  (if (and (keyword? k) (nil? (namespace k))
           (re-matches safe-keyword-re (name k)))
    (str k)
    (throw (ex-info (str "html2redin: refusing to emit unsafe keyword " (pr-str k))
                    {:value k}))))

(defn fmt-value [x]
  (cond
    (keyword? x) (fmt-keyword x)
    (string? x) (str "\"" (-> x (str/replace "\\" "\\\\")
                              (str/replace "\"" "\\\"")
                              (str/replace "\n" "\\n")) "\"")
    (and (number? x) (not (ratio? x))
         (not (Double/isNaN (double x))) (not (Double/isInfinite (double x))))
    (fmt-num x)
    (boolean? x) (str x)
    (vector? x) (str "[" (str/join " " (map fmt-value x)) "]")
    ;; symbols, nil, non-finite numbers, maps, ... have no safe literal form
    ;; here -- never fall back to (str x).
    :else (throw (ex-info (str "html2redin: refusing to emit value " (pr-str x))
                          {:value x}))))

(def attr-order [:id :aspect :layout :width :height :gap :margin :overflow
                 :placeholder :value :click])

(defn- fmt-attrs [attrs]
  (let [ks (concat (filter (set (keys attrs)) attr-order)
                   (sort (remove (set attr-order) (keys attrs))))]
    (str "{" (str/join " " (map #(str (fmt-keyword %) " " (fmt-value (get attrs %))) ks)) "}")))

(defn view-fnl
  ([node] (view-fnl node 0))
  ([[tag attrs & children] depth]
   (let [pad (apply str (repeat (* 2 depth) " "))
         head (str "[" (fmt-keyword tag) " " (fmt-attrs attrs))
         has-elements? (some vector? children)]
     (if has-elements?
       ;; Has element children: emit each child on its own line in order
       (let [child-depth (inc depth)
             child-pad (apply str (repeat (* 2 child-depth) " "))
             formatted-children (map (fn [child]
                                       (if (vector? child)
                                         (view-fnl child child-depth)
                                         (str child-pad (fmt-value child))))
                                     children)]
         (str pad head "\n"
              (str/join "\n" formatted-children)
              "]"))
       ;; No element children: all strings on head line (or no children)
       (let [strs (filter string? children)]
         (str pad head (when (seq strs) (str " " (str/join " " (map fmt-value strs)))) "]"))))))

(def theme-key-order [:bg :color :border :border-width :radius :padding
                      :font-size :weight :font :line-height :opacity :shadow])

(defn theme-fnl [theme]
  (let [fmt-entry (fn [[aspect props]]
                    (let [ks (concat (filter (set (keys props)) theme-key-order)
                                     (sort (remove (set theme-key-order) (keys props))))]
                      (str (fmt-keyword aspect) " {"
                           (str/join " " (map #(str (fmt-keyword %) " " (fmt-value (get props %))) ks))
                           "}")))
        entries (sort-by (comp name key) theme)]
    (str "{" (str/join "\n " (map fmt-entry entries)) "}")))
