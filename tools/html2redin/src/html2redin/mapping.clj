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

(defn- warn-str [el msg] (str "t.html:" (:line el) " warning: " msg))

(defn- size-attr [el prop attr-name style-key]
  ;; explicit width/height: CSS wins over HTML attribute
  (let [css (get-in el [:style style-key])
        att (get-in el [:attrs attr-name])]
    (cond
      css (let [p (v/parse-length css)]
            (cond (number? p) p
                  (= :full-percent p) :full
                  :else nil))
      att (try (Double/parseDouble att) (catch Exception _ nil))
      :else nil)))

(declare map-element)

(defn- map-children [el path assignments warn!]
  (vec (keep-indexed
        (fn [i child]
          (if (string? child)
            child
            (map-element child (conj path i) assignments warn!)))
        (:children el))))

(defn- base-attrs [el assignments path]
  (cond-> {}
    (get-in el [:attrs "id"]) (assoc :id (keyword (get-in el [:attrs "id"])))
    (get assignments path) (assoc :aspect (get assignments path))))

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
          (into [:text (base-attrs el assignments path)]
                [(flatten-text el warn!)]))

      (= :button tag)
      (into [:button (base-attrs el assignments path)] [(flatten-text el warn!)])

      (= :input tag)
      (let [type (str/lower-case (get-in el [:attrs "type"] ""))]
        (if (#{"button" "submit"} type)
          [:button (base-attrs el assignments path)
           (get-in el [:attrs "value"] "")]
          (do (when-not (text-input-types type)
                (warn! el (str "input type=" type " treated as text input")))
              [:input (cond-> (base-attrs el assignments path)
                        (get-in el [:attrs "placeholder"]) (assoc :placeholder (get-in el [:attrs "placeholder"]))
                        (get-in el [:attrs "value"]) (assoc :value (get-in el [:attrs "value"])))])))

      (= :textarea tag)
      (do (warn! el "textarea mapped to single-line :input")
          [:input (cond-> (base-attrs el assignments path)
                    (seq (:children el)) (assoc :value (flatten-text el warn!)))])

      (= :img tag)
      [:image (cond-> (base-attrs el assignments path)
                (size-attr el :width "width" :width) (assoc :width (size-attr el :width "width" :width))
                (size-attr el :height "height" :height) (assoc :height (size-attr el :height "height" :height)))]

      (= :hr tag)
      [:vbox (assoc (base-attrs el assignments path) :height 1.0 :aspect :hr-rule)]

      ;; containers (incl. table best-effort: tr -> hbox)
      (container-tags tag)
      (let [_ (when (= :table tag) (warn! el "table mapped best-effort to vbox of hbox rows"))
            flex-row? (and (= "flex" (get style :display))
                           (str/starts-with? (get style :flex-direction "row") "row"))
            box (cond (= :tr tag) :hbox flex-row? :hbox :else :vbox)]
        (into [box (base-attrs el assignments path)]
              (map-children el path assignments warn!)))

      :else
      (do (warn! el (str "<" (name tag) "> unknown — treated as vbox"))
          (into [:vbox (base-attrs el assignments path)]
                (map-children el path assignments warn!))))))

(defn map-tree
  "styled tree -> {:node hiccup :warnings [...]}"
  [tree assignments]
  (let [warnings (atom [])
        warn! (fn [el msg] (swap! warnings conj (warn-str el msg)))
        kids (vec (keep-indexed
                   (fn [i c] (if (string? c) c (map-element c [i] assignments warn!)))
                   (:children tree)))
        node (if (and (= 1 (count kids)) (vector? (first kids)))
               (first kids)
               (into [:vbox {}] kids))]
    {:node node :warnings @warnings}))
