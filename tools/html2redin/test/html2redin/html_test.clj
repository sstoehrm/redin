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

(deftest body-tag-is-preserved-not-renamed
  ;; the root must stay tagged :body (not :root) so `body { ... }` CSS
  ;; rules can match it during cascade resolution
  (let [{:keys [tree]} (parse "<html><body><p>hi</p></body></html>")]
    (is (= :body (:tag tree)))
    (is (= [:p] (map :tag (:children tree))))))

(deftest skips-and-warnings
  (let [{:keys [tree warnings]} (parse "<div><script>var x;</script><svg><rect/></svg><span>ok</span></div>")]
    (is (= [:span] (map :tag (:children (first (:children tree))))))
    (is (some #(re-find #"<script> skipped" %) warnings))
    (is (some #(re-find #"<svg> skipped" %) warnings))))

(deftest entities-and-lines
  (let [{:keys [tree]} (parse "<p>a &amp; b &#65;</p>\n<p>two</p>")]
    (is (= ["a & b A"] (:children (first (:children tree)))))
    (is (= 2 (:line (second (:children tree)))))))

(deftest unknown-entity-warning-line-within-multiline-run
  (let [{:keys [warnings]} (parse "<p>ok\n&bogus;</p>")]
    (is (some #(re-find #"^t\.html:2 warning: unknown entity &bogus; passed through$" %) warnings))))

(deftest supplementary-plane-numeric-entity-never-throws
  (let [{:keys [tree]} (parse "<p>&#128512;</p>")]
    (is (= ["😀"] (:children (first (:children tree)))))
    (is (= "😀" (str (char 0xD83D) (char 0xDE00))))))

(deftest out-of-range-numeric-entities-pass-through-with-warning
  (let [{:keys [tree warnings]} (parse "<p>&#99999999999;</p>")]
    (is (= ["&#99999999999;"] (:children (first (:children tree)))))
    (is (some #(re-find #"unknown entity &#99999999999; passed through" %) warnings)))
  (let [{:keys [tree warnings]} (parse "<p>&#xFFFFFFFFF;</p>")]
    (is (= ["&#xFFFFFFFFF;"] (:children (first (:children tree)))))
    (is (some #(re-find #"unknown entity &#xFFFFFFFFF; passed through" %) warnings))))

(deftest nesting-capped-so-consumers-never-overflow
  ;; #277 M2: unbounded nesting built a tree every recursive consumer
  ;; (find-body, mapping, emit) died on. Depth is capped; deeper opening
  ;; tags become leaves, with a single warning.
  (let [n 5000
        {:keys [tree warnings]} (parse (apply str (repeat n "<b>")))
        depth (loop [el tree, d 0]
                (if-let [child (first (filter map? (:children el)))]
                  (recur child (inc d))
                  d))]
    (is (<= depth 256))
    (is (= 1 (count (filter #(re-find #"nesting deeper than 256" %) warnings))))))
