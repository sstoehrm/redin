(local dataflow (require :dataflow))

(local t {})

(fn setup []
  (dataflow.reset))

;; --- init ---

(fn t.test-init-returns-db []
  (setup)
  (let [db (dataflow.init {:counter 0 :name "test"})]
    (assert (= (type db) "table") "init returns a table")
    (assert (= (rawget db :counter) 0) "db has counter")
    (assert (= (rawget db :name) "test") "db has name")))

(fn t.test-init-empty []
  (setup)
  (let [db (dataflow.init)]
    (assert (= (type db) "table") "init with nil returns table")))

(fn t.test-init-replaces-state []
  (setup)
  (dataflow.init {:a 1})
  (let [db (dataflow.init {:b 2})]
    (assert (= (rawget db :b) 2) "new state has :b")
    (assert (= (rawget db :a) nil) "old state :a is gone")))

;; --- get ---

(fn t.test-get-reads-value []
  (setup)
  (let [db (dataflow.init {:counter 42})]
    (assert (= (dataflow.get db :counter) 42) "get reads value")))

(fn t.test-get-returns-nil-for-missing []
  (setup)
  (let [db (dataflow.init {:counter 0})]
    (assert (= (dataflow.get db :missing) nil) "get returns nil for missing key")))

(fn t.test-get-returns-default []
  (setup)
  (let [db (dataflow.init {})]
    (assert (= (dataflow.get db :missing "fallback") "fallback") "get returns default")))

(fn t.test-get-returns-value-over-default []
  (setup)
  (let [db (dataflow.init {:key "real"})]
    (assert (= (dataflow.get db :key "fallback") "real") "get returns value not default")))

;; --- get-in ---

(fn t.test-get-in-nested []
  (setup)
  (let [db (dataflow.init {:user {:name "Alice"}})]
    (assert (= (dataflow.get-in db [:user :name]) "Alice") "get-in reads nested")))

(fn t.test-get-in-array-index []
  (setup)
  (let [db (dataflow.init {:items [{:text "first"} {:text "second"}]})]
    (assert (= (dataflow.get-in db [:items 1 :text]) "first") "get-in with numeric index")
    (assert (= (dataflow.get-in db [:items 2 :text]) "second") "get-in second item")))

(fn t.test-get-in-returns-nil-for-missing []
  (setup)
  (let [db (dataflow.init {:a {:b 1}})]
    (assert (= (dataflow.get-in db [:a :c]) nil) "get-in nil for missing")))

(fn t.test-get-in-returns-default []
  (setup)
  (let [db (dataflow.init {})]
    (assert (= (dataflow.get-in db [:a :b] "default") "default") "get-in default")))

(fn t.test-get-in-nil-intermediate []
  (setup)
  (let [db (dataflow.init {})]
    (assert (= (dataflow.get-in db [:a :b :c] "safe") "safe") "get-in nil intermediate returns default")))

;; --- assoc ---

(fn t.test-assoc []
  (setup)
  (let [db (dataflow.init {:counter 0})]
    (let [result (dataflow.assoc db :counter 5)]
      (assert (= result db) "assoc returns db")
      (assert (= (rawget db :counter) 5) "assoc sets value"))))

(fn t.test-assoc-new-key []
  (setup)
  (let [db (dataflow.init {})]
    (dataflow.assoc db :new-key "hello")
    (assert (= (rawget db :new-key) "hello") "assoc creates new key")))

(fn t.test-assoc-records-change []
  (setup)
  (let [db (dataflow.init {})]
    (dataflow.assoc db :x 1)
    (let [paths (dataflow._get-changed-paths)]
      (assert (> (length paths) 0) "assoc records changed path")
      (let [path (. paths 1)]
        (assert (= (. path 1) :x) "changed path is [:x]")))))

;; --- assoc-in ---

(fn t.test-assoc-in []
  (setup)
  (let [db (dataflow.init {:user {:name "Alice"}})]
    (let [result (dataflow.assoc-in db [:user :name] "Bob")]
      (assert (= result db) "assoc-in returns db")
      (assert (= (. (rawget db :user) :name) "Bob") "assoc-in sets nested value"))))

(fn t.test-assoc-in-creates-intermediates []
  (setup)
  (let [db (dataflow.init {})]
    (dataflow.assoc-in db [:a :b :c] 42)
    (assert (= (. (. (rawget db :a) :b) :c) 42) "assoc-in creates intermediate tables")))

