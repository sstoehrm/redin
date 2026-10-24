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

;; review C14a: a declaration outside any block made skip-block stop at its
;; `;` (before the next `{`), so (subs text (inc open) (dec close)) got
;; close < open and threw StringIndexOutOfBoundsException.
(deftest declaration-outside-block-is-skipped
  (let [{:keys [rules warnings]} (css/parse "s.css" "color: red;\n.a { color: blue }")]
    (is (= 1 (count rules)))
    (is (= #{"a"} (:classes (first (:compounds (first rules))))))
    (is (= [[:color "blue" false]] (:decls (first rules))))
    (is (some #(re-find #"^s\.css:1 warning: .*outside" %) warnings))))

;; Same slice, other end: a block left open at EOF (`.b {` as the last
;; characters) also produced a negative range; an unterminated block with
;; declarations lost its last character.
(deftest unterminated-block-at-eof
  (let [rs (rules ".a { color: red }\n.b {")]
    (is (= 2 (count rs)))
    (is (= [] (:decls (second rs)))))
  (is (= [[:color "red" false]] (:decls (first (rules ".a { color: red"))))))
