(require '[redin-test :refer :all]
         '[babashka.http-client :as http]
         '[cheshire.core :as json]
         '[clojure.string :as str])

;; Verifies the JSON codec depth cap + cycle detection land from #46:
;;   - Deeply-nested request bodies must not crash the host (H1).
;;   - Cyclic Lua tables must not crash the host on /state readback (H2).
;; Uses the smoke app — which exposes redin_get_state — so /state is live.

(defn- auth-header []
  (if-let [t (read-token-file)]
    {"Authorization" (str "Bearer " t)}
    {}))

(defn- post-raw [path body-str]
  (http/post (str (base-url) path)
             {:throw false
              :headers (merge {"Content-Type" "application/json"} (auth-header))
              :body body-str}))

(deftest deeply-nested-request-body-rejected-not-crash
  ;; 1000 nested arrays — pre-fix this blew the native stack. After
  ;; #46, the decoder caps at MAX_JSON_DEPTH (128) and /events
  ;; returns 400.
  (let [deep (str (str/join (repeat 1000 "["))
                  (str/join (repeat 1000 "]")))
        resp (post-raw "/events" deep)]
    (assert (= 400 (:status resp))
            (str "Expected 400 for over-deep body, got " (:status resp))))
  ;; Server must still be responsive after the rejection.
  (let [resp (http/get (str (base-url) "/state")
                       {:throw false :headers (auth-header)})]
    (assert (= 200 (:status resp))
            (str "Server unreachable after deeply-nested POST, got " (:status resp)))))

(deftest decoder-accepts-depth-at-cap
  ;; Depth exactly 128 should still decode — cap is inclusive.
  (let [shallow (str (str/join (repeat 128 "["))
                     (str/join (repeat 128 "]")))
        resp (post-raw "/events" shallow)]
    ;; Either 200 (if an event/1000-level-deep handler exists, which
    ;; it doesn't) or 500 (handler not registered) — but never 400,
    ;; since 400 means the decoder rejected it.
    (assert (not= 400 (:status resp))
            (str "Depth-128 body wrongly rejected by decoder, got 400"))))

(deftest cyclic-lua-table-does-not-crash-state-encoding
  ;; Ask Fennel to install a cyclic table as the app db. `_get-raw-db`
  ;; returns the db; dataflow.set-db replaces it.
  (dispatch ["event/install-cycle"])
  (wait-ms 200)
  ;; /state must return 200 and valid JSON (cycles → null).
  (let [resp (http/get (str (base-url) "/state")
                       {:throw false :headers (auth-header)})]
    (assert (= 200 (:status resp)))
    (assert (json/parse-string (:body resp) true)
            "Response body should parse as JSON")))
