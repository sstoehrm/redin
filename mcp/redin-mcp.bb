#!/usr/bin/env bb

(require '[cheshire.core :as json]
         '[babashka.http-client :as http]
         '[clojure.java.io :as io]
         '[clojure.string :as str])

;; ===== Configuration =====

(def dev-server
  (or (System/getenv "REDIN_DEV_SERVER")
      "http://localhost:8800"))

;; ===== JSON-RPC helpers =====

(defn respond [id result]
  (let [msg (json/encode {:jsonrpc "2.0" :id id :result result})]
    (println msg)
    (flush)))

(defn respond-error [id code message]
  (let [msg (json/encode {:jsonrpc "2.0" :id id
                          :error {:code code :message message}})]
    (println msg)
    (flush)))

;; ===== Tool definitions =====

(def tools
  [{:name "inspect"
    :description "Read redin app state. Returns frame tree, app-db state, bindings, or theme aspects."
    :inputSchema {:type "object"
                  :properties {:what {:type "string"
                                      :enum ["frame" "state" "bindings" "aspects" "all"]
                                      :description "What to inspect"}
                               :path {:type "string"
                                      :description "Dot-separated path for state (e.g. 'items.0.text') or element id for frame subtree"}
                               :id {:type "string"
                                    :description "Element id for frame subtree"}}
                  :required ["what"]}}
   {:name "act"
    :description "Interact with a running redin app. Dispatch events, click at coordinates, or inject frames."
    :inputSchema {:type "object"
                  :properties {:action {:type "string"
                                        :enum ["dispatch" "click" "inject" "shutdown" "focus" "type" "input"]
                                        :description "Action type"}
                               :event {:type "array"
                                       :description "Event vector for dispatch, e.g. [\"event/increment\"]"}
                               :x {:type "number" :description "X coordinate for click"}
                               :y {:type "number" :description "Y coordinate for click"}
                               :id {:type "string" :description "Element id for inject/focus/input"}
                               :frame {:type "array" :description "Frame tree for inject"}
                               :text {:type "string" :description "Text to type (for type action)"}
                               :key {:type "string" :description "Special key name (for type action, e.g. enter, backspace)"}
                               :value {:type "string" :description "Value to set (for input action)"}}
                  :required ["action"]}}
   {:name "screenshot"
    :description "Capture the current redin app frame as a PNG screenshot."
    :inputSchema {:type "object" :properties {}}}
   {:name "theme"
    :description "Read or replace the redin app theme."
    :inputSchema {:type "object"
                  :properties {:action {:type "string"
                                        :enum ["read" "write"]
                                        :description "Read current theme or write a new one"}
                               :aspects {:type "object"
                                         :description "Theme aspects table (for write)"}}
                  :required ["action"]}}])

;; ===== Resource definitions =====

(def resources
  [{:uri "redin://docs/quickstart"
    :name "Quickstart Guide"
    :description "Getting started with redin in 5 minutes"
    :mimeType "text/markdown"}
   {:uri "redin://docs/elements"
    :name "Element Reference"
    :description "All 13 element tags with attributes and examples"
    :mimeType "text/markdown"}
   {:uri "redin://docs/theme"
    :name "Theme Reference"
    :description "Aspect system, composition, state variants, built-in themes"
    :mimeType "text/markdown"}
   {:uri "redin://docs/effects"
    :name "Effects Reference"
    :description "Built-in effects, custom effects, timers"
    :mimeType "text/markdown"}
   {:uri "redin://docs/dev-server"
    :name "Dev Server API"
    :description "HTTP/WS endpoints and MCP integration"
    :mimeType "text/markdown"}])

(def resource-file-map
  {"redin://docs/quickstart"  "docs/guide/quickstart.md"
   "redin://docs/elements"    "docs/reference/elements.md"
   "redin://docs/theme"       "docs/reference/theme.md"
   "redin://docs/effects"     "docs/reference/effects.md"
   "redin://docs/dev-server"  "docs/reference/dev-server.md"})

;; ===== HTTP helpers =====

(defn dev-get [path]
  (try
    (let [resp (http/get (str dev-server path)
                         {:headers {"Accept" "application/json"}})]
      (json/decode (:body resp) true))
    (catch Exception e
      {:error (str "Dev server unavailable: " (.getMessage e))})))

(defn dev-post [path body]
  (try
    (let [resp (http/post (str dev-server path)
                          {:headers {"Content-Type" "application/json"}
                           :body (json/encode body)})]
      (json/decode (:body resp) true))
    (catch Exception e
      {:error (str "Dev server unavailable: " (.getMessage e))})))

(defn dev-put [path body]
  (try
    (let [resp (http/put (str dev-server path)
                         {:headers {"Content-Type" "application/json"}
                          :body (json/encode body)})]
      (json/decode (:body resp) true))
    (catch Exception e
      {:error (str "Dev server unavailable: " (.getMessage e))})))

(defn dev-get-binary [path]
  (try
    (let [resp (http/get (str dev-server path)
                         {:as :bytes})]
      (:body resp))
    (catch Exception _e
      nil)))

;; ===== Tool implementations =====

(defn handle-inspect [{:keys [what path id]}]
  (case what
    "frame"    (if id
                 (dev-get (str "/frames/" id))
                 (dev-get "/frames"))
    "state"    (if path
                 (dev-get (str "/state/" path))
                 (dev-get "/state"))
    "bindings" (dev-get "/bindings")
    "aspects"  (dev-get "/aspects")
    "all"      {:frame    (dev-get "/frames")
                :state    (dev-get "/state")
                :bindings (dev-get "/bindings")
                :aspects  (dev-get "/aspects")}
    {:error (str "Unknown inspect target: " what)}))

(defn handle-act [{:keys [action event x y id frame text key value]}]
  (case action
    "dispatch" (dev-post "/events" {:event event})
    "click"    (dev-post "/click" {:x x :y y})
    "inject"   (dev-put (str "/frames/" id) {:frame frame})
    "shutdown" (dev-post "/shutdown" {})
    "focus"    (dev-post "/focus" {:id id})
    "type"     (if text
                 (dev-post "/type" {:text text})
                 (dev-post "/type" {:key key}))
    "input"    (dev-post "/input" {:id id :value value})
    {:error (str "Unknown action: " action)}))

(defn handle-screenshot [_params]
  (let [data (dev-get-binary "/screenshot")]
    (if data
      {:type "image"
       :data (.encodeToString (java.util.Base64/getEncoder) data)}
      {:error "Failed to capture screenshot"})))

(defn handle-theme [{:keys [action aspects]}]
  (case action
    "read"  (dev-get "/aspects")
    "write" (dev-put "/aspects" aspects)
    {:error (str "Unknown theme action: " action)}))

(defn call-tool [name params]
  (case name
    "inspect"    (handle-inspect params)
    "screenshot" (handle-screenshot params)
    "act"        (handle-act params)
    "theme"      (handle-theme params)
    {:error (str "Unknown tool: " name)}))

;; ===== Resource reading =====

(defn read-resource [uri]
  (if-let [file-path (resource-file-map uri)]
    (let [f (io/file file-path)]
      (if (.exists f)
        (slurp f)
        (str "Documentation not yet written. File: " file-path)))
    (str "Unknown resource: " uri)))

;; ===== Message handler =====

(defn handle-message [{:keys [id method params]}]
  (case method
    "initialize"
    (respond id {:protocolVersion "2024-11-05"
                 :capabilities {:tools {}
                                :resources {}}
                 :serverInfo {:name "redin-mcp"
                              :version "0.1.0"}})

    "notifications/initialized"
    nil ;; no response needed for notifications

    "tools/list"
    (respond id {:tools tools})

    "tools/call"
    (let [tool-name (:name params)
          arguments (:arguments params)
          result (call-tool tool-name arguments)]
      (if (:error result)
        (respond id {:content [{:type "text" :text (str "Error: " (:error result))}]
                     :isError true})
        (if (= (:type result) "image")
          (respond id {:content [{:type "image"
                                  :data (:data result)
                                  :mimeType "image/png"}]})
          (respond id {:content [{:type "text"
                                  :text (json/encode result {:pretty true})}]}))))

    "resources/list"
    (respond id {:resources resources})

    "resources/read"
    (let [uri (:uri params)
          content (read-resource uri)]
      (respond id {:contents [{:uri uri
                               :mimeType "text/markdown"
                               :text content}]}))

    ;; Unknown method
    (if id
      (respond-error id -32601 (str "Method not found: " method))
      nil)))

;; ===== Main loop =====

(defn -main []
  (binding [*in* (io/reader System/in)]
    (doseq [line (line-seq *in*)]
      (when-not (str/blank? line)
        (try
          (let [msg (json/decode line true)]
            (handle-message msg))
          (catch Exception e
            (binding [*out* *err*]
              (println "Parse error:" (.getMessage e)))))))))

(-main)
