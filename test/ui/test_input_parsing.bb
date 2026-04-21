(require '[redin-test :refer :all]
         '[babashka.http-client :as http]
         '[cheshire.core :as json]
         '[clojure.string :as str])

;; Covers #49: dev-server input-parsing hardening.
;; - M2: JSON \uXXXX surrogate pairs decode correctly, lone surrogates reject.
;; - M3: /state/<path> uses lua_rawget (no metamethod invocation).
;; - M4: /resize uses proper JSON parse (can't be confused by substring keys).

(defn- auth-header []
  (if-let [t (read-token-file)]
    {"Authorization" (str "Bearer " t)}
    {}))

(defn- post-raw [path body-str]
  (http/post (str (base-url) path)
             {:throw false
              :headers (merge {"Content-Type" "application/json"} (auth-header))
              :body body-str}))

;; ---- M2 ---------------------------------------------------------------

(deftest decoder-accepts-surrogate-pair
  ;; \uD83D\uDE00 (😀) — high + low surrogate must decode to U+1F600.
  ;; The JSON body is a dispatch payload that won't match any handler,
  ;; so we expect 500 (not 400: 400 would mean the decoder rejected it).
  (let [resp (post-raw "/events" "[\"event/does-not-exist\", {\"emoji\":\"\\uD83D\\uDE00\"}]")]
    (assert (not= 400 (:status resp))
            (str "Decoder wrongly rejected surrogate pair, got 400"))))

(deftest decoder-rejects-lone-surrogate
  ;; \uD83D alone (high surrogate, no low) is invalid per RFC 8259 §7.
  (let [resp (post-raw "/events" "[\"event/x\", {\"bad\":\"\\uD83D\"}]")]
    (assert (= 400 (:status resp))
            (str "Expected 400 for lone surrogate, got " (:status resp)))))

;; ---- M3 ---------------------------------------------------------------

(deftest state-path-bypasses-metamethods
  (dispatch ["event/reset"])
  (wait-ms 100)
  (dispatch ["event/install-metatable"])
  (wait-ms 100)
  ;; Probe a key not present on db.plain. Under lua_getfield, __index
  ;; would fire, set tripped=true, and return "tripped". Under
  ;; lua_rawget, __index is bypassed and the result is nil.
  (let [resp (http/get (str (base-url) "/state/plain.absent")
                       {:throw false :headers (auth-header)})]
    (assert (= 200 (:status resp)))
    (assert (= "null" (str/trim (:body resp)))
            (str "Expected null via rawget, got " (:body resp))))
  ;; And verify __index did NOT run.
  (let [resp (http/get (str (base-url) "/state/tripped")
                       {:throw false :headers (auth-header)})]
    (assert (= "false" (str/trim (:body resp)))
            (str "Metamethod fired (tripped=true) — /state/<path> must use rawget"))))

(deftest state-path-rejects-over-long-dot-chain
  ;; 33 segments — over the 32 cap.
  (let [path (str/join "." (repeat 33 "x"))
        resp (http/get (str (base-url) "/state/" path)
                       {:throw false :headers (auth-header)})]
    (assert (= 400 (:status resp))
            (str "Expected 400 for 33-segment path, got " (:status resp)))))

;; ---- M4 ---------------------------------------------------------------

(deftest resize-ignores-substring-match
  ;; `:widthless` would match `strings.index(body, "\"width\"")` under
  ;; the old parser. The real width field must win.
  (let [resp (post-raw "/resize"
              "{\"widthless\":999,\"heightless\":999,\"width\":640,\"height\":480}")]
    (assert (= 200 (:status resp))
            (str "Expected 200 resize, got " (:status resp))))
  ;; Confirm the window is actually 640x480, not 999x999.
  (wait-ms 200)
  (let [resp (http/get (str (base-url) "/window")
                       {:throw false :headers (auth-header)})
        parsed (json/parse-string (:body resp) true)]
    (assert (= 640 (:width parsed)) (str "width=" (:width parsed)))
    (assert (= 480 (:height parsed)) (str "height=" (:height parsed)))))

(deftest resize-rejects-invalid-json
  (let [resp (post-raw "/resize" "not json")]
    (assert (= 400 (:status resp)))))
