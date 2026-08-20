(ns html2redin.e2e-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.java.io :as io]
            [html2redin.cli :as cli]))

(defn- fixture [n]
  (slurp (io/file "tools/html2redin/test/html2redin/fixtures" n)))

(deftest golden
  (let [{:keys [view theme]}
        (cli/run {:html (fixture "sample.html")
                  :html-path "sample.html"
                  :css-sources [{:name "sample.css" :text (fixture "sample.css")}]})]
    (is (= (clojure.string/trim (fixture "expected-view.fnl")) view))
    (is (= (clojure.string/trim (fixture "expected-theme.fnl")) theme))))
