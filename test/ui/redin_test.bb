#!/usr/bin/env bb
;; redin UI test library
;; HTTP-based connection, steer functions, frame queries, assertions,
;; polling-based waits, and a test runner DSL for the redin dev server.

(ns redin-test
  (:require [babashka.http-client :as http]
            [cheshire.core :as json]
            [clojure.string :as str]))

(defn read-port-file
  "Read the dev server port from ./.redin-port if it exists."
  []
  (let [f (clojure.java.io/file ".redin-port")]
    (when (.isFile f) (some-> (slurp f) str/trim parse-long))))

;; ---------------------------------------------------------------------------
;; Connection state
;; ---------------------------------------------------------------------------

(def conn (atom nil))

(defn- base-url []
  (or (:base-url @conn) "http://localhost:8800"))

;; ---------------------------------------------------------------------------
;; Connection management
;; ---------------------------------------------------------------------------

(defn connect!
  "Open HTTP connection to the dev server.
   Port defaults to ./.redin-port if present, else 8800."
  ([] (connect! {}))
  ([{:keys [host port] :or {host "localhost"}}]
   (let [port (or port (read-port-file) 8800)
         base (str "http://" host ":" port)]
     (reset! conn {:base-url base})
     @conn)))

(defn disconnect!
  "Reset connection state."
  []
  (reset! conn nil))

;; ---------------------------------------------------------------------------
;; HTTP helpers
;; ---------------------------------------------------------------------------

(defn- get-json [path]
  (let [resp (http/get (str (base-url) path)
                       {:headers {"Accept" "application/json"}})]
    (json/parse-string (:body resp) true)))

(defn- post-json [path body]
  (let [resp (http/post (str (base-url) path)
                        {:headers {"Content-Type" "application/json"
                                   "Accept" "application/json"}
                         :body (json/generate-string body)})]
    (json/parse-string (:body resp) true)))

(defn- put-json [path body]
  (let [resp (http/put (str (base-url) path)
                       {:headers {"Content-Type" "application/json"
                                  "Accept" "application/json"}
                        :body (json/generate-string body)})]
    (json/parse-string (:body resp) true)))

;; ---------------------------------------------------------------------------
;; Steer functions (drive the app)
;; ---------------------------------------------------------------------------

(defn dispatch
  "Dispatch an event to the app via POST /events."
  [event]
  (post-json "/events" event))

(defn click
  "Simulate a click at (x, y) via POST /click."
  [x y]
  (post-json "/click" {:x x :y y}))

(defn set-theme
  "Replace the theme via PUT /aspects."
  [theme]
  (put-json "/aspects" theme))

(defn resize!
  "Resize the application window via POST /resize."
  [width height]
  (post-json "/resize" {:width width :height height})
  ;; Give the renderer a couple frames to pick up the new size.
  (Thread/sleep 100))

(defn shutdown!
  "Send shutdown event and disconnect."
  []
  (try (post-json "/shutdown" {}) (catch Exception _))
  (disconnect!))

;; ---------------------------------------------------------------------------
;; Query functions (read app state)
;; ---------------------------------------------------------------------------

(defn get-frame
  "Fetch the last pushed frame tree via GET /frames."
  []
  (let [resp (get-json "/frames")]
    (if (map? resp) (:frame resp) (vec resp))))

(defn get-state
  "Fetch app state. Optional path for nested access."
  ([] (get-json "/state"))
  ([path] (get-json (str "/state/" path))))

(defn get-theme
  "Fetch the active theme via GET /aspects."
  []
  (get-json "/aspects"))

;; ---------------------------------------------------------------------------
;; Frame tree walking
;; ---------------------------------------------------------------------------

(defn- frame-tag [node]
  (when (and (vector? node) (pos? (count node)))
    (first node)))

(defn- frame-attrs [node]
  (when (and (vector? node) (> (count node) 1))
    (second node)))

(defn- frame-children [node]
  (when (and (vector? node) (> (count node) 2))
    (subvec node 2)))

(defn- text-content [node]
  (when (and (= "text" (frame-tag node))
             (> (count node) 2))
    (last node)))

