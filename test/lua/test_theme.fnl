(local theme (require :theme))

(local t {})

(fn setup []
  (theme.reset))

;; --- storage + basic resolve ---

(fn t.test-set-and-resolve []
  (setup)
  (theme.set-theme
    {:button {:bg [76 86 106] :color [236 239 244] :radius 6}})
  (let [props (theme.resolve :button [])]
    (assert (= (. props.bg 1) 76) "bg red")
    (assert (= props.radius 6) "radius")))

(fn t.test-resolve-missing-aspect []
  (setup)
  (theme.set-theme {})
  (let [props (theme.resolve :nonexistent [])]
    (assert (= (next props) nil) "missing aspect = empty table")))

;; --- state variants (# notation) ---

(fn t.test-state-variant-hover []
  (setup)
  (theme.set-theme
    {:button        {:bg [76 86 106] :color [236 239 244]}
     "button#hover" {:bg [94 105 126]}})
  (let [props (theme.resolve :button [:hover])]
    (assert (= (. props.bg 1) 94) "hover bg applied")
    (assert (= (. props.color 1) 236) "base color preserved")))

(fn t.test-state-variant-missing []
  (setup)
  (theme.set-theme
    {:button {:bg [76 86 106]}})
  (let [props (theme.resolve :button [:hover])]
    (assert (= (. props.bg 1) 76) "base bg when no hover variant")))

(fn t.test-multiple-states []
  (setup)
  (theme.set-theme
    {:button         {:bg [76 86 106] :radius 6}
     "button#hover"  {:bg [94 105 126]}
     "button#focus"  {:radius 8}})
  (let [props (theme.resolve :button [:hover :focus])]
    (assert (= (. props.bg 1) 94) "hover bg")
    (assert (= props.radius 8) "focus radius")))

;; --- composed aspects ---

(fn t.test-composed-merge []
  (setup)
  (theme.set-theme
    {:button {:bg [76 86 106] :color [236 239 244] :radius 6 :padding [8 16]}
     :danger {:bg [191 97 106] :color [236 239 244]}})
  (let [props (theme.resolve [:button :danger] [])]
    (assert (= (. props.bg 1) 191) "danger bg wins")
    (assert (= (. props.color 1) 236) "color preserved")
    (assert (= props.radius 6) "button radius preserved")
    (assert (= (. props.padding 1) 8) "button padding preserved")))

(fn t.test-composed-with-state []
  (setup)
  (theme.set-theme
    {:button         {:bg [76 86 106] :color [236 239 244]}
     :danger         {:bg [191 97 106]}
     "button#hover"  {:bg [94 105 126]}
     "danger#hover"  {:bg [200 100 110]}})
  (let [props (theme.resolve [:button :danger] [:hover])]
    (assert (= (. props.bg 1) 200) "danger#hover bg wins")
    (assert (= (. props.color 1) 236) "button color preserved")))

;; --- property consumption filter ---

(fn t.test-props-for-text []
  (setup)
  (let [all-props {:bg [0 0 0] :color [255 255 255] :font-size 14 :font :sans
                   :weight :bold :line-height 1.5 :opacity 0.8 :radius 6 :padding [8 8]}
        filtered (theme.props-for :text all-props)]
    (assert filtered.color "text consumes color")
    (assert filtered.font-size "text consumes font-size")
    (assert filtered.font "text consumes font")
    (assert filtered.weight "text consumes weight")
    (assert filtered.line-height "text consumes line-height")
    (assert filtered.opacity "text consumes opacity")
    (assert (= filtered.bg nil) "text does not consume bg")
    (assert (= filtered.radius nil) "text does not consume radius")
    (assert (= filtered.padding nil) "text does not consume padding")))


(fn t.test-props-for-input []
  (setup)
  (let [all-props {:bg [0 0 0] :color [255 255 255] :border [100 100 100]
                   :font :mono :padding [4 8] :radius 4 :border-width 1 :opacity 1}
        filtered (theme.props-for :input all-props)]
    (assert filtered.bg "input consumes bg")
    (assert filtered.color "input consumes color")
    (assert filtered.border "input consumes border")
    (assert filtered.font "input consumes font")
    (assert filtered.padding "input consumes padding")
    (assert filtered.radius "input consumes radius")
    (assert filtered.border-width "input consumes border-width")
    (assert filtered.opacity "input consumes opacity")))

;; --- validation ---

(fn t.test-validate-valid-theme []
  (let [result (theme.validate
    {:button {:bg [76 86 106] :color [236 239 244] :radius 6 :padding [8 16]}
     "button#hover" {:bg [94 105 126]}
     :body {:color [216 222 233] :font-size 14 :font :sans}})]
    (assert result.ok "valid theme passes")))

(fn t.test-validate-bad-color []
  (let [result (theme.validate {:button {:bg "red"}})]
    (assert (not result.ok) "string color fails"))
  (let [result (theme.validate {:button {:bg [256 0 0]}})]
    (assert (not result.ok) "color > 255 fails"))
  (let [result (theme.validate {:button {:bg [-1 0 0]}})]
    (assert (not result.ok) "color < 0 fails"))
  (let [result (theme.validate {:button {:bg [0 0]}})]
    (assert (not result.ok) "color with 2 elements fails")))

(fn t.test-validate-color-rgba []
  (let [result (theme.validate {:button {:bg [76 86 106 200]}})]
    (assert result.ok "rgba color passes")))

(fn t.test-validate-bad-font []
  (let [result (theme.validate {:body {:font 42}})]
    (assert (not result.ok) "non-string font fails"))
  (let [result (theme.validate {:body {:font :sans}})]
    (assert result.ok "valid font passes"))
  (let [result (theme.validate {:body {:font :my-custom-font}})]
    (assert result.ok "custom font name passes")))

(fn t.test-validate-bad-weight []
  (let [result (theme.validate {:body {:weight :heavy}})]
    (assert (not result.ok) "invalid weight fails"))
  (let [result (theme.validate {:body {:weight :bold}})]
    (assert result.ok "valid weight passes")))

(fn t.test-validate-bad-opacity []
  (let [result (theme.validate {:overlay {:opacity 1.5}})]
    (assert (not result.ok) "opacity > 1 fails"))
  (let [result (theme.validate {:overlay {:opacity -0.1}})]
    (assert (not result.ok) "opacity < 0 fails"))
  (let [result (theme.validate {:overlay {:opacity 0.5}})]
    (assert result.ok "valid opacity passes")))

(fn t.test-validate-bad-numeric []
  (let [result (theme.validate {:body {:font-size "big"}})]
    (assert (not result.ok) "string font-size fails"))
  (let [result (theme.validate {:body {:radius "round"}})]
    (assert (not result.ok) "string radius fails")))

(fn t.test-validate-padding-formats []
  (let [result (theme.validate {:box {:padding 8}})]
    (assert result.ok "number padding passes"))
  (let [result (theme.validate {:box {:padding [8 16]}})]
    (assert result.ok "[v h] padding passes"))
  (let [result (theme.validate {:box {:padding [4 8 4 8]}})]
    (assert result.ok "[t r b l] padding passes"))
  (let [result (theme.validate {:box {:padding [1 2 3]}})]
    (assert (not result.ok) "3-element padding fails")))

(fn t.test-validate-shadow []
  (let [result (theme.validate {:card {:shadow [0 2 4 [0 0 0 128]]}})]
    (assert result.ok "valid shadow passes"))
  (let [result (theme.validate {:card {:shadow "drop"}})]
    (assert (not result.ok) "string shadow fails"))
  (let [result (theme.validate {:card {:shadow [0 2]}})]
    (assert (not result.ok) "shadow with 2 elements fails"))
  (let [result (theme.validate {:card {:shadow [0 2 4 "black"]}})]
    (assert (not result.ok) "shadow with string color fails")))

t
