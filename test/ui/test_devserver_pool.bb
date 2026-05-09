;; Integration test for the dev-server handler pool (#129 H8).
;;
;; Opens three TCP connections that send a partial HTTP request and
;; never finish the headers. With the old single-thread design the
;; first stalled connection would hold the loop until its 30s
;; deadline, blocking every other client. With the acceptor +
;; 4-handler pool, three stalled connections still leave one
;; handler free, so a fourth normal request must complete promptly.

(require '[redin-test :refer :all]
         '[babashka.http-client :as http])

(deftest pool-allows-concurrent-requests-while-others-stall
  (let [port  (read-port-file)
        token (read-token-file)]
    (assert port  "expected .redin-port to be present")
    (assert token "expected .redin-token to be present")
    (let [stalled (doall
                    (for [_ (range 3)]
                      (let [s (java.net.Socket. "127.0.0.1" port)]
                        (.write (.getOutputStream s)
                                (.getBytes "GET /state HTTP/1.1\r\n"))
                        (.flush (.getOutputStream s))
                        s)))]
      (try
        ;; Give the acceptor a moment to enqueue all three stalled conns
        ;; and three handlers a moment to pick them up.
        (Thread/sleep 200)
        (let [start (System/currentTimeMillis)
              resp  (http/get (str "http://localhost:" port "/state")
                              {:headers {"Authorization" (str "Bearer " token)}
                               :timeout 5000})
              took  (- (System/currentTimeMillis) start)]
          (assert (= 200 (:status resp))
                  (str "fourth request returned " (:status resp)
                       ", expected 200"))
          (assert (< took 2000)
                  (str "fourth request took " took
                       "ms (>2s) — handler pool is not active")))
        (finally
          (doseq [s stalled]
            (try (.close s) (catch Exception _))))))))
