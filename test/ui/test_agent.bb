(require '[redin-test :refer :all]
         '[babashka.http-client :as http]
         '[cheshire.core :as json])

(when-not (agent-supported?)
  (println "[skip] /agent/* not compiled in (need -define:REDIN_AGENT=true)")
  (System/exit 0))

;; -- Discovery --

(deftest agent-nodes-discovers-tagged-nodes
  (let [nodes (agent-nodes)
        ids (set (map :id nodes))]
    (assert (contains? ids "reply")       "reply present")
    (assert (contains? ids "user-input")  "user-input present")
    (assert (contains? ids "ro-text")     "ro-text present")
    (assert (contains? ids "region")      "region present")
    (assert (contains? ids "ro-button")   "ro-button present")))

(deftest agent-nodes-marks-modes
  (let [nodes (agent-nodes)
        by-id (into {} (map (juxt :id :mode) nodes))]
    (assert (= "edit" (by-id "reply"))      "reply is :edit")
    (assert (= "read" (by-id "user-input")) "user-input is :read")
    (assert (= "edit" (by-id "region"))     "region is :edit")
    (assert (= "read" (by-id "ro-text"))    "ro-text is :read")
    (assert (= "read" (by-id "ro-button"))  "ro-button is :read")))

;; -- GET --

(deftest agent-get-text
  (let [r (agent-get-content :reply)]
    (assert (= "default-reply" (:content r))
            (str "expected default-reply, got " (:content r)))))

(deftest agent-get-button-label
  (let [r (agent-get-content :ro-button)]
    (assert (= "click me" (:content r))
            (str "expected click me, got " (:content r)))))

(deftest agent-get-input-value
  (dispatch ["event/typed" {:value "abc"}])
  (wait-ms 100)
  (let [r (agent-get-content :user-input)]
    (assert (= "abc" (:content r)) (str "got " (:content r)))))

(deftest agent-get-missing-id-404
  (let [resp (http/get (str (base-url) "/agent/content/no-such")
                       {:headers (auth-headers) :throw false})]
    (assert (= 404 (:status resp)) (str "expected 404, got " (:status resp)))))

;; -- PUT --

(deftest agent-put-text-replaces-content
  (let [resp (agent-put-content :reply {:content "from-agent"})]
    (assert (= 200 (:status resp))
            (str "expected 200, got " (:status resp))))
  (wait-ms 200)
  ;; Verify by reading back through the GET endpoint.
  (let [r (agent-get-content :reply)]
    (assert (= "from-agent" (:content r))
            (str "expected from-agent, got " (:content r)))))

(deftest agent-put-read-mode-403
  (let [resp (agent-put-content :user-input {:content "x"})]
    (assert (= 403 (:status resp))
            (str "expected 403, got " (:status resp)))))

(deftest agent-put-wrong-shape-400
  (let [resp (agent-put-content :reply {:content [1 2]})]
    (assert (= 400 (:status resp))
            (str "expected 400 for array body to text node, got " (:status resp)))))

(deftest agent-put-container-replaces-children
  (let [resp (agent-put-content :region
               {:content [["text" {} "agent-row-1"]
                          ["text" {} "agent-row-2"]]})]
    (assert (= 200 (:status resp))))
  (wait-ms 200)
  ;; Verify in /frames that the region's children include the new texts.
  (let [frame-json (get-json "/frames")
        flat (pr-str frame-json)]
    (assert (re-find #"agent-row-1" flat) "region should now contain agent-row-1")
    (assert (re-find #"agent-row-2" flat) "region should now contain agent-row-2")))
