(ns html2redin.mapping
  (:require [clojure.string :as str]
            [html2redin.values :as v]))

(def container-tags #{:div :section :main :article :aside :nav :header :footer
                      :form :ul :ol :li :fieldset :root :body :table :thead
                      :tbody :tr :td :th})
(def text-tags #{:h1 :h2 :h3 :h4 :h5 :h6 :p :span :a :label :strong :em :b :i :small})
(def text-input-types #{"" "text" "email" "password" "search" "number" "url" "tel"})

(defn flatten-text
  "Collect an element's text content into one string; <br> -> newline."
  [el warn!]
  (let [saw-inline (atom false)
        s (letfn [(go [n]
                    (cond
                      (string? n) n
                      (= :br (:tag n)) "\n"
                      :else (do (reset! saw-inline true)
                                (apply str (interpose " " (map go (:children n)))))))]
            (apply str (interpose " " (map #(if (string? %) % (go %)) (:children el)))))]
    (when @saw-inline
      (warn! el "inline markup flattened to plain text"))
    (str/trim (str/replace s #" *\n *" "\n"))))

(defn- warn-str [source el msg] (str source ":" (:line el) " warning: " msg))

(defn- size-attr
  "HTML width/height attribute as a number (px), nil if absent/unparseable.
   CSS handling lives in node-attrs; this is only the HTML-attribute fallback."
  [el attr-name]
  (when-let [att (get-in el [:attrs attr-name])]
    (try (Double/parseDouble att) (catch Exception _ nil))))

(def ^:private pos->idx {"flex-start" 0 "start" 0 "left" 0 "center" 1
                         "flex-end" 2 "end" 2 "right" 2})
(def ^:private anchor-table
  [[:top_left :top_center :top_right]
   [:center_left :center :center_right]
   [:bottom_left :bottom_center :bottom_right]])

(defn- flex-anchor [style vertical?]
  (let [justify (pos->idx (get style :justify-content))
        align (pos->idx (get style :align-items))]
    (when (or justify align)
      (let [main (or justify 0) cross (or align 0)
            [v h] (if vertical? [main cross] [cross main])]
        (get-in anchor-table [v h])))))

(defn- margin-of [el]
  (let [sides (map #(get-in el [:style %])
                   [:margin-top :margin-right :margin-bottom :margin-left])]
    (when (some some? sides)
      (mapv #(v/clamp-u8 (or (let [p (v/parse-length (or % "0"))]
                               (when (number? p) p)) 0)) sides))))

(defn- length-attr [el warn! prop style-key]
  (when-let [raw (get-in el [:style style-key])]
    (let [p (v/parse-length raw)]
      (cond
        (number? p) p
        (= :full-percent p) :full
        :else (do (warn! el (str (name style-key) ": " raw " unmappable — dropped"))
                  nil)))))

(defn- node-attrs
  "Full redin attrs for an element. leaf? gates :margin; vertical? is the
   box orientation (nil for leaves other than text)."
  [el path assignments leaf? vertical? warn!]
  (let [style (:style el)
        own (:own-style el)
        gap (when-let [g (get own :gap)]
              (let [p (v/parse-length g)] (when (number? p) p)))
        overflow (let [oy (get own :overflow-y) ox (get own :overflow-x)]
                   (cond (#{"auto" "scroll"} oy) :scroll-y
                         (#{"auto" "scroll"} ox) :scroll-x
                         :else nil))
        margin (margin-of el)
        layout (if (= :text-leaf leaf?)
                 (when-let [ta (pos->idx (get style :text-align))]
                   (get-in anchor-table [0 ta]))
                 (when (some? vertical?) (flex-anchor own vertical?)))
        w (length-attr el warn! :width :width)
        h (length-attr el warn! :height :height)]
    (when (and margin (not leaf?))
      (warn! el (str "margin on container ."
                     (first (str/split (get-in el [:attrs "class"] "?") #"\s+"))
                     " dropped (redin has :gap/:padding)")))
    (cond-> {}
      (get-in el [:attrs "id"]) (assoc :id (keyword (get-in el [:attrs "id"])))
      (get assignments path) (assoc :aspect (get assignments path))
      gap (assoc :gap gap)
      overflow (assoc :overflow overflow)
      (and margin leaf?) (assoc :margin margin)
      layout (assoc :layout layout)
      w (assoc :width w)
      h (assoc :height h))))

(declare map-element)

;; redin's frame format allows bare string content only on :text/:button
;; nodes -- a string directly under a container (:vbox/:hbox) is dropped by
;; the runtime. Wrap loose text runs (e.g. mixed text in a <div>, table
;; cell content) in a plain [:text {} s] node instead.
(defn- wrap-loose-text [s] [:text {} s])

(defn- map-children [el path assignments warn!]
  (vec (keep-indexed
        (fn [i child]
          (if (string? child)
            (wrap-loose-text child)
            (map-element child (conj path i) assignments warn!)))
        (:children el))))

(defn map-element [el path assignments warn!]
  (let [style (:style el)
        tag (:tag el)]
    (cond
      (= "none" (get style :display))
      (do (warn! el (str "<" (name tag) "> dropped (display:none)")) nil)

      ;; text-like leaves
      (text-tags tag)
      (do (when (= :a tag)
            (warn! el (str "<a> mapped to :text — wire :click by hand (href="
                           (get-in el [:attrs "href"] "") ")")))
          (into [:text (node-attrs el path assignments :text-leaf nil warn!)]
                [(flatten-text el warn!)]))

      (= :button tag)
      (into [:button (node-attrs el path assignments true nil warn!)] [(flatten-text el warn!)])

      (= :input tag)
      (let [type (str/lower-case (get-in el [:attrs "type"] ""))]
        (if (#{"button" "submit"} type)
          [:button (node-attrs el path assignments true nil warn!)
           (get-in el [:attrs "value"] "")]
          (do (when-not (text-input-types type)
                (warn! el (str "input type=" type " treated as text input")))
              [:input (cond-> (node-attrs el path assignments true nil warn!)
                        (get-in el [:attrs "placeholder"]) (assoc :placeholder (get-in el [:attrs "placeholder"]))
                        (get-in el [:attrs "value"]) (assoc :value (get-in el [:attrs "value"])))])))

      (= :textarea tag)
      (do (warn! el "textarea mapped to single-line :input")
          [:input (cond-> (node-attrs el path assignments true nil warn!)
                    (seq (:children el)) (assoc :value (flatten-text el warn!)))])

      (= :img tag)
      (let [attrs (node-attrs el path assignments true nil warn!)
            w (size-attr el "width")
            h (size-attr el "height")]
        [:image (cond-> attrs
                  (and w (not (:width attrs))) (assoc :width w)
                  (and h (not (:height attrs))) (assoc :height h))])

      (= :hr tag)
      (let [attrs (node-attrs el path assignments true nil warn!)
            assigned (:aspect attrs)
            ;; Compose rather than clobber: an hr that also carries a
            ;; class-derived aspect (e.g. <hr class=sep>) keeps that
            ;; styling alongside the default hr border aspect.
            composed (cond
                       (nil? assigned) :hr-rule
                       (vector? assigned) (conj assigned :hr-rule)
                       :else [assigned :hr-rule])]
        [:vbox (assoc attrs :height 1.0 :aspect composed)])

      ;; containers (incl. table best-effort: tr -> hbox)
      (container-tags tag)
      (let [_ (when (= :table tag) (warn! el "table mapped best-effort to vbox of hbox rows"))
            flex-row? (and (= "flex" (get style :display))
                           (str/starts-with? (get style :flex-direction "row") "row"))
            box (cond (= :tr tag) :hbox flex-row? :hbox :else :vbox)]
        (into [box (node-attrs el path assignments false (not= box :hbox) warn!)]
              (map-children el path assignments warn!)))

      :else
      (do (warn! el (str "<" (name tag) "> unknown — treated as vbox"))
          (into [:vbox (node-attrs el path assignments false true warn!)]
                (map-children el path assignments warn!))))))

(defn- uses-hr-rule?
  "Does this mapped hiccup node (or any descendant) carry :hr-rule in its
   :aspect (bare or composed)? Used by the caller to decide whether a
   default :hr-rule theme entry needs to be merged in."
  [node]
  (and (vector? node)
       (let [[_ attrs & children] node
             a (:aspect attrs)]
         (boolean
          (or (= a :hr-rule)
              (and (vector? a) (some #{:hr-rule} a))
              (some #(and (vector? %) (uses-hr-rule? %)) children))))))

(defn map-tree
  "styled tree -> {:node hiccup :warnings [...] :uses-hr-rule? bool}"
  ([tree assignments] (map-tree tree assignments "t.html"))
  ([tree assignments source]
   (let [warnings (atom [])
         warn! (fn [el msg] (swap! warnings conj (warn-str source el msg)))
         kids (vec (keep-indexed
                    (fn [i c] (if (string? c) (wrap-loose-text c)
                                  (map-element c [i] assignments warn!)))
                    (:children tree)))
         node (if (and (= 1 (count kids)) (vector? (first kids)))
                (first kids)
                (into [:vbox {}] kids))]
     {:node node :warnings @warnings :uses-hr-rule? (uses-hr-rule? node)})))
