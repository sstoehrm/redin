(ns html2redin.html-test
  (:require [clojure.test :refer [deftest is]]
            [html2redin.html :as html]))

(defn- parse [s] (html/parse "t.html" s))

(deftest nesting-and-attrs
  (let [{:keys [tree]} (parse "<div class=\"card top\" id=hero><p>Hi</p></div>")
        d (first (:children tree))]
    (is (= :div (:tag d)))
    (is (= "card top" (get-in d [:attrs "class"])))
    (is (= "hero" (get-in d [:attrs "id"])))
    (is (= :p (:tag (first (:children d)))))
    (is (= ["Hi"] (:children (first (:children d)))))))

(deftest void-and-unclosed
  (let [{:keys [tree]} (parse "<div><img src=x><br><p>a</div>")]
    (is (= [:img :br :p] (map :tag (:children (first (:children tree))))))))

(deftest body-extraction-and-style
  (let [{:keys [tree styles]} (parse "<html><head><style>.a{color:red}</style><title>x</title></head><body><div></div></body></html>")]
    (is (= [:div] (map :tag (:children tree))))
    (is (= ".a{color:red}" (:text (first styles))))))

(deftest skips-and-warnings
  (let [{:keys [tree warnings]} (parse "<div><script>var x;</script><svg><rect/></svg><span>ok</span></div>")]
    (is (= [:span] (map :tag (:children (first (:children tree))))))
    (is (some #(re-find #"<script> skipped" %) warnings))
    (is (some #(re-find #"<svg> skipped" %) warnings))))

(deftest entities-and-lines
  (let [{:keys [tree]} (parse "<p>a &amp; b &#65;</p>\n<p>two</p>")]
    (is (= ["a & b A"] (:children (first (:children tree)))))
    (is (= 2 (:line (second (:children tree)))))))
