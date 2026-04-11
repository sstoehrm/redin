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