;; --- update ---

(fn t.test-update []
  (setup)
  (let [db (dataflow.init {:counter 5})]
    (let [result (dataflow.update db :counter #(+ $1 1))]
      (assert (= result db) "update returns db")
      (assert (= (rawget db :counter) 6) "update applies function"))))

(fn t.test-update-nil-value []
  (setup)
  (let [db (dataflow.init {})]
    (dataflow.update db :counter #(or $1 0))
    (assert (= (rawget db :counter) 0) "update handles nil input")))

;; --- update-in ---

(fn t.test-update-in []
  (setup)
  (let [db (dataflow.init {:items [{:done false}]})]
    (let [result (dataflow.update-in db [:items 1 :done] #(not $1))]
      (assert (= result db) "update-in returns db")
      (assert (= (. (. (. (rawget db :items) 1) :done) ) true) "update-in toggles nested value"))))

(fn t.test-update-in-creates-intermediates []
  (setup)
  (let [db (dataflow.init {})]
    (dataflow.update-in db [:a :b] #(or $1 0))
    (assert (= (. (rawget db :a) :b) 0) "update-in creates intermediate tables")))

;; --- dissoc ---

(fn t.test-dissoc []
  (setup)
  (let [db (dataflow.init {:a 1 :b 2})]
    (let [result (dataflow.dissoc db :a)]
      (assert (= result db) "dissoc returns db")
      (assert (= (rawget db :a) nil) "dissoc removes key")
      (assert (= (rawget db :b) 2) "dissoc preserves other keys"))))

(fn t.test-dissoc-missing-key []
  (setup)
  (let [db (dataflow.init {:a 1})]
    (dataflow.dissoc db :nonexistent)
    (assert (= (rawget db :a) 1) "dissoc of missing key is harmless")))

;; --- dissoc-in ---

(fn t.test-dissoc-in []
  (setup)
  (let [db (dataflow.init {:user {:name "Alice" :age 30}})]
    (let [result (dataflow.dissoc-in db [:user :age])]
      (assert (= result db) "dissoc-in returns db")
      (assert (= (. (rawget db :user) :age) nil) "dissoc-in removes nested key")
      (assert (= (. (rawget db :user) :name) "Alice") "dissoc-in preserves siblings"))))

(fn t.test-dissoc-in-missing-intermediate []
  (setup)
  (let [db (dataflow.init {})]
    (let [result (dataflow.dissoc-in db [:a :b :c])]
      (assert (= result db) "dissoc-in with missing intermediate returns db"))))

;; --- reg-handler + dispatch ---

(fn t.test-reg-handler-and-dispatch []
  (setup)
  (let [db (dataflow.init {:counter 0})]
    (dataflow.reg-handler :event/inc
      (fn [db event]
        (dataflow.update db :counter #(+ $1 1))))
    (dataflow.dispatch [:event/inc])
    (assert (= (rawget (dataflow._get-raw-db) :counter) 1) "dispatch runs handler")))

(fn t.test-dispatch-with-args []
  (setup)
  (let [db (dataflow.init {:counter 0})]
    (dataflow.reg-handler :event/add
      (fn [db event]
        (dataflow.update db :counter #(+ $1 (. event 2)))))
    (dataflow.dispatch [:event/add 10])
    (assert (= (rawget (dataflow._get-raw-db) :counter) 10) "dispatch passes event args")))

(fn t.test-dispatch-records-changes []
  (setup)
  (let [db (dataflow.init {:counter 0})]
    (dataflow.reg-handler :event/inc
      (fn [db event]
        (dataflow.update db :counter #(+ $1 1))))
    (dataflow.dispatch [:event/inc])
    (assert (dataflow.has-changes?) "dispatch records changed paths")))

(fn t.test-dispatch-unknown-handler []
  (setup)
  (dataflow.init {})
  (let [(ok err) (pcall dataflow.dispatch [:event/unknown])]
    (assert (not ok) "dispatch errors on unknown handler")
    (assert (string.find err "No handler") "error mentions missing handler")))

(fn t.test-dispatch-multiple []
  (setup)
  (let [db (dataflow.init {:counter 0})]
    (dataflow.reg-handler :event/inc
      (fn [db event]
        (dataflow.update db :counter #(+ $1 1))))
    (dataflow.dispatch [:event/inc])
    (dataflow.dispatch [:event/inc])
    (dataflow.dispatch [:event/inc])
    (assert (= (rawget (dataflow._get-raw-db) :counter) 3) "multiple dispatches accumulate")))

;; --- reg-sub + subscribe ---

(fn t.test-subscribe-basic []
  (setup)
  (let [db (dataflow.init {:counter 42})]
    (dataflow.reg-sub :sub/counter
      (fn [db] (dataflow.get db :counter)))
    (assert (= (dataflow.subscribe :sub/counter) 42) "subscribe returns computed value")))

(fn t.test-subscribe-caches []
  (setup)
  (var call-count 0)
  (let [db (dataflow.init {:counter 1})]
    (dataflow.reg-sub :sub/counter
      (fn [db]
        (set call-count (+ call-count 1))
        (dataflow.get db :counter)))
    (dataflow.subscribe :sub/counter)
    (dataflow.subscribe :sub/counter)
    (dataflow.subscribe :sub/counter)
    (assert (= call-count 1) "subscription fn called only once when cached")))

(fn t.test-subscribe-missing-warns []
  (setup)
  (dataflow.init {})
  (assert (= (dataflow.subscribe :sub/nonexistent) nil) "missing sub returns nil"))

;; --- flush + invalidation ---

(fn t.test-flush-invalidates-matching-sub []
  (setup)
  (var call-count 0)
  (let [db (dataflow.init {:counter 0})]
    (dataflow.reg-sub :sub/counter
      (fn [db]
        (set call-count (+ call-count 1))
        (dataflow.get db :counter)))
    (assert (= (dataflow.subscribe :sub/counter) 0))
    (assert (= call-count 1))
    (dataflow.reg-handler :event/inc
      (fn [db event] (dataflow.update db :counter #(+ $1 1))))
    (dataflow.dispatch [:event/inc])
    (dataflow.flush)
    (assert (= (dataflow.subscribe :sub/counter) 1) "sub recomputed after flush")
    (assert (= call-count 2) "sub fn called twice total")))

(fn t.test-flush-does-not-invalidate-unrelated []
  (setup)
  (var counter-calls 0)
  (var name-calls 0)
  (let [db (dataflow.init {:counter 0 :name "Alice"})]
    (dataflow.reg-sub :sub/counter
      (fn [db]
        (set counter-calls (+ counter-calls 1))
        (dataflow.get db :counter)))
    (dataflow.reg-sub :sub/name
      (fn [db]
        (set name-calls (+ name-calls 1))
        (dataflow.get db :name)))
    (dataflow.subscribe :sub/counter)
    (dataflow.subscribe :sub/name)
    (assert (= counter-calls 1))
    (assert (= name-calls 1))
    (dataflow.reg-handler :event/inc
      (fn [db event] (dataflow.update db :counter #(+ $1 1))))
    (dataflow.dispatch [:event/inc])
    (dataflow.flush)
    (dataflow.subscribe :sub/counter)
    (dataflow.subscribe :sub/name)
    (assert (= counter-calls 2) "counter sub recomputed")
    (assert (= name-calls 1) "name sub NOT recomputed")))

(fn t.test-prefix-invalidation-parent-write []
  (setup)
  (let [db (dataflow.init {:items [{:done false}]})]
    (dataflow.reg-sub :sub/first-done
      (fn [db] (dataflow.get-in db [:items 1 :done])))
    (assert (= (dataflow.subscribe :sub/first-done) false))
    (dataflow.reg-handler :event/replace-items
      (fn [db event] (dataflow.assoc db :items [{:done true}])))
    (dataflow.dispatch [:event/replace-items])
    (dataflow.flush)
    (assert (= (dataflow.subscribe :sub/first-done) true) "parent write invalidates child sub")))

(fn t.test-prefix-invalidation-child-write []
  (setup)
  (var recomputed false)
  (let [db (dataflow.init {:items [{:done false} {:done false}]})]
    (dataflow.reg-sub :sub/items
      (fn [db]
        (set recomputed true)
        (dataflow.get db :items)))
    (dataflow.subscribe :sub/items)
    (set recomputed false)
    (dataflow.reg-handler :event/toggle
      (fn [db event] (dataflow.assoc-in db [:items 1 :done] true)))
    (dataflow.dispatch [:event/toggle])
    (dataflow.flush)
    (dataflow.subscribe :sub/items)
    (assert recomputed "child write invalidates parent sub")))

(fn t.test-flush-clears-changed-paths []
  (setup)
  (let [db (dataflow.init {:x 1})]
    (dataflow.reg-handler :event/set
      (fn [db event] (dataflow.assoc db :x 2)))
    (dataflow.dispatch [:event/set])
    (assert (dataflow.has-changes?))
    (dataflow.flush)
    (assert (not (dataflow.has-changes?)) "flush clears changed paths")))

;; --- dynamic subscription dependencies ---

(fn t.test-dynamic-deps-simple []
  (setup)
  (var call-count 0)
  (let [db (dataflow.init {:mode :a :a-val 10 :b-val 20})]
    (dataflow.reg-sub :sub/value
      (fn [db]
        (set call-count (+ call-count 1))
        (let [mode (dataflow.get db :mode)]
          (if (= mode :a)
            (dataflow.get db :a-val)
            (dataflow.get db :b-val)))))
    (assert (= (dataflow.subscribe :sub/value) 10))
    (assert (= call-count 1))
    (dataflow.reg-handler :event/set-b
      (fn [db event] (dataflow.assoc db :b-val 99)))
    (dataflow.dispatch [:event/set-b])
    (dataflow.flush)
    (dataflow.subscribe :sub/value)
    (assert (= call-count 1) "changing :b-val does not recompute when mode is :a")
    (dataflow.reg-handler :event/set-mode
      (fn [db event] (dataflow.assoc db :mode :b)))
    (dataflow.dispatch [:event/set-mode])
    (dataflow.flush)
    (assert (= (dataflow.subscribe :sub/value) 99) "after mode switch, reads :b-val")
    (assert (= call-count 2))
    (dataflow.reg-handler :event/set-a
      (fn [db event] (dataflow.assoc db :a-val 999)))
    (dataflow.dispatch [:event/set-a])
    (dataflow.flush)
    (dataflow.subscribe :sub/value)
    (assert (= call-count 2) "changing :a-val does not recompute when mode is :b")))

;; --- fx map detection ---

(fn t.test-handler-fx-map []
  (setup)
  (let [db (dataflow.init {:loading false})
        captured []]
    (dataflow.set-effect-handler
      (fn [fx-map]
        (table.insert captured fx-map)))
    (dataflow.reg-handler :event/fetch
      (fn [db event]
        {:db (dataflow.assoc db :loading true)
         :http {:url "/api/items"}
         :log "fetching..."}))
    (dataflow.dispatch [:event/fetch])
    (assert (= (rawget (dataflow._get-raw-db) :loading) true) "fx map: db was updated")
    (assert (= (length captured) 1) "effect handler called once")
    (let [fx (. captured 1)]
      (assert (. fx :http) "fx map contains :http")
      (assert (= (. fx :log) "fetching...") "fx map contains :log"))))

(fn t.test-handler-no-fx-when-returning-db []
  (setup)
  (let [db (dataflow.init {:counter 0})
        captured []]
    (dataflow.set-effect-handler
      (fn [fx-map]
        (table.insert captured fx-map)))
    (dataflow.reg-handler :event/inc
      (fn [db event]
        (dataflow.update db :counter #(+ $1 1))))
    (dataflow.dispatch [:event/inc])
    (assert (= (length captured) 0) "no effect handler called for plain db return")))

;; --- global exports ---

(fn t.test-globals-registered []
  (setup)
  (dataflow.init {:counter 0})
  (dataflow.register-globals)
  (assert (= _G.get dataflow.get) "global get")
  (assert (= (. _G "get-in") dataflow.get-in) "global get-in")
  (assert (= _G.assoc dataflow.assoc) "global assoc")
  (assert (= (. _G "reg-handler") dataflow.reg-handler) "global reg-handler")
  (assert (= _G.dispatch dataflow.dispatch) "global dispatch")
  (assert (= (. _G "reg-sub") dataflow.reg-sub) "global reg-sub")
  (assert (= _G.subscribe dataflow.subscribe) "global subscribe"))

(fn t.test-globals-work-end-to-end []
  (setup)
  (let [db (dataflow.init {:counter 0})]
    (dataflow.register-globals)
    (_G.reg_handler "event/inc"
      (fn [db event]
        (_G.update db :counter #(+ $1 1))))
    (_G.dispatch ["event/inc"])
    (_G.reg_sub "sub/counter"
      (fn [db] (_G.get db :counter)))
    (dataflow.flush)
    (assert (= (_G.subscribe "sub/counter") 1) "globals work end-to-end")))

t
