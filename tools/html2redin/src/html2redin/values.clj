(ns html2redin.values
  (:require [clojure.string :as str]))

(def named-colors
  {"black" [0 0 0] "white" [255 255 255] "red" [255 0 0] "lime" [0 255 0]
   "blue" [0 0 255] "yellow" [255 255 0] "cyan" [0 255 255] "aqua" [0 255 255]
   "magenta" [255 0 255] "fuchsia" [255 0 255] "silver" [192 192 192]
   "gray" [128 128 128] "grey" [128 128 128] "maroon" [128 0 0]
   "olive" [128 128 0] "green" [0 128 0] "purple" [128 0 128]
   "teal" [0 128 128] "navy" [0 0 128]})

(defn- hex->int [s] (Integer/parseInt s 16))

(defn clamp-u8 [n] (int (min 255 (max 0 (Math/round (double n))))))

(defn- parse-color-component
  "One rgb() component (number or percentage) -> double 0-255, nil if unparseable."
  [s]
  (try
    (if (str/ends-with? s "%")
      (* 2.55 (Double/parseDouble (subs s 0 (dec (count s)))))
      (Double/parseDouble s))
    (catch Exception _ nil)))

(defn- parse-alpha-component
  "One alpha component (number or percentage) -> double 0.0-1.0, nil if unparseable."
  [s]
  (try
    (if (str/ends-with? s "%")
      (/ (Double/parseDouble (subs s 0 (dec (count s)))) 100.0)
      (Double/parseDouble s))
    (catch Exception _ nil)))

(defn- parse-rgb-args
  "rgb()/rgba() argument string (space- or comma-separated, optional
   `/ alpha`, %-components allowed) -> [r g b] or [r g b a], nil if
   unparseable. Never throws."
  [args]
  (try
    (let [[main slash-alpha] (map str/trim (str/split (str/trim args) #"/" 2))
          sep (if (str/includes? main ",") #"," #"\s+")
          parts (->> (str/split main sep) (map str/trim) (remove str/blank?))]
      (cond
        (and slash-alpha (= 3 (count parts)))
        (let [comps (mapv parse-color-component parts)
              a (parse-alpha-component slash-alpha)]
          (when (and (every? some? comps) a)
            (conj (mapv clamp-u8 comps) a)))

        (= 3 (count parts))
        (let [comps (mapv parse-color-component parts)]
          (when (every? some? comps) (mapv clamp-u8 comps)))

        (= 4 (count parts))
        (let [comps (mapv parse-color-component (take 3 parts))
              a (parse-alpha-component (nth parts 3))]
          (when (and (every? some? comps) a)
            (conj (mapv clamp-u8 comps) a)))

        :else nil))
    (catch Exception _ nil)))

(defn parse-color
  "CSS color string -> [r g b] or [r g b a] (a 0.0-1.0), nil if unsupported.
   Never throws, regardless of how malformed the input is."
  [s]
  (let [s (str/trim (str/lower-case (or s "")))]
    (or (named-colors s)
        (when-let [[_ h] (re-matches #"#([0-9a-f]{3})" s)]
          (mapv #(hex->int (str % %)) h))
        (when-let [[_ h] (re-matches #"#([0-9a-f]{6})" s)]
          (mapv #(hex->int (subs h % (+ % 2))) [0 2 4]))
        (when-let [[_ h] (re-matches #"#([0-9a-f]{8})" s)]
          (conj (mapv #(hex->int (subs h % (+ % 2))) [0 2 4])
                (/ (Math/round (* 100.0 (/ (hex->int (subs h 6 8)) 255.0))) 100.0)))
        (when-let [[_ args] (re-matches #"rgba?\(([^)]*)\)" s)]
          (parse-rgb-args args)))))

(defn parse-length
  "CSS length -> px number, :full-percent for 100%, nil if unmappable.
   Never throws, regardless of how malformed the input is."
  [s]
  (let [s (str/trim (or s ""))]
    (cond
      (= s "0") 0.0
      (re-matches #"-?[\d.]+px" s)
      (try (Double/parseDouble (subs s 0 (- (count s) 2))) (catch Exception _ nil))
      (re-matches #"-?[\d.]+rem" s)
      (try (* 16.0 (Double/parseDouble (subs s 0 (- (count s) 3)))) (catch Exception _ nil))
      (= s "100%") :full-percent
      :else nil)))
