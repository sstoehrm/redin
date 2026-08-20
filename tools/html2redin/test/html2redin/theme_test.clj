(ns html2redin.theme-test
  (:require [clojure.test :refer [deftest is]]
            [html2redin.html :as html]
            [html2redin.css :as css]
            [html2redin.cascade :as cas]
            [html2redin.theme :as th]))

(defn- synth [htm css-text]
  (let [{:keys [tree]} (html/parse "t.html" htm)
        rules (:rules (css/parse "t.css" css-text))]
    (th/synthesize (:tree (cas/resolve-tree tree rules)))))

(deftest font-shorthand-family-is-first-family-name
  (let [[props _] (th/visual-props {:font-family "\"Helvetica Neue\", sans-serif"} "t.css:1")]
    (is (= "Helvetica Neue" (:font props))))
  ;; end-to-end through the `font:` shorthand (expand-decl -> cascade ->
  ;; theme synthesis): family must be "Helvetica Neue", not the shorthand's
  ;; last raw token ("sans-serif")
  (let [{:keys [theme assignments]}
        (synth "<h1>t</h1>"
               "h1 { font: bold 14px \"Helvetica Neue\", sans-serif }")]
    (is (= "Helvetica Neue" (get-in theme [(get assignments [0]) :font])))))

(deftest visual-prop-conversion
  (let [[props _] (th/visual-props
                   {:background-color "#2e3440" :color "white"
                    :padding-top "8px" :padding-right "16px"
                    :padding-bottom "8px" :padding-left "16px"
                    :border-radius "6px" :border-color "#888" :border-width "1px"
                    :font-size "14px" :font-weight "700" :line-height "1.5"
                    :opacity "0.8" :box-shadow "2px 2px 8px rgba(0,0,0,0.5)"}
                   "t.css:1")]
    (is (= {:bg [46 52 64] :color [255 255 255] :padding [8 16 8 16]
            :radius 6 :border [136 136 136] :border-width 1
            :font-size 14 :weight 1 :line-height 1.5 :opacity 0.8
            :shadow [2 2 8 [0 0 0 0.5]]}
           props))))

(deftest class-aspects-and-variants
  (let [{:keys [theme assignments]} (synth "<div class=card><p>x</p></div>"
                                           ".card { background-color: #111 } .card:hover { background-color: #222 }")]
    (is (= [17 17 17] (get-in theme [:card :bg])))
    (is (= [34 34 34] (get-in theme [:card#hover :bg])))
    (is (= :card (get assignments [0])))))

(deftest multi-class-composes
  (let [{:keys [theme assignments]} (synth "<div class=\"a b\">x</div>"
                                           ".a { color: red } .b { background-color: #000 }")]
    (is (= [:a :b] (get assignments [0])))
    (is (contains? theme :a))
    (is (contains? theme :b))))

(deftest disambiguation-when-resolved-differs
  ;; #id override makes the element's own style differ from its class
  (let [{:keys [theme assignments]} (synth "<div class=card id=x>a</div><div class=card>b</div>"
                                           ".card { color: red } #x { color: blue }")]
    (is (= :card-2 (get assignments [0])))
    (is (= [0 0 255] (get-in theme [:card-2 :color])))
    (is (= :card (get assignments [1])))))

(deftest classless-styled-element
  (let [{:keys [theme assignments]} (synth "<h1>t</h1>" "h1 { font-size: 24px }")]
    (is (= :h1-1 (get assignments [0])))
    (is (= 24 (get-in theme [:h1-1 :font-size])))))

(deftest body-color-inherits-into-child-text-aspect
  ;; a classless child with no own color rule gets a generated aspect
  ;; carrying the color it inherits from `body { color: ... }`
  (let [{:keys [theme assignments]}
        (synth "<body><span>hi</span></body>" "body { color: #88c0d0 }")]
    (is (= :span-1 (get assignments [0])))
    (is (= [136 192 208] (get-in theme [:span-1 :color])))))

(deftest unstyled-gets-no-aspect
  (let [{:keys [assignments]} (synth "<p>x</p>" "")]
    (is (empty? assignments))))

(deftest distinct-classes-with-same-props-do-not-collide
  ;; "car" must not reuse "card" merely because it's a string prefix
  (let [{:keys [theme assignments]} (synth "<div class=card>x</div><div class=car>y</div>"
                                           ".card { color: red } .car { color: red }")]
    (is (= :card (get assignments [0])))
    (is (= :car (get assignments [1])))
    (is (= [255 0 0] (get-in theme [:card :color])))
    (is (= [255 0 0] (get-in theme [:car :color])))))

(deftest variant-mismatch-forces-disambiguation
  ;; both elements share the same base .card props, but the id=x element's
  ;; :hover resolves differently (id beats class) — it must NOT silently
  ;; reuse :card and lose its own hover
  (let [{:keys [theme assignments]}
        (synth "<div class=card>a</div><div class=card id=x>b</div>"
               ".card { background-color: #111 } .card:hover { color: blue } #x:hover { color: green }")]
    (is (= :card (get assignments [0])))
    (is (= :card-2 (get assignments [1])))
    (is (= [0 0 255] (get-in theme [:card#hover :color])))
    (is (= [0 128 0] (get-in theme [:card-2#hover :color])))))
