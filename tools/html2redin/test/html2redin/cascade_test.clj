(ns html2redin.cascade-test
  (:require [clojure.test :refer [deftest is]]
            [html2redin.css :as css]
            [html2redin.cascade :as cas]))

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
