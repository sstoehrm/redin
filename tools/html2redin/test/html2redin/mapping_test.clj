(ns html2redin.mapping-test
  (:require [clojure.test :refer [deftest is]]
            [html2redin.html :as html]
            [html2redin.css :as css]
            [html2redin.cascade :as cas]
            [html2redin.mapping :as m]))

(defn- convert [htm css-text]
  (let [{:keys [tree]} (html/parse "t.html" htm)
        rules (:rules (css/parse "t.css" css-text))
        styled (:tree (cas/resolve-tree tree rules))]
    (m/map-tree styled {})))

(deftest structural-mapping
  (let [{:keys [node]} (convert "<div><p>Hi</p><button>Go</button></div>" "")]
    (is (= :vbox (first node)))
    (is (= [:text {} "Hi"] (nth node 2)))
    (is (= [:button {} "Go"] (nth node 3)))))

(deftest flex-row-becomes-hbox
  (let [{:keys [node]} (convert "<div class=r><span>a</span></div>"
                                ".r { display: flex; flex-direction: row }")]
    (is (= :hbox (first node)))))

(deftest inputs-images-ids
  (let [{:keys [node]} (convert "<div id=box><input type=text placeholder=Name value=v><img src=x width=30 height=20></div>" "")]
    (is (= :box (:id (second node))))
    (is (= [:input {:placeholder "Name" :value "v"}] (nth node 2)))
    (is (= [:image {:width 30.0 :height 20.0}] (nth node 3)))))

(deftest text-flattening-br-and-inline
  (let [{:keys [node warnings]} (convert "<p>a<br>b <strong>c</strong></p>" "")]
    (is (= [:text {} "a\nb c"] node))
    (is (some #(re-find #"inline markup flattened" %) warnings))))

(deftest display-none-dropped
  (let [{:keys [node warnings]} (convert "<div><p class=h>x</p><p>y</p></div>"
                                         ".h { display: none }")]
    (is (= 3 (count node)))          ; [:vbox {} [:text {} "y"]]
    (is (some #(re-find #"display:none" %) warnings))))

(deftest anchor-link-warns
  (let [{:keys [node warnings]} (convert "<a href=\"/x\">go</a>" "")]
    (is (= [:text {} "go"] node))
    (is (some #(re-find #"href=/x" %) warnings))))