(defn- matches-criteria? [node criteria]
  (let [tag (frame-tag node)
        attrs (frame-attrs node)]
    (and
     tag attrs
     (if-let [t (:tag criteria)]
       (= (name t) (if (keyword? tag) (name tag) (str tag)))
       true)
     (if-let [id (:id criteria)]
       (= (name id) (if-let [a (:id attrs)]
                       (if (keyword? a) (name a) (str a))
                       nil))
       true)
     (if-let [asp (:aspect criteria)]
       (let [node-asp (:aspect attrs)
             asp-name (name asp)]
         (cond
           (nil? node-asp) false
           (string? node-asp) (= asp-name node-asp)
           (keyword? node-asp) (= asp-name (name node-asp))
           (sequential? node-asp) (some #(= asp-name (if (keyword? %) (name %) (str %))) node-asp)
           :else false))
       true)
     (if-let [txt (:text criteria)]
       (if (string? txt)
         (= txt (text-content node))
         (when-let [tc (text-content node)]
           (re-find txt tc)))
       true)
     (if (contains? criteria :visible)
       (let [v (:visible criteria)
             node-v (get attrs :visible true)]
         (= v node-v))
       true)
     (if-let [attr-criteria (:attrs criteria)]
       (every? (fn [[k v]] (= v (get attrs k))) attr-criteria)
       true))))

(defn- walk-frame [node criteria acc]
  (when (and (vector? node) (pos? (count node)))
    (when (matches-criteria? node criteria)
      (swap! acc conj node))
    (when-let [children (frame-children node)]
      (doseq [child children]
        (when (vector? child)
          (walk-frame child criteria acc))))))

(defn find-elements
  "Find all elements in the frame tree matching the criteria map."
  ([criteria] (find-elements (get-frame) criteria))
  ([frame criteria]
   (let [acc (atom [])]
     (walk-frame frame criteria acc)
     @acc)))

(defn find-element
  "Find the first element matching criteria."
  ([criteria] (find-element (get-frame) criteria))
  ([frame criteria]
   (first (find-elements frame criteria))))

;; ---------------------------------------------------------------------------
;; Assertions
;; ---------------------------------------------------------------------------

(defn assert-element
  "Assert that an element matching criteria exists."
  ([criteria] (assert-element criteria nil))
  ([criteria message]
   (when-not (find-element criteria)
     (throw (ex-info (or message (str "Expected element matching " (pr-str criteria) " but none found"))
                     {:type :assertion-failure :criteria criteria})))))

(defn assert-no-element
  "Assert that no element matching criteria exists."
  ([criteria] (assert-no-element criteria nil))
  ([criteria message]
   (when-let [found (find-element criteria)]
     (throw (ex-info (or message (str "Expected no element matching " (pr-str criteria) " but found: " (pr-str found)))
                     {:type :assertion-failure :criteria criteria :found found})))))

(defn assert-state
  "Assert a predicate on the app state."
  ([pred] (assert-state nil pred nil))
  ([path pred] (assert-state path pred nil))
  ([path pred message]
   (let [state (if path (get-state path) (get-state))]
     (when-not (pred state)
       (throw (ex-info (or message (str "State assertion failed"
                                        (when path (str " at '" path "'"))
                                        ". Value: " (pr-str state)))
                       {:type :assertion-failure :path path :value state}))))))

;; ---------------------------------------------------------------------------
;; Polling-based wait
;; ---------------------------------------------------------------------------

(defn wait-for
  "Wait for a condition to be satisfied by polling. Checks every 50ms."
  ([condition] (wait-for condition {}))
  ([condition {:keys [timeout interval] :or {timeout 5000 interval 50}}]
   (let [start (System/currentTimeMillis)
         check-fn (:check-fn condition)]
     (loop []
       (if (try (check-fn) (catch Exception _ false))
         nil
         (if (> (- (System/currentTimeMillis) start) timeout)
           (throw (ex-info (str "Timed out waiting for: " (:desc condition) " (after " timeout "ms)")
                           {:type :timeout :condition condition}))
           (do (Thread/sleep interval) (recur))))))))

(defn state=
  "Create a wait condition that checks state at path equals expected."
  [path expected]
  {:desc (str "state at '" path "' = " (pr-str expected))
   :check-fn (fn []
               (let [v (if path (get-state path) (get-state))]
                 (= v expected)))})

(defn state-pred
  "Create a wait condition that checks a predicate against state."
  ([pred desc] (state-pred nil pred desc))
  ([path pred desc]
   {:desc (or desc (str "state predicate at '" path "'"))
    :check-fn (fn []
                (let [v (if path (get-state path) (get-state))]
                  (pred v)))}))

(defn element-exists?
  "Create a wait condition for an element to appear."
  [criteria]
  {:desc (str "element exists: " (pr-str criteria))
   :check-fn (fn [] (some? (find-element criteria)))})

(defn no-element?
  "Create a wait condition for an element to disappear."
  [criteria]
  {:desc (str "no element: " (pr-str criteria))
   :check-fn (fn [] (empty? (find-elements criteria)))})

;; ---------------------------------------------------------------------------
;; Test runner DSL
;; ---------------------------------------------------------------------------

(def ^:private tests (atom []))

(defn reset-tests! [] (reset! tests []))

(defmacro deftest [test-name & body]
  `(swap! tests conj {:name ~(str test-name)
                       :fn (fn [] ~@body)}))

(defn run-tests!
  ([] (run-tests! {}))
  ([{:keys [stop-on-fail?] :or {stop-on-fail? false}}]
   (let [results (atom {:passed 0 :failed 0 :errors []})]
     (doseq [{:keys [name fn]} @tests]
       (print (str "  " name "... "))
       (flush)
       (try
         (fn)
         (println "PASS")
         (swap! results update :passed inc)
         (catch Exception e
           (println "FAIL")
           (println (str "    " (.getMessage e)))
           (swap! results update :failed inc)
           (swap! results update :errors conj {:test name :error e})
           (when stop-on-fail?
             (println "\nStopping on first failure.")
             (reduced nil)))))
     (let [{:keys [passed failed]} @results]
       (println)
       (println (str "Results: " passed " passed, " failed " failed, " (+ passed failed) " total"))
       @results))))

;; ---------------------------------------------------------------------------
;; Convenience
;; ---------------------------------------------------------------------------

(defn screenshot
  "Save a screenshot to the given path."
  ([] (screenshot nil))
  ([path]
   (let [resp (http/get (str (base-url) "/screenshot") {:as :bytes})]
     (when path
       (with-open [out (java.io.FileOutputStream. path)]
         (.write out ^bytes (:body resp))))
     (:body resp))))

(defn wait-ms
  "Sleep for n milliseconds. Prefer wait-for."
  [ms]
  (Thread/sleep ms))

(println "redin-test library loaded")
