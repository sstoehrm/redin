(ns html2redin.css-test
  (:require [clojure.test :refer [deftest is]]
            [html2redin.css :as css]))

(defn- rules [s] (:rules (css/parse "s.css" s)))
(defn- warns [s] (:warnings (css/parse "s.css" s)))

(deftest simple-rule
  (let [[r] (rules ".card { color: red; padding: 8px !important }")]
    (is (= [{:tag nil :classes #{"card"} :id nil}] (:compounds r)))
    (is (= [] (:combinators r)))
    (is (nil? (:pseudo r)))
    (is (= [[:color "red" false] [:padding "8px" true]] (:decls r)))
    (is (= [0 1 0] (:specificity r)))))

(deftest compound-descendant-child
  (let [[r] (rules "div.card > #x .y { margin: 0 }")]
    (is (= 3 (count (:compounds r))))
    (is (= [:child :descendant] (:combinators r)))
    (is (= {:tag "div" :classes #{"card"} :id nil} (first (:compounds r))))
    (is (= "x" (:id (second (:compounds r)))))
    (is (= [1 2 1] (:specificity r)))))

(deftest grouping-and-pseudo
  (let [rs (rules "h1, .btn:hover { color: blue }")]
    (is (= 2 (count rs)))
    (is (nil? (:pseudo (first rs))))
    (is (= :hover (:pseudo (second rs))))
    (is (= [0 2 0] (:specificity (second rs))))))  ; class + pseudo-class

(deftest skipped-constructs
  (is (some #(re-find #"selector .a \+ \.b. not supported" %)
            (warns "a + .b { color: red }")))
  (is (some #(re-find #"@media" %) (warns "@media (max-width: 600px) { .a { color: red } }")))
  (is (empty? (rules "a + .b { color: red }")))
  (is (= 1 (count (rules "@media x { .a{} } .b { color: red }")))))

(deftest comments-stripped
  (is (= 1 (count (rules "/* c */ .a { /* x */ color: red }")))))

(deftest stray-semicolon-between-rules
  (let [rs (rules ".a { color: red; }; .b { color: blue }")]
    (is (= 2 (count rs)))
    (is (= #{"a"} (:classes (first (:compounds (first rs))))))
    (is (= #{"b"} (:classes (first (:compounds (second rs))))))))
