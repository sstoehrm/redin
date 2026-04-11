(require '[redin-test :refer :all])

;; -- Initial state: popouts closed --

(deftest popouts-start-closed
  (dispatch ["event/reset"])
  (wait-ms 200)
  (assert-no-element {:tag :popout :id :tooltip} "Tooltip should not exist")
  (assert-no-element {:tag :popout :id :menu} "Menu should not exist"))

(deftest background-elements-exist
  (assert-element {:tag :text :id :title :text "Popout Test"})
  (assert-element {:tag :button :id :tooltip-btn})
  (assert-element {:tag :button :id :menu-btn}))

;; -- Tooltip popout --

(deftest open-tooltip
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/toggle-tooltip"])
  (wait-ms 200)
  (assert-element {:tag :popout :id :tooltip} "Tooltip should appear"))

(deftest tooltip-has-content
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/toggle-tooltip"])
  (wait-ms 200)
  (assert-element {:tag :text :id :tooltip-text :text "This is a tooltip"}))

(deftest tooltip-has-aspect
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/toggle-tooltip"])
  (wait-ms 200)
  (let [el (find-element {:tag :popout :id :tooltip})
        attrs (second el)]
    (assert (= "tooltip" (name (:aspect attrs))) "Should have :tooltip aspect")))

(deftest tooltip-has-fixed-mode
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/toggle-tooltip"])
  (wait-ms 200)
  (let [el (find-element {:tag :popout :id :tooltip})
        attrs (second el)]
    (assert (= "fixed" (name (:mode attrs))) "Should have fixed mode")
    (assert (= 50 (:x attrs)) "x should be 50")
    (assert (= 200 (:y attrs)) "y should be 200")))

(deftest close-tooltip
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/toggle-tooltip"])
  (wait-ms 200)
  (dispatch ["event/toggle-tooltip"])
  (wait-ms 200)
  (assert-no-element {:tag :popout :id :tooltip} "Tooltip should close"))

;; -- Menu popout --

(deftest open-menu
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/toggle-menu"])
  (wait-ms 200)
  (assert-element {:tag :popout :id :menu} "Menu should appear"))

(deftest menu-has-items
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/toggle-menu"])
  (wait-ms 200)
  (assert-element {:tag :button :id :menu-item-1})
  (assert-element {:tag :button :id :menu-item-2})
  (assert-element {:tag :button :id :menu-item-3}))

(deftest select-menu-item-closes-menu
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/toggle-menu"])
  (wait-ms 200)
  (dispatch ["event/select" "beta"])
  (wait-for (state= "selected" "beta") {:timeout 2000})
  (assert-state "menu-open" false? "Menu should close after select")
  (assert-no-element {:tag :popout :id :menu}))

(deftest select-updates-display
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/select" "gamma"])
  (wait-ms 200)
  (assert-element {:tag :text :id :selected-val :text "selected:gamma"}))

;; -- Both popouts independent --

(deftest tooltip-and-menu-independent
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/toggle-tooltip"])
  (wait-ms 200)
  (dispatch ["event/toggle-menu"])
  (wait-ms 200)
  (assert-element {:tag :popout :id :tooltip} "Both should be open")
  (assert-element {:tag :popout :id :menu} "Both should be open"))

;; -- Reset --

(deftest reset-clears-all
  (dispatch ["event/toggle-tooltip"])
  (wait-ms 100)
  (dispatch ["event/toggle-menu"])
  (wait-ms 100)
  (dispatch ["event/select" "alpha"])
  (wait-ms 100)
  (dispatch ["event/reset"])
  (wait-ms 200)
  (assert-no-element {:tag :popout :id :tooltip})
  (assert-no-element {:tag :popout :id :menu})
  (assert-state "selected" #(= % "") "Selected should be empty"))
