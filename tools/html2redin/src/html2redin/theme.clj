(ns html2redin.theme
  (:require [clojure.string :as str]
            [html2redin.values :as v]
            [html2redin.cascade :as cas]))

(def visual-longhands
  #{:background-color :color :border-color :border-width :border-radius
    :padding-top :padding-right :padding-bottom :padding-left
    :font-size :font-weight :font-family :line-height :opacity :box-shadow})

;; Mirrors mapping.clj's text-tags (text/button-ish leaves that flatten to
;; :text). Kept as a small local duplicate rather than a cross-require --
;; the pipeline stages are deliberately decoupled from one another.
(def ^:private leaf-text-tags
  #{:h1 :h2 :h3 :h4 :h5 :h6 :p :span :a :label :strong :em :b :i :small})

(defn- rgb3 [c] (when c (vec (take 3 c))))

(defn visual-props
  "CSS longhands -> redin theme props. Returns [props warnings]."
  [style ctx]
  (let [warnings (atom [])
        warn! #(swap! warnings conj (str ctx " warning: " %))
        num (fn [raw] (let [p (v/parse-length raw)] (when (number? p) p)))
        props
        (cond-> {}
          (get style :background-color)
          (as-> m (let [c (v/parse-color (get style :background-color))]
                    (cond-> m
                      c (assoc :bg (rgb3 c))
                      (and c (= 4 (count c)) (< (nth c 3) 1.0)) (assoc :opacity (nth c 3)))))
          (get style :color)
          (as-> m (if-let [c (v/parse-color (get style :color))]
                    (assoc m :color (rgb3 c)) m))
          (get style :border-color)
          (as-> m (if-let [c (v/parse-color (get style :border-color))]
                    (assoc m :border (rgb3 c)) m))
          (get style :border-width)
          (as-> m (if-let [n (num (get style :border-width))]
                    (assoc m :border-width (v/clamp-u8 n)) m))
          (get style :border-radius)
          (as-> m (if-let [n (num (get style :border-radius))]
                    (assoc m :radius (v/clamp-u8 n)) m))
          (some style [:padding-top :padding-right :padding-bottom :padding-left])
          (assoc :padding (mapv #(v/clamp-u8 (or (num (get style % "0")) 0))
                                [:padding-top :padding-right :padding-bottom :padding-left]))
          (get style :font-size)
          (as-> m (if-let [n (num (get style :font-size))]
                    (assoc m :font-size (int n)) m))
          (get style :font-weight)
          (assoc :weight (let [w (get style :font-weight)]
                           (if (or (= w "bold")
                                   (>= (or (try (Integer/parseInt w) (catch Exception _ 0)) 0) 600))
                             1 0)))
          (get style :font-family)
          (assoc :font (-> (get style :font-family) (str/split #",") first str/trim
                           (str/replace #"^[\"']|[\"']$" "")))
          (get style :line-height)
          (as-> m (let [lh (get style :line-height)]
                    (if (re-matches #"[\d.]+" lh)
                      (assoc m :line-height (Double/parseDouble lh))
                      (do (warn! (str "line-height " lh " not unitless — dropped")) m))))
          (get style :opacity)
          (as-> m (try (assoc m :opacity (Double/parseDouble (get style :opacity)))
                       (catch Exception _ m)))
          (get style :box-shadow)
          (as-> m (let [tokens (str/split (str/trim (get style :box-shadow)) #"\s+(?![^(]*\))")
                        nums (keep num (take 3 tokens))
                        color (some v/parse-color tokens)]
                    (if (and (>= (count nums) 2) color)
                      (assoc m :shadow [(int (nth nums 0)) (int (nth nums 1))
                                        (int (or (nth nums 2 nil) 0))
                                        (if (= 4 (count color)) (vec color) (conj (vec color) 1.0))])
                      (do (warn! "box-shadow unmappable — dropped") m)))))]
    [props @warnings]))

(defn- sanitize [s]
  (-> s str/lower-case (str/replace #"[^a-z0-9-]" "-") (str/replace #"-+" "-")
      (str/replace #"^-|-$" "")))

(defn- visual-subset [style] (select-keys style visual-longhands))

(defn- base-key-match?
  "Does theme key k belong to base-name's own family — k is exactly
   base-name, or base-name followed by a numeric disambiguation suffix
   (`base-2`, `base-17`, ...)? Never matches a variant key (`base#hover`)
   and never matches an unrelated base name that merely shares a prefix
   (`car` must not match `card`)."
  [k base-name]
  (let [nm (name k)]
    (and (not (str/includes? nm "#"))
         (or (= nm base-name)
             (when-let [suffix (and (str/starts-with? nm (str base-name "-"))
                                     (subs nm (inc (count base-name))))]
               (re-matches #"\d+" suffix))))))

(defn- variants-of
  "{pseudo-name-string props} for the variant entries already registered
   under theme key aspect-name (`hover` -> props, from `aspect-name#hover`)."
  [theme-map aspect-name]
  (let [prefix (str aspect-name "#")]
    (into {}
          (keep (fn [[k p]]
                  (let [nm (name k)]
                    (when (str/starts-with? nm prefix)
                      [(subs nm (count prefix)) p]))))
          theme-map)))

(defn synthesize
  "styled tree -> {:theme {...} :assignments {path aspect} :warnings [...]}"
  ([tree] (synthesize tree "t.html"))
  ([tree source]
  (let [theme (atom {}) assignments (atom {}) warnings (atom []) counters (atom {})
        register!
        (fn [base-name props variants ctx always-suffix?]
          ;; Reuse an existing aspect only when BOTH its base props and its
          ;; full set of converted variant props match exactly — an element
          ;; with a differing pseudo-state style (e.g. an id-specific
          ;; :hover override) is not the same aspect and must disambiguate,
          ;; carrying its own variant(s). Class-derived base names keep the
          ;; bare name on first claim; tag-derived (classless) base names
          ;; are always numbered, so a synthetic aspect never collides with
          ;; a literal class name.
          (let [computed (mapv (fn [[ps vstyle]]
                                  (let [[vprops vwarns] (visual-props (visual-subset vstyle) ctx)]
                                    [ps vprops vwarns]))
                                variants)
                variant-props (into {} (keep (fn [[ps vprops _]]
                                                (when (seq vprops) [(name ps) vprops]))
                                              computed))
                existing (some (fn [[k p]]
                                 (when (and (base-key-match? k base-name)
                                            (= p props)
                                            (= (variants-of @theme (name k)) variant-props))
                                   k))
                               @theme)
                aspect (or existing
                           (let [n (get (swap! counters update base-name (fnil inc 0)) base-name)
                                 nm (if (and (= 1 n) (not always-suffix?))
                                      base-name
                                      (str base-name "-" n))]
                             (keyword nm)))]
            (when-not existing
              (swap! theme assoc aspect props)
              (doseq [[ps vprops vwarns] computed]
                (swap! warnings into vwarns)
                (when (seq vprops)
                  (swap! theme assoc (keyword (str (name aspect) "#" (name ps))) vprops))))
            aspect))
        walk
        (fn walk [mode el path]
          (when (map? el)
            (let [ctx (str source ":" (:line el))
                  own-vis (visual-subset (:own-style el))
                  class-vis (visual-subset (:class-style el))
                  classes (vec (remove str/blank?
                                       (str/split (get-in el [:attrs "class"] "") #"\s+")))
                  faithful? (and (seq classes) (= own-vis class-vis))
                  ;; A classless leaf with no own declarations at all can
                  ;; still visually differ from "unstyled" via inheritance
                  ;; alone (e.g. text color from a `body { color: ... }`
                  ;; rule). :style already merges inherited-props from
                  ;; ancestors under own, so its visual subset carries
                  ;; exactly the inherited value here (own-vis is empty).
                  ;; Scoped to classless leaf-text tags only, so this never
                  ;; fires for containers/tables and can't change any
                  ;; existing faithful/disambiguation outcome (those all
                  ;; require non-empty own-vis or a class).
                  inherited-vis (when (and (empty? own-vis) (empty? classes)
                                            (leaf-text-tags (:tag el)))
                                  (visual-subset (:style el)))
                  eff-vis (if (seq inherited-vis) inherited-vis own-vis)]
              (when (and (seq eff-vis)
                         (if (= mode :faithful) faithful? (not faithful?)))
                (let [[props pwarns] (visual-props eff-vis ctx)]
                  (swap! warnings into pwarns)
                  (when (seq props)
                    (if faithful?
                      ;; faithful to classes: register merged props under each
                      ;; sanitized class name; register! reuses identical
                      ;; existing entries so shared classes converge
                      (if (= 1 (count classes))
                        (swap! assignments assoc path
                               (register! (sanitize (first classes)) props (:variants el) ctx false))
                        (swap! assignments assoc path
                               (mapv #(register! (sanitize %) props (:variants el) ctx false)
                                     classes)))
                      ;; disambiguated or classless
                      (let [base (if (seq classes)
                                   (sanitize (first classes))
                                   (name (:tag el)))]
                        (swap! assignments assoc path
                               (register! base props (:variants el) ctx (empty? classes))))))))
              (doseq [[i c] (map-indexed vector (:children el))]
                (walk mode c (conj path i))))))]
    (doseq [[i c] (map-indexed vector (:children tree))]
      (walk :faithful c [i]))
    (doseq [[i c] (map-indexed vector (:children tree))]
      (walk :rest c [i]))
    {:theme @theme :assignments @assignments :warnings @warnings})))
