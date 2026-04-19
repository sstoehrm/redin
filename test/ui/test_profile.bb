(require '[redin-test :refer :all]
         '[cheshire.core :as json]
         '[babashka.http-client :as http])

(defn get-profile []
  (let [port (slurp ".redin-port")
        resp (http/get (str "http://localhost:" (clojure.string/trim port) "/profile")
                       {:throw false})]
    {:status (:status resp)
     :body   (when (= 200 (:status resp)) (json/parse-string (:body resp) true))}))

(deftest profile-enabled-shape
  (let [{:keys [status body]} (get-profile)]
    (assert (= 200 status) (str "expected 200, got " status))
    (assert (true? (:enabled body)) ":enabled should be true")
    (assert (= 120 (:frame_cap body)) ":frame_cap should be 120")
    (assert (= ["input" "bridge" "layout" "render" "devserver"]
               (:phases body))
            (str ":phases should match spec, got " (:phases body)))))

(deftest profile-count-grows
  ;; Wait until the ring fills.
  (wait-for {:desc "profile ring fills to 120 frames"
             :check-fn (fn [] (= 120 (:count (:body (get-profile)))))}
            {:timeout 4000})
  (let [body (:body (get-profile))]
    (assert (= 120 (:count body)))
    (assert (= 120 (count (:frames body))))))

(deftest profile-phase-sums-bounded-by-total
  ;; Phase sums must never exceed total frame time (modulo 10% timer slack).
  ;; Lower bound is not meaningful: with vsync the frame total is dominated
  ;; by the wait between frames, which is not attributed to any phase.
  (let [body (:body (get-profile))]
    (doseq [frame (:frames body)]
      (let [total (:total_us frame)
            phase-sum (apply + (:phase_us frame))]
        (when (> total 100) ;; ignore frames under 100 µs (timer noise)
          (assert (<= phase-sum (* 1.1 total))
                  (str "phase sum " phase-sum " exceeds total " total
                       " by more than 10% slack")))))))
