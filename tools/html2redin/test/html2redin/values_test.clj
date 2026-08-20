(ns html2redin.values-test
  (:require [clojure.test :refer [deftest is]]
            [html2redin.values :as v]))

(deftest colors
  (is (= [255 0 0] (v/parse-color "#f00")))
  (is (= [46 52 64] (v/parse-color "#2e3440")))
  (is (= [46 52 64 0.5] (v/parse-color "#2e344080")))
  (is (= [10 20 30] (v/parse-color "rgb(10, 20, 30)")))
  (is (= [10 20 30 0.4] (v/parse-color "rgba(10,20,30,0.4)")))
  (is (= [255 255 255] (v/parse-color "white")))
  (is (nil? (v/parse-color "var(--x)"))))

(deftest lengths
  (is (= 12.0 (v/parse-length "12px")))
  (is (= 24.0 (v/parse-length "1.5rem")))
  (is (= 0.0 (v/parse-length "0")))
  (is (= :full-percent (v/parse-length "100%")))
  (is (nil? (v/parse-length "50%")))
  (is (nil? (v/parse-length "2em")))
  (is (nil? (v/parse-length "auto"))))

(deftest clamping
  (is (= 255 (v/clamp-u8 300.4)))
  (is (= 0 (v/clamp-u8 -3)))
  (is (= 8 (v/clamp-u8 8.4))))

(deftest rgb-space-and-percent-syntax-never-throws
  (is (= [255 0 0] (v/parse-color "rgb(255 0 0)")))
  (is (= [255 0 0] (v/parse-color "rgb(100%, 0%, 0%)")))
  (is (= [0 0 0 0.5] (v/parse-color "rgba(0 0 0 / 0.5)"))))

(deftest malformed-color-never-throws
  (is (nil? (v/parse-color "rgb(a b c)")))
  (is (nil? (v/parse-color "rgb(1 2)")))
  (is (nil? (v/parse-color "rgb()"))))

(deftest parse-length-multi-dot-never-throws
  (is (nil? (v/parse-length "1.2.3px"))))
