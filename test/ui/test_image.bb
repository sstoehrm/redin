(require '[redin-test :refer :all])

;; -- Frame structure --

(deftest image-elements-exist
  (dispatch ["event/reset"])
  (wait-ms 200)
  (assert-element {:tag :image :id :logo} "Logo image should exist")
  (assert-element {:tag :image :id :banner} "Banner image should exist")
  (assert-element {:tag :image :id :plain} "Plain image should exist"))

(deftest logo-has-aspect
  (let [el (find-element {:tag :image :id :logo})
        attrs (second el)]
    (assert (= "logo" (name (:aspect attrs))) "Logo should have :logo aspect")))

(deftest banner-has-aspect
  (let [el (find-element {:tag :image :id :banner})
        attrs (second el)]
    (assert (= "banner" (name (:aspect attrs))) "Banner should have :banner aspect")))

(deftest plain-has-no-aspect
  (let [el (find-element {:tag :image :id :plain})
        attrs (second el)]
    (assert (nil? (:aspect attrs)) "Plain image should have no aspect")))

(deftest images-have-dimensions
  (let [logo (find-element {:tag :image :id :logo})
        banner (find-element {:tag :image :id :banner})
        plain (find-element {:tag :image :id :plain})]
    (assert (= 120 (:width (second logo))) "Logo width should be 120")
    (assert (= 40 (:height (second logo))) "Logo height should be 40")
    (assert (= 300 (:width (second banner))) "Banner width should be 300")
    (assert (= 80 (:height (second banner))) "Banner height should be 80")
    (assert (= 60 (:width (second plain))) "Plain width should be 60")
    (assert (= 60 (:height (second plain))) "Plain height should be 60")))

;; -- Conditional rendering --

(deftest toggle-hides-logo
  (dispatch ["event/reset"])
  (wait-ms 200)
  (assert-element {:tag :image :id :logo})
  (dispatch ["event/toggle"])
  (wait-ms 200)
  (assert-no-element {:tag :image :id :logo} "Logo should be hidden after toggle"))

(deftest toggle-preserves-other-images
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/toggle"])
  (wait-ms 200)
  (assert-element {:tag :image :id :banner} "Banner should remain")
  (assert-element {:tag :image :id :plain} "Plain should remain"))

(deftest toggle-back-shows-logo
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/toggle"])
  (wait-ms 200)
  (dispatch ["event/toggle"])
  (wait-ms 200)
  (assert-element {:tag :image :id :logo} "Logo should reappear after double toggle"))

;; -- Reset --

(deftest reset-shows-logo
  (dispatch ["event/toggle"])
  (wait-ms 100)
  (dispatch ["event/reset"])
  (wait-ms 200)
  (assert-element {:tag :image :id :logo} "Reset should restore logo"))

;; -- :src / :fit attributes (texture foundation spec) --

(deftest src-images-exist-and-app-stays-alive
  (dispatch ["event/reset"])
  (wait-ms 300)
  (assert-element {:tag :image :id :sprite} "src image should exist")
  (assert-element {:tag :image :id :sprite-keep} "keep-fit image should exist")
  (assert-element {:tag :image :id :broken} "broken-src image should exist")
  ;; several frames of texture rendering must not crash the app
  (wait-ms 500)
  (assert-element {:tag :image :id :sprite} "app alive after sustained texture draws"))

(deftest src-attr-roundtrips
  (let [el (find-element {:tag :image :id :sprite})
        attrs (second el)]
    (assert (= "test/ui/fixtures/sprite.png" (:src attrs)) "src attr should round-trip")))

(deftest screenshot-valid-with-textures
  (let [[w h] (screenshot-dims (screenshot))]
    (assert (pos? w) "screenshot decodes with textures on screen")
    (assert (pos? h))))

;; -- :fit stretch-x / stretch-y coverage (#3) --
;; image_app.fnl adds :sprite-stretch-x (32x64) and :sprite-stretch-y
;; (64x32). The fixture texture is a square 4x4, so fitting it into these
;; rects makes both modes letterbox rather than overflow: see the comment
;; on those elements in image_app.fnl for the geometry.

(deftest stretch-x-and-stretch-y-images-exist
  (dispatch ["event/reset"])
  (wait-ms 300)
  (assert-element {:tag :image :id :sprite-stretch-x} "stretch-x image should exist")
  (assert-element {:tag :image :id :sprite-stretch-y} "stretch-y image should exist"))

(deftest stretch-x-and-stretch-y-fit-attrs-roundtrip
  (let [sx (find-element {:tag :image :id :sprite-stretch-x})
        sy (find-element {:tag :image :id :sprite-stretch-y})]
    (assert (= "stretch-x" (:fit (second sx))) "sprite-stretch-x should have :fit stretch-x")
    (assert (= "stretch-y" (:fit (second sy))) "sprite-stretch-y should have :fit stretch-y")))

(deftest stretch-x-and-stretch-y-dimensions
  (let [sx (find-element {:tag :image :id :sprite-stretch-x})
        sy (find-element {:tag :image :id :sprite-stretch-y})]
    (assert (= 32 (:width (second sx))) "sprite-stretch-x width should be 32")
    (assert (= 64 (:height (second sx))) "sprite-stretch-x height should be 64")
    (assert (= 64 (:width (second sy))) "sprite-stretch-y width should be 64")
    (assert (= 32 (:height (second sy))) "sprite-stretch-y height should be 32")))

;; -- Pixel spot-checks (#1) --
;; The fixture (test/ui/fixtures/sprite.png) is 4x4 RGBA, top half solid
;; red, bottom half solid blue. Sample dominance rather than exact values
;; to stay robust to point-filter edge effects.
;;
;; The PNG decode (inflate + unfilter every row up to the sampled y,
;; across the full window width) is pure-bb and cost ~8us/byte in local
;; measurement -- at the default 1280x800 window a single sample near
;; the bottom of the screen took over 30s to decode. That's slow enough
;; on its own to blow run-all.sh's 30s per-suite timeout (#132), and
;; multiplies with every extra sample. Two mitigations, both needed:
;;  1. Shrink the window before these tests -- decode cost scales with
;;     (window width) * (rows up to the deepest sampled y), and this
;;     app's vbox of images doesn't need 1280x800 for that. 140x480 was
;;     checked against a live /frames dump: it's wide enough that every
;;     sampled element keeps its expected rect (:fit :stretch/:stretch-x/
;;     :stretch-y all render correctly at this width) and tall enough to
;;     keep every sample on-screen (deepest is :sprite-stretch-y's rect,
;;     bottom edge at y=446); measured single-decode cost there is ~2.2s
;;     vs. ~6.4s at 420x480 and >30s at 1280x800.
;;  2. Batch all of a test's samples into a single `screenshot-pixels`
;;     call so each test does exactly one screenshot and one decode.

(defn- red-dominant? [[r _g b]] (and (> r 150) (> (- r b) 60)))
(defn- blue-dominant? [[r _g b]] (and (> b 150) (> (- b r) 60)))
(defn- letterbox? [px] (and (not (red-dominant? px)) (not (blue-dominant? px))))

;; This file's earlier tests rely on the default 1280x800 window (e.g. the
;; vbox stretching cross-axis to fill its width); nothing after this point
;; does, and these are the last tests in the file, so there's no need to
;; resize back.
(resize! 140 480)

(deftest sprite-stretch-shows-texture-content
  ;; :sprite is :fit :stretch (64x64): the whole rect is the texture, no
  ;; letterboxing. Sample at 1/4 and 3/4 height, mid-width, to land well
  ;; inside the top/bottom halves and away from the point-filter seam.
  (dispatch ["event/reset"])
  (wait-ms 400)
  (let [r   (rect-of (find-element {:tag :image :id :sprite}))
        _   (assert r "sprite image must have a rect")
        png (screenshot)
        mx  (int (+ (:x r) (/ (:w r) 2)))
        top-y (int (+ (:y r) (* 0.25 (:h r))))
        bot-y (int (+ (:y r) (* 0.75 (:h r))))
        [top-px bot-px] (screenshot-pixels png [[mx top-y] [mx bot-y]])]
    (assert (red-dominant? top-px)
            (str "top-center of :stretch sprite should be red-dominant; got " top-px))
    (assert (blue-dominant? bot-px)
            (str "bottom-center of :stretch sprite should be blue-dominant; got " bot-px))))

(deftest sprite-stretch-x-letterboxes-top-and-bottom
  ;; rect 32x64: dest is 32x32 (width-fit, square asset), centered
  ;; vertically -> 16px letterbox bands top and bottom, texture in the
  ;; middle 32px (top 16 red, bottom 16 blue).
  (let [r  (rect-of (find-element {:tag :image :id :sprite-stretch-x}))
        _  (assert r "sprite-stretch-x image must have a rect")
        png (screenshot)
        mx  (int (+ (:x r) (/ (:w r) 2)))
        pad-top-y (int (+ (:y r) 8))
        red-y     (int (+ (:y r) 24))
        blue-y    (int (+ (:y r) 40))
        pad-bot-y (int (+ (:y r) 56))
        [pad-top-px red-px blue-px pad-bot-px]
        (screenshot-pixels png [[mx pad-top-y] [mx red-y] [mx blue-y] [mx pad-bot-y]])]
    (assert (letterbox? pad-top-px)
            "top letterbox band should not be texture-colored")
    (assert (red-dominant? red-px)
            "stretch-x texture band (upper) should be red-dominant")
    (assert (blue-dominant? blue-px)
            "stretch-x texture band (lower) should be blue-dominant")
    (assert (letterbox? pad-bot-px)
            "bottom letterbox band should not be texture-colored")))

(deftest sprite-stretch-y-letterboxes-left-and-right
  ;; rect 64x32: dest is 32x32 (height-fit, square asset), centered
  ;; horizontally -> 16px letterbox bands left and right, texture in the
  ;; middle 32px (top half red, bottom half blue).
  (let [r  (rect-of (find-element {:tag :image :id :sprite-stretch-y}))
        _  (assert r "sprite-stretch-y image must have a rect")
        png (screenshot)
        my  (int (+ (:y r) (/ (:h r) 2)))
        pad-left-x  (int (+ (:x r) 8))
        red-x       (int (+ (:x r) 32))
        pad-right-x (int (+ (:x r) 56))
        red-y  (int (+ (:y r) 8))
        blue-y (int (+ (:y r) 24))
        [pad-left-px red-px blue-px pad-right-px]
        (screenshot-pixels png [[pad-left-x my] [red-x red-y] [red-x blue-y] [pad-right-x my]])]
    (assert (letterbox? pad-left-px)
            "left letterbox band should not be texture-colored")
    (assert (red-dominant? red-px)
            "stretch-y texture band (top) should be red-dominant")
    (assert (blue-dominant? blue-px)
            "stretch-y texture band (bottom) should be blue-dominant")
    (assert (letterbox? pad-right-px)
            "right letterbox band should not be texture-colored")))
