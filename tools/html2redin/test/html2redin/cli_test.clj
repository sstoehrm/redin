(ns html2redin.cli-test
  (:require [clojure.test :refer [deftest is]]
            [html2redin.cli :as cli]))

(deftest pipeline-end-to-end
  (let [{:keys [view theme warnings]}
        (cli/run {:html "<div class=card><p>Hi</p><button class=cta>Go</button></div><style>.card{background-color:#111;padding:8px;gap:4px;display:flex;flex-direction:column}.cta{background-color:#08f}.cta:hover{background-color:#09f}</style>"
                  :html-path "page.html"
                  :css-sources []})]
    (is (re-find #"\[:vbox \{:aspect :card :gap 4\}" view))
    (is (re-find #"\[:text \{\} \"Hi\"\]" view))
    (is (re-find #"\[:button \{:aspect :cta\} \"Go\"\]" view))
    (is (re-find #":card \{:bg \[17 17 17\] :padding \[8 8 8 8\]\}" theme))
    (is (re-find #":cta#hover \{:bg \[0 153 255\]\}" theme))
    (is (vector? warnings))))

(deftest css-source-ordering
  ;; -c files come first, <style> last => <style> wins ties
  (let [{:keys [theme]}
        (cli/run {:html "<p class=a>x</p><style>.a{color:#00f}</style>"
                  :html-path "p.html"
                  :css-sources [{:name "x.css" :text ".a{color:#f00}"}]})]
    (is (re-find #":color \[0 0 255\]" theme))))

(deftest inline-style-warning-line-is-document-relative
  ;; the <style> block opens on line 2; the unsupported selector is on
  ;; document line 3 -- the warning must carry 3, not 1 (block-relative)
  (let [html (str "<div></div>\n"
                  "<style>\n"
                  "a ~ b { color: red }\n"
                  "</style>\n")
        {:keys [warnings]} (cli/run {:html html :html-path "page.html" :css-sources []})]
    (is (some #(re-find #"^page\.html#style1:3 warning: selector" %) warnings))))

(deftest hr-rule-default-theme-entry-and-composition
  (let [{:keys [theme]}
        (cli/run {:html "<hr>" :html-path "page.html" :css-sources []})]
    (is (re-find #":hr-rule \{:bg \[128 128 128\]\}" theme)))
  ;; a class-styled hr keeps its own aspect's styling as well as :hr-rule
  (let [{:keys [view theme]}
        (cli/run {:html "<hr class=sep>"
                  :html-path "page.html"
                  :css-sources [{:name "s.css" :text ".sep{background-color:#f00}"}]})]
    (is (re-find #"\[:sep :hr-rule\]" view))
    (is (re-find #":hr-rule \{:bg \[128 128 128\]\}" theme))
    (is (re-find #":sep \{:bg \[255 0 0\]\}" theme))))
