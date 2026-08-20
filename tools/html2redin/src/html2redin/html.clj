(ns html2redin.html
  (:require [clojure.string :as str]))

(def void-tags #{:img :br :hr :input :meta :link :area :base :col :embed
                 :source :track :wbr})
(def skip-tags #{:script :svg :iframe :video :audio :canvas :title :meta :noscript})

(defn- line-of [text idx]
  (inc (count (filter #(= % \newline) (subs text 0 idx)))))

(defn- decode-entities [s warn! src line]
  ;; Walk matches with a Matcher (rather than str/replace) so each entity's
  ;; warning can be attributed to its own line -- the run's start line plus
  ;; newlines preceding the entity's offset within s -- not the run's
  ;; starting line, which is wrong for entities after a newline in the
  ;; same text run.
  (let [m (re-matcher #"&(#x?[0-9a-fA-F]+|\w+);" s)
        out (StringBuilder.)]
    (loop [pos 0]
      (if (.find m)
        (let [start (.start m)
              whole (.group m 0)
              body (.group m 1)
              entity-line (+ line (count (filter #(= % \newline) (subs s 0 start))))]
          (.append out (subs s pos start))
          (.append out
                   (cond
                     (= body "amp") "&" (= body "lt") "<" (= body "gt") ">"
                     (= body "quot") "\"" (= body "apos") "'"
                     (str/starts-with? body "#")
                     (let [hex? (str/starts-with? body "#x")
                           digits (subs body (if hex? 2 1))
                           cp (try (Integer/parseInt digits (if hex? 16 10))
                                   (catch Exception _ nil))
                           ch (when cp (try (String. (Character/toChars cp))
                                             (catch Exception _ nil)))]
                       (or ch
                           (do (warn! (str src ":" entity-line " warning: unknown entity " whole
                                           " passed through"))
                               whole)))
                     :else (do (warn! (str src ":" entity-line " warning: unknown entity " whole
                                            " passed through")) whole)))
          (recur (.end m)))
        (.append out (subs s pos))))
    (str out)))

(def ^:private attr-re
  #"([a-zA-Z][\w:-]*)(?:\s*=\s*(\"[^\"]*\"|'[^']*'|[^\s>]+))?")

(defn- parse-attrs [s]
  (into {}
        (for [[_ k v] (re-seq attr-re (or s ""))]
          [(str/lower-case k)
           (if v
             (if (or (str/starts-with? v "\"") (str/starts-with? v "'"))
               (subs v 1 (dec (count v)))
               v)
             "")])))

(defn- close-top
  "Pop the top-of-stack element and append it as a child of the new top."
  [stack]
  (let [closed (peek stack)
        st (pop stack)]
    (update-in st [(dec (count st)) :children] conj closed)))

(defn- close-all
  "Fold the whole stack down into a single root element."
  [stack]
  (peek (loop [st stack]
          (if (= 1 (count st)) st (recur (close-top st))))))

(defn parse
  "Lenient HTML parse. Returns {:tree {:tag :root ...} :styles [...] :warnings [...]}"
  [src text]
  (let [warnings (atom [])
        styles (atom [])
        warn! #(swap! warnings conj %)
        root {:tag :root :attrs {} :children [] :line 1}
        push-child (fn [stack child]
                     (update-in stack [(dec (count stack)) :children] conj child))]
    (loop [i 0, stack [root]]
      (if (>= i (count text))
        (let [tree (close-all stack)
              find-body (fn find-body [el]
                          (if (= :body (:tag el)) el
                              (some find-body (filter map? (:children el)))))
              body (find-body tree)]
          ;; When a <body> exists, use it (keeping :tag :body, not renamed)
          ;; as the tree root -- this lets `body { ... }` rules match and
          ;; inherit normally during cascade resolution. map-tree only ever
          ;; consumes the root's :children, never its own tag/attrs, so the
          ;; root-shape contract (root's children become the top-level view)
          ;; is unaffected either way.
          {:tree (or body tree)
           :styles @styles
           :warnings @warnings})
        (let [c (nth text i)]
          (if (not= c \<)
            ;; text run
            (let [end (or (str/index-of text "<" i) (count text))
                  raw (subs text i end)
                  txt (decode-entities raw warn! src (line-of text i))]
              (recur end (if (str/blank? txt) stack
                             (push-child stack (str/trim txt)))))
            (cond
              ;; comment
              (str/starts-with? (subs text i) "<!--")
              (recur (+ 3 (or (str/index-of text "-->" i) (count text))) stack)
              ;; doctype / other <! declarations
              (str/starts-with? (subs text i) "<!")
              (recur (inc (or (str/index-of text ">" i) (count text))) stack)
              ;; closing tag
              (str/starts-with? (subs text i) "</")
              (let [end (or (str/index-of text ">" i) (count text))
                    tag (keyword (str/lower-case (str/trim (subs text (+ i 2) end))))
                    ;; index (from top, 0-based) of nearest open element with this tag
                    depth (some (fn [[d el]] (when (= (:tag el) tag) d))
                                (map-indexed vector (rseq stack)))]
                (recur (inc end)
                       (if (nil? depth)
                         stack
                         (loop [st stack, n (inc depth)]
                           (if (zero? n) st (recur (close-top st) (dec n)))))))
              ;; opening tag
              :else
              (let [end (or (str/index-of text ">" i) (count text))
                    inside (subs text (inc i) end)
                    self-closing (str/ends-with? inside "/")
                    inside (if self-closing (subs inside 0 (dec (count inside))) inside)
                    [_ tagname rest-attrs] (re-matches #"(?s)([a-zA-Z][\w-]*)\s*(.*)" inside)
                    tag (keyword (str/lower-case (or tagname "")))
                    ln (line-of text i)
                    el {:tag tag :attrs (parse-attrs rest-attrs) :children [] :line ln}]
                (cond
                  (nil? tagname) (recur (inc end) stack)
                  ;; raw-text style: capture content
                  (= tag :style)
                  (let [close (or (str/index-of text "</style" end) (count text))
                        content (subs text (inc end) close)
                        after (inc (or (str/index-of text ">" close) (count text)))]
                    (swap! styles conj {:text content :line ln})
                    (recur after stack))
                  ;; skipped subtrees
                  (skip-tags tag)
                  (let [close-str (str "</" (name tag))
                        close (str/index-of text close-str end)
                        after (if close (inc (or (str/index-of text ">" close) (count text)))
                                  (inc end))]
                    (when-not (#{:title :meta :noscript} tag)
                      (warn! (str src ":" ln " warning: <" (name tag) "> skipped")))
                    (recur after stack))
                  (or self-closing (void-tags tag))
                  (recur (inc end) (push-child stack el))
                  :else
                  (recur (inc end) (conj stack el)))))))))))
