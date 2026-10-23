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

(deftest interleaved-string-element-children
  (is (= (str "[:vbox {}\n"
              "  \"lead\"\n"
              "  [:text {} \"a\"]\n"
              "  \"trail\"]")
         (e/view-fnl [:vbox {} "lead" [:text {} "a"] "trail"]))))

(deftest theme-output
  (is (= (str "{:card {:bg [17 17 17] :padding [8 16 8 16]}\n"
              " :card#hover {:bg [34 34 34]}}")
         (e/theme-fnl {:card {:bg [17 17 17] :padding [8 16 8 16]}
                       :card#hover {:bg [34 34 34]}}))))

;; review S1: emission is the last line of defence against code injection --
;; a keyword/symbol whose name isn't a plain Fennel keyword must never be
;; printed raw, whichever upstream path produced it.
(deftest refuses-unsafe-keywords
  (let [evil (keyword "x (os.execute \"touch pwned\") :z")]
    (is (thrown? clojure.lang.ExceptionInfo (e/fmt-value evil)))
    (is (thrown? clojure.lang.ExceptionInfo (e/fmt-value [:ok evil])))
    (is (thrown? clojure.lang.ExceptionInfo (e/view-fnl [:vbox {:id evil}])))
    (is (thrown? clojure.lang.ExceptionInfo (e/view-fnl [:vbox {evil 1}])))
    (is (thrown? clojure.lang.ExceptionInfo (e/view-fnl [evil {}])))
    (is (thrown? clojure.lang.ExceptionInfo (e/theme-fnl {evil {:bg [0 0 0]}})))
    (is (thrown? clojure.lang.ExceptionInfo (e/theme-fnl {:a {evil 1}})))
    (is (thrown? clojure.lang.ExceptionInfo (e/fmt-value (keyword ""))))
    (is (thrown? clojure.lang.ExceptionInfo (e/fmt-value :ns/kw)))
    (is (thrown? clojure.lang.ExceptionInfo (e/fmt-value 'sym)))
    (is (thrown? clojure.lang.ExceptionInfo (e/fmt-value nil)))
    (is (thrown? clojure.lang.ExceptionInfo (e/fmt-value ##Inf)))
    (is (thrown? clojure.lang.ExceptionInfo (e/fmt-value ##NaN))))
  ;; legitimate shapes still emit
  (is (= ":card#hover" (e/fmt-value :card#hover)))
  (is (= ":hr-rule" (e/fmt-value :hr-rule)))
  (is (= ":top_left" (e/fmt-value :top_left)))
  (is (= ":1col" (e/fmt-value :1col))))
