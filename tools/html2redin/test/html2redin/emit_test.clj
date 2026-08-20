(ns html2redin.emit-test
  (:require [clojure.test :refer [deftest is]]
            [html2redin.emit :as e]))

(deftest scalars-and-leaf
  (is (= "[:text {:aspect :body} \"hi \\\"x\\\"\"]"
         (e/view-fnl [:text {:aspect :body} "hi \"x\""])))
  (is (= "[:image {:width 30 :height 20.5}]"
         (e/view-fnl [:image {:width 30.0 :height 20.5}]))))

(deftest nested-indent
  (is (= (str "[:vbox {:gap 10}\n"
              "  [:text {} \"a\"]\n"
              "  [:hbox {:aspect [:a :b]}\n"
              "    [:button {} \"go\"]]]")
         (e/view-fnl [:vbox {:gap 10.0}
                      [:text {} "a"]
                      [:hbox {:aspect [:a :b]} [:button {} "go"]]]))))

(deftest theme-output
  (is (= (str "{:card {:bg [17 17 17] :padding [8 16 8 16]}\n"
              " :card#hover {:bg [34 34 34]}}")
         (e/theme-fnl {:card {:bg [17 17 17] :padding [8 16 8 16]}
                       :card#hover {:bg [34 34 34]}}))))
