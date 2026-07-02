;; agent.fnl -- Agent channel runtime.
;;
;; Stores agent-written content in db.agent[id]. Walks the view-fn's
;; output before flattening to swap content of any node tagged
;; `:agent :edit` (with an `:id`) for the value in db.agent[id], if
;; present. `:agent :read` is observe-only -- no override applied.

(local dataflow (require :dataflow))

(local M {})

(local content-attrs
  ;; For these node tags, agent content goes into a specific attr.
  {:input :value :image :src})

(local container-tags
  {:vbox true :hbox true :stack true :popout true :modal true})

;; Detect a frame-node table: slot 1 is a non-empty string and slot 2 is a table.
(fn vector? [v]
  (and (= (type v) :table)
       (= (type (. v 1)) :string)
       (> (length (. v 1)) 0)
       (= (type (. v 2)) :table)))

;; #225 M2: `event/agent-edit` is an ordinary dispatchable event, so its
;; payload can arrive via `POST /events` bypassing the shape-checking
;; `PUT /agent/content/<id>` handler. Store only a plausibly-valid override
;; -- a string (leaf/input/image content) or a table (container children).
;; Anything else (number, bool) can never match a node and previously
;; persisted, making every subsequent frame's override re-fail.
(fn valid-content? [content]
  (let [tp (type content)]
    (or (= tp :string) (= tp :table))))

(fn handle-edit [db ev]
  (let [payload (. ev 2)
        id (. payload :id)
        content (. payload :content)]
    (if (and (= (type id) :string) (valid-content? content))
        (dataflow.assoc-in db [:agent id] content)
        db)))

(fn M.install []
  (dataflow.reg-handler :event/agent-edit handle-edit))

(fn override-node [node db]
  (when (vector? node)
    (let [tag (. node 1)
          attrs (. node 2)
          id (. attrs :id)
          mode (. attrs :agent)
          override (and id (. (or (. db :agent) {}) id))]
      ;; #225 M2: an override whose type doesn't fit the target node (e.g. a
      ;; scalar for a container, or a table for a leaf) is ignored rather than
      ;; spliced -- guards against `ipairs(<scalar>)` crashing every frame and
      ;; against a table landing in a text slot.
      (if (or (not id) (not= mode :edit) (= override nil))
          node
          (if (. content-attrs tag)
              ;; Swap the named attr (value/src) -- string only.
              (if (= (type override) :string)
                  (let [k (. content-attrs tag)
                        new-attrs (collect [ak av (pairs attrs)] ak av)
                        out (icollect [_ v (ipairs node)] v)]
                    (tset new-attrs k override)
                    (tset out 2 new-attrs)
                    out)
                  node)
              (. container-tags tag)
              ;; Replace children: keep [tag attrs], then splice override (a list).
              (if (= (type override) :table)
                  (let [head [tag attrs]]
                    (each [_ child (ipairs override)]
                      (table.insert head child))
                    head)
                  node)
              ;; Default: leaf text-like node, swap slot 3 -- string only.
              (if (= (type override) :string)
                  (let [out (icollect [_ v (ipairs node)] v)]
                    (tset out 3 override)
                    out)
                  node))))))

;; Recursively apply overrides to a frame tree.
(fn walk [node db]
  (if (vector? node)
      (let [overridden (or (override-node node db) node)
            out [(. overridden 1) (. overridden 2)]]
        (for [i 3 (length overridden)]
          (let [child (. overridden i)]
            (table.insert out
              (if (vector? child)
                  (walk child db)
                  child))))
        out)
      node))

(fn M.apply-overrides [tree]
  (let [db (or (dataflow.get-state) {})]
    (walk tree db)))

M
