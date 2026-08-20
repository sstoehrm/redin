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

(deftest gap-and-overflow
  (let [{:keys [node]} (convert "<div class=c><p>a</p></div>"
                                ".c { display:flex; flex-direction:column; gap: 10px; overflow-y: auto; height: 300px }")]
    (is (= :vbox (first node)))
    (is (= 10.0 (:gap (second node))))
    (is (= :scroll-y (:overflow (second node))))
    (is (= 300.0 (:height (second node))))))

(deftest margin-on-leaf-and-container
  (let [{:keys [node warnings]} (convert "<div class=c><p class=m>a</p></div>"
                                         ".m { margin: 10px 20px 30px 40px } .c { margin: 4px }")]
    (is (= [10 20 30 40] (:margin (second (nth node 2)))))
    (is (some #(re-find #"margin on container" %) warnings))
    (is (nil? (:margin (second node))))))

(deftest anchors-from-flex
  (let [{:keys [node]} (convert "<div class=c><p>a</p></div>"
                                ".c { display:flex; flex-direction:column; justify-content:center; align-items:center }")]
    (is (= :center (:layout (second node)))))
  (let [{:keys [node]} (convert "<div class=c><p>a</p></div>"
                                ".c { display:flex; justify-content:flex-end; align-items:flex-start }")]
    ;; hbox: justify -> horizontal (end), align -> vertical (start) => :top_right
    (is (= :top_right (:layout (second node))))))

(deftest width-full-and-warnings
  (let [{:keys [node]} (convert "<div class=c><p>a</p></div>" ".c { width: 100% }")]
    (is (= :full (:width (second node)))))
  (let [{:keys [warnings]} (convert "<div class=c>x</div>" ".c { width: 50% }")]
    (is (some #(re-find #"width: 50% unmappable" %) warnings))))

(deftest text-align-on-text
  (let [{:keys [node]} (convert "<p class=t>x</p>" ".t { text-align: center }")]
    (is (= :top_center (:layout (second node))))))

(deftest img-width-html-fallback-on-unmappable-css
  (let [{:keys [node warnings]} (convert "<img class=i width=200 height=100 src=x>"
                                         ".i { width: 50% }")]
    (is (= 200.0 (:width (second node))))
    (is (= 100.0 (:height (second node))))
    (is (some #(re-find #"width: 50% unmappable" %) warnings))))
