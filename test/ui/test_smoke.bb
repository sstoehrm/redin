(require '[redin-test :refer :all]
         '[babashka.http-client :as http]
         '[cheshire.core :as json]
         '[clojure.string :as str])

(defn- click-status
  "POST /click with the given JSON body, return the HTTP status code.
   Used by the /click validation regression tests for issue #78 L2 —
   redin-test/click hides the status."
  [body]
  (let [port  (slurp ".redin-port")
        token (str/trim (slurp ".redin-token"))
        resp  (http/post (str "http://localhost:" (str/trim port) "/click")
                         {:headers {"Content-Type" "application/json"
                                    "Authorization" (str "Bearer " token)}
                          :body (json/generate-string body)
                          :throw false})]
    (:status resp)))

(deftest inspect-frame
  (let [frame (get-frame)]
    (assert (some? frame) "Frame should not be nil")))

(deftest inspect-state
  (let [state (get-state)]
    (assert (some? state) "State should not be nil")))

(deftest inspect-theme
  (let [theme (get-theme)]
    (assert (some? theme) "Theme should not be nil")
    (assert (some? (:heading theme)) "Theme should have :heading aspect")))

(deftest dispatch-and-assert-state
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/inc"])
  (wait-ms 200)
  (assert-state "counter" #(= % 1)))

(deftest dispatch-multiple
  (dispatch ["event/reset"])
  (wait-ms 200)
  (dispatch ["event/inc"])
  (dispatch ["event/inc"])
  (dispatch ["event/inc"])
  (wait-ms 200)
  (assert-state "counter" #(= % 3)))

(deftest set-message-and-assert
  (dispatch ["event/set-message" "world"])
  (wait-ms 200)
  (assert-state "message" #(= % "world"))
  (dispatch ["event/reset"]))

(deftest state-path-access
  (dispatch ["event/reset"])
  (wait-ms 200)
  (let [counter (get-state "counter")]
    (assert (= counter 0) "Counter should be 0 after reset")))

(deftest wait-for-state-change
  (dispatch ["event/reset"])
  (wait-ms 100)
  (dispatch ["event/inc"])
  (wait-for (state= "counter" 1) {:timeout 2000}))

;; Issue #78 L2: /click previously accepted any (x,y) including
;; out-of-window values. /resize already validates and returns 400;
;; /click must do the same. NaN/Infinity rejection is also part of the
;; fix but isn't reachable through JSON (the literals aren't valid JSON
;; and cheshire-encoded strings get coerced to 0 by lua_tonumber), so
;; only the reachable cases are exercised here.

(deftest click-rejects-negative
  (assert (= 400 (click-status {:x -10 :y 100}))
          "Negative x must be rejected with 400"))

(deftest click-rejects-out-of-bounds
  (assert (= 400 (click-status {:x 99999 :y 100}))
          "x past the screen width must be rejected with 400"))

(deftest click-accepts-valid-coords
  (assert (= 200 (click-status {:x 10 :y 10}))
          "Valid in-bounds coordinates must still succeed"))
