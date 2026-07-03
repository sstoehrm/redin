(local dataflow (require :dataflow))
(local agent    (require :agent))

(local t {})

(fn t.test-handler-stores-content []
  (dataflow.init {})
  (agent.install)
  (dataflow.dispatch [:event/agent-edit {:id :reply :content "hello"}])
  (dataflow.flush)
  (assert (= "hello" (. (dataflow.get-state) :agent :reply))
          "agent.reply should be 'hello' after :event/agent-edit"))

(fn t.test-apply-overrides-text []
  (dataflow.init {:agent {:reply "actual"}})
  (let [tree [:text {:id :reply :agent :edit} "..."]
        out  (agent.apply-overrides tree)]
    (assert (= "actual" (. out 3))
            "text content should be replaced when db.agent.reply present")))

(fn t.test-apply-overrides-falls-through []
  (dataflow.init {})
  (let [tree [:text {:id :reply :agent :edit} "fallback"]
        out  (agent.apply-overrides tree)]
    (assert (= "fallback" (. out 3))
            "text content should fall through when db.agent.reply missing")))

(fn t.test-apply-overrides-input-value []
  (dataflow.init {:agent {:user-input "typed"}})
  (let [tree [:input {:id :user-input :agent :edit :value "x"}]
        out  (agent.apply-overrides tree)
        attrs (. out 2)]
    (assert (= "typed" (. attrs :value))
            "input :value should be replaced when db.agent.user-input present")))

(fn t.test-apply-overrides-container-children []
  (dataflow.init {:agent {:cards [[:text {} "from agent"]]}})
  (let [tree [:vbox {:id :cards :agent :edit}
                [:text {} "literal child"]]
        out  (agent.apply-overrides tree)]
    (assert (= "from agent" (. (. out 3) 3))
            "vbox children should be replaced when db.agent.cards present")))

(fn t.test-apply-overrides-recurses []
  (dataflow.init {:agent {:reply "deep"}})
  (let [tree [:vbox {}
                [:text {:id :reply :agent :edit} "..."]]
        out  (agent.apply-overrides tree)
        text-node (. out 3)]
    (assert (= "deep" (. text-node 3))
            "deeply-nested :agent :edit text should be overridden")))

(fn t.test-read-mode-no-override []
  (dataflow.init {:agent {:reply "ignored"}})
  (let [tree [:text {:id :reply :agent :read} "literal"]
        out  (agent.apply-overrides tree)]
    (assert (= "literal" (. out 3))
            ":agent :read must not override content")))

;; #225 M2: a malformed agent override (wrong type for the target node)
;; must not crash rendering or corrupt the node. Reachable via
;; `POST /events ["event/agent-edit" {:id ... :content <bad>}]`.

(fn t.test-handle-edit-rejects-non-string-non-table-content []
  (dataflow.init {})
  (agent.install)
  (dataflow.dispatch [:event/agent-edit {:id :reply :content 42}])
  (dataflow.flush)
  (assert (= nil (?. (dataflow.get-state) :agent :reply))
          "non-string/non-table content must be rejected, not stored"))

(fn t.test-container-override-non-table-no-crash []
  ;; A container whose override is a scalar used to raise ipairs(42) every
  ;; frame. Now it must leave the node's literal children intact.
  (dataflow.init {:agent {:cards 42}})
  (let [tree [:vbox {:id :cards :agent :edit}
                [:text {} "literal child"]]
        out  (agent.apply-overrides tree)]
    (assert (= "literal child" (. (. out 3) 3))
            "malformed container override must leave literal children intact")))

(fn t.test-leaf-override-non-string-ignored []
  ;; A leaf text node whose override is a table (container-shaped) must not
  ;; have the table spliced into its text slot.
  (dataflow.init {:agent {:reply [[:text {} "x"]]}})
  (let [tree [:text {:id :reply :agent :edit} "keep"]
        out  (agent.apply-overrides tree)]
    (assert (= "keep" (. out 3))
            "non-string override for a leaf text node must be ignored")))

t
