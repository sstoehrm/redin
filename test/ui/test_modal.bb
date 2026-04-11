(require '[redin-test :refer :all])

;; -- Initial state: modal closed --

(deftest modal-starts-closed
  (dispatch ["event/reset"])
  (wait-ms 200)
  (assert-state "modal-open" false? "Modal should start closed")
  (assert-no-element {:tag :modal} "Modal element should not exist when closed"))

(deftest background-elements-exist
  (assert-element {:tag :text :id :title :text "Modal Test"})
  (assert-element {:tag :button :id :open-btn})
  (assert-element {:tag :button :id :bg-btn}))

;; -- Opening modal --

(deftest open-modal-shows-element
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/open-modal"])
  (wait-ms 200)
  (assert-state "modal-open" true? "State should be open")
  (assert-element {:tag :modal} "Modal element should exist when open"))

(deftest modal-children-visible
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/open-modal"])
  (wait-ms 200)
  (assert-element {:tag :text :id :modal-title :text "Confirm Action"})
  (assert-element {:tag :text :id :modal-body :text "Are you sure?"})
  (assert-element {:tag :button :id :cancel-btn})
  (assert-element {:tag :button :id :confirm-btn}))

(deftest modal-has-overlay-aspect
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/open-modal"])
  (wait-ms 200)
  (let [modal (find-element {:tag :modal})]
    (assert modal "Modal should exist")
    (let [attrs (second modal)]
      (assert (= "overlay" (name (:aspect attrs))) "Modal should have :overlay aspect"))))

;; -- Modal actions --

(deftest confirm-closes-modal
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/open-modal"])
  (wait-ms 200)
  (dispatch ["event/confirm"])
  (wait-for (state= "modal-open" false) {:timeout 2000})
  (assert-state "last-action" #(= % "confirmed") "Action should be confirmed")
  (assert-no-element {:tag :modal} "Modal should be gone after confirm"))

(deftest cancel-closes-modal
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/open-modal"])
  (wait-ms 200)
  (dispatch ["event/cancel"])
  (wait-for (state= "modal-open" false) {:timeout 2000})
  (assert-state "last-action" #(= % "cancelled") "Action should be cancelled")
  (assert-no-element {:tag :modal} "Modal should be gone after cancel"))

;; -- Background interaction while modal open --

(deftest background-button-works-with-modal-open
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/open-modal"])
  (wait-ms 200)
  (dispatch ["event/inc"])
  (wait-for (state= "counter" 1) {:timeout 2000}))

;; -- Reopen after close --

(deftest reopen-modal-after-close
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/open-modal"])
  (wait-ms 200)
  (dispatch ["event/cancel"])
  (wait-ms 200)
  (assert-no-element {:tag :modal})
  (dispatch ["event/open-modal"])
  (wait-ms 200)
  (assert-element {:tag :modal} "Modal should reappear"))

;; -- Reset --

(deftest reset-clears-all
  (dispatch ["event/open-modal"])
  (wait-ms 100)
  (dispatch ["event/inc"])
  (wait-ms 100)
  (dispatch ["event/confirm"])
  (wait-ms 100)
  (dispatch ["event/reset"])
  (wait-for (state= "modal-open" false) {:timeout 2000})
  (assert-state "counter" #(= % 0) "Counter should reset")
  (assert-state "last-action" #(= % "") "Action should reset"))
