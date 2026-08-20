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

(defn parse-color
  "CSS color string -> [r g b] or [r g b a] (a 0.0-1.0), nil if unsupported."
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
          (let [parts (mapv str/trim (str/split args #","))
                nums (mapv #(Double/parseDouble %) parts)]
            (when (<= 3 (count nums) 4)
              (let [rgb (mapv #(int (Math/round ^double %)) (take 3 nums))]
                (if (= 4 (count nums)) (conj rgb (nth nums 3)) rgb))))))))

(defn parse-length
  "CSS length -> px number, :full-percent for 100%, nil if unmappable."
  [s]
  (let [s (str/trim (or s ""))]
    (cond
      (= s "0") 0.0
      (re-matches #"-?[\d.]+px" s) (Double/parseDouble (subs s 0 (- (count s) 2)))
      (re-matches #"-?[\d.]+rem" s) (* 16.0 (Double/parseDouble (subs s 0 (- (count s) 3))))
      (= s "100%") :full-percent
      :else nil)))

(defn clamp-u8 [n] (int (min 255 (max 0 (Math/round (double n))))))
