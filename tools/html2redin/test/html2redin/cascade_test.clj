(ns html2redin.cascade-test
  (:require [clojure.test :refer [deftest is]]
            [html2redin.css :as css]
            [html2redin.cascade :as cas]
            [html2redin.html :as html]))

(defn- rule [sel] (first (:rules (css/parse "t" (str sel " { color: red }")))))
(defn- el [tag & [attrs]] {:tag tag :attrs (or attrs {}) :children [] :line 1})

(deftest compound-matching
  (is (cas/matches? (rule ".card") (el :div {"class" "card top"}) []))
  (is (not (cas/matches? (rule ".card") (el :div {"class" "cardx"}) [])))
  (is (cas/matches? (rule "div.card#a") (el :div {"class" "card" "id" "a"}) []))
  (is (not (cas/matches? (rule "p.card") (el :div {"class" "card"}) []))))

(deftest descendant-and-child
  (let [gp (el :section) p (el :div {"class" "row"}) c (el :span)]
    (is (cas/matches? (rule "section span") c [gp p]))
    (is (cas/matches? (rule ".row > span") c [gp p]))
    (is (not (cas/matches? (rule "section > span") c [gp p])))
    (is (not (cas/matches? (rule ".nope span") c [gp p])))))

(deftest shorthand-expansion
  (is (= [[:margin-top "8px" false] [:margin-right "4px" false]
          [:margin-bottom "8px" false] [:margin-left "4px" false]]
         (cas/expand-decl [:margin "8px 4px" false])))
  (is (= [[:padding-top "1px" false] [:padding-right "2px" false]
          [:padding-bottom "3px" false] [:padding-left "4px" false]]
         (cas/expand-decl [:padding "1px 2px 3px 4px" false])))
  (is (= #{[:border-width "1px" false] [:border-color "#fff" false]}
         (set (cas/expand-decl [:border "1px solid #fff" false]))))
  (is (= [[:background-color "#2e3440" false]]
         (cas/expand-decl [:background "#2e3440 url(x.png)" false])))
  (is (= [[:font-size "14px" false] [:font-weight "bold" false]
          [:font-family "\"Helvetica Neue\", sans-serif" false]]
         (cas/expand-decl [:font "bold 14px \"Helvetica Neue\", sans-serif" false]))))

(deftest cascade-resolution
  (let [css "div { color: red } .a { color: blue } #x { color: green } .a:hover { color: black }"
        rules (:rules (html2redin.css/parse "t" css))
        tree {:tag :root :attrs {} :line 1
              :children [{:tag :div :attrs {"class" "a"} :line 1
                          :children [{:tag :span :attrs {} :children ["hi"] :line 1}]}
                         {:tag :div :attrs {"class" "a" "id" "x"} :children [] :line 2}]}
        styled (:tree (cas/resolve-tree tree rules))
        [d1 d2] (:children styled)]
    (is (= "blue" (get-in d1 [:style :color])))          ; class beats type
    (is (= "green" (get-in d2 [:style :color])))         ; id beats class
    (is (= "blue" (get-in (first (:children d1)) [:style :color]))) ; inherited
    (is (nil? (get-in (first (:children d1)) [:own-style :color]))) ; not own
    (is (= "black" (get-in d1 [:variants :hover :color])))
    (is (= "blue" (get-in d1 [:class-style :color])))))

(deftest body-rule-matches-and-inherits-to-children
  (let [{:keys [tree]} (html/parse "t.html" "<html><body><p>hi</p></body></html>")
        rules (:rules (css/parse "t.css" "body { color: red }"))
        styled (:tree (cas/resolve-tree tree rules))]
    (is (= :body (:tag styled)))
    (is (= "red" (get-in styled [:own-style :color])))
    (is (= "red" (get-in (first (:children styled)) [:style :color])))
    (is (nil? (get-in (first (:children styled)) [:own-style :color])))))

(deftest important-wins
  (let [css ".a { color: red !important } #x { color: green }"
        rules (:rules (html2redin.css/parse "t" css))
        tree {:tag :root :attrs {} :children [{:tag :div :attrs {"class" "a" "id" "x"} :children [] :line 1}] :line 1}
        styled (:tree (cas/resolve-tree tree rules))]
    (is (= "red" (get-in (first (:children styled)) [:style :color])))))
