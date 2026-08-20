(ns html2redin.emit
  (:require [clojure.string :as str]))

(defn- fmt-num [n]
  (if (and (number? n) (== n (Math/floor (double n))) (not (ratio? n)))
    (str (long n)) (str n)))

(defn fmt-value [x]
  (cond
    (keyword? x) (str x)
    (string? x) (str "\"" (-> x (str/replace "\\" "\\\\")
                              (str/replace "\"" "\\\"")
                              (str/replace "\n" "\\n")) "\"")
    (number? x) (fmt-num x)
    (vector? x) (str "[" (str/join " " (map fmt-value x)) "]")
    :else (str x)))

(def attr-order [:id :aspect :layout :width :height :gap :margin :overflow
                 :placeholder :value :click])

(defn- fmt-attrs [attrs]
  (let [ks (concat (filter (set (keys attrs)) attr-order)
                   (sort (remove (set attr-order) (keys attrs))))]
    (str "{" (str/join " " (map #(str % " " (fmt-value (get attrs %))) ks)) "}")))

(defn view-fnl
  ([node] (view-fnl node 0))
  ([[tag attrs & children] depth]
   (let [pad (apply str (repeat (* 2 depth) " "))
         head (str "[" tag " " (fmt-attrs attrs))
         elems (filter vector? children)
         strs (filter string? children)]
     (if (empty? elems)
       (str pad head (when (seq strs) (str " " (str/join " " (map fmt-value strs)))) "]")
       (str pad head
            (when (seq strs) (str " " (str/join " " (map fmt-value strs)))) "\n"
            (str/join "\n" (map #(view-fnl % (inc depth)) elems))
            "]")))))

(def theme-key-order [:bg :color :border :border-width :radius :padding
                      :font-size :weight :font :line-height :opacity :shadow])

(defn theme-fnl [theme]
  (let [fmt-entry (fn [[aspect props]]
                    (let [ks (concat (filter (set (keys props)) theme-key-order)
                                     (sort (remove (set theme-key-order) (keys props))))]
                      (str aspect " {"
                           (str/join " " (map #(str % " " (fmt-value (get props %))) ks))
                           "}")))
        entries (sort-by (comp name key) theme)]
    (str "{" (str/join "\n " (map fmt-entry entries)) "}")))
