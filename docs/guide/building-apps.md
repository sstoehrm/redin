# Building Apps

A progressive tutorial that builds a todo app in Fennel. You should have read the quickstart first. The full API reference lives in [app-api.md](../app-api.md) and [core-api.md](../core-api.md).

---

## 1. Initialize state

All app state lives in a single table called `app-db`. You initialize it once at startup with `dataflow.init`. Everything in this table is the source of truth -- you never read or write it directly, only through tracked accessor functions.

```fennel
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(dataflow.init
  {:items  [{:text "Learn redin"} {:text "Write tests"}]
   :input-value ""})
```

The `:items` list holds the todo items and `:input-value` tracks the current input text. The framework records which paths are read and written, so subscriptions only invalidate when the data they actually depend on changes.

---

## 2. Theme

The theme is a flat map of aspect name to visual properties. Call `theme-mod.set-theme` once at startup. Visual properties never go on elements -- only aspect names do.

State variants use `#` as a separator (e.g. `:button#hover`, `:input#focus`). The renderer resolves state variants automatically -- define only the properties that change.

```fennel
(theme-mod.set-theme
  {:surface         {:bg [46 52 64] :padding [24 24 24 24]}
   :heading         {:font-size 24 :color [236 239 244] :weight 1}
   :body            {:font-size 14 :color [216 222 233]}
   :muted           {:font-size 13 :color [76 86 106]}
   :input           {:bg [59 66 82] :color [236 239 244]
                      :border [76 86 106] :border-width 1
                      :radius 4 :padding [8 12 8 12] :font-size 14}
   :input#focus     {:border [136 192 208]}
   :button          {:bg [76 86 106] :color [236 239 244]
                      :radius 6 :padding [6 14 6 14] :font-size 13}
   :button#hover    {:bg [94 105 126]}
   :button#active   {:bg [59 66 82]}})
```

---

## 3. Register handlers

Handlers are pure functions from `(db, event) -> db`. They are the only place state can change. Register them at startup with `reg-handler`.

```fennel
;; Update the input value from input element change events.
(reg-handler :todo/input
  (fn [db event]
    (let [ctx (. event 2)]
      (assoc db :input-value (or ctx.value "")))
    db))

;; Add a new todo from the current input value.
(reg-handler :todo/add
  (fn [db event]
    (let [val (get db :input-value "")]
      (when (> (string.len val) 0)
        (update db :items (fn [items]
          (table.insert items {:text val})
          items))
        (assoc db :input-value "")))
    db))
```

Event vectors are plain arrays: `[:todo/add]`. The first element is the event key; extra elements are arguments accessed by index with `(. event 2)`.

---

## 4. Register subscriptions

Subscriptions derive read-only views of state. They are cached and only recomputed when a path they depend on changes. Register them with `reg-sub`.

```fennel
(reg-sub :items
  (fn [db] (get db :items [])))

(reg-sub :input-value
  (fn [db] (get db :input-value "")))
```

The framework re-records dependencies on every recomputation. No explicit wiring is needed -- you just read what you need.

---

## 5. Write the view

A view function returns the frame tree directly as nested arrays. It calls `subscribe` to read derived state, then builds the frame tree. Events are declared directly on elements as attributes (`:click`, `:change`, `:key`).

```fennel
(global main_view
  (fn []
    (let [items (subscribe :items)
          input-val (subscribe :input-value)]
      [:vbox {}
       [:stack {}
        [:vbox {:aspect :surface :layout :center}
         [:text {:aspect :heading :layout :center} "Todo List"]
         [:input {:aspect :input :width 250 :height 42
                  :value input-val
                  :change [:todo/input] :key [:todo/add]}]
         [:button {:width 250 :height 42 :aspect :button
                   :click [:todo/add]} "Add"]
         [:vbox {:overflow :scroll-y :aspect :muted}
          (icollect [_ item (ipairs (or items []))]
            [:text {:aspect :body} item.text])]]]])))
```

`icollect` returns a list of frames that the framework flattens into the parent's children automatically. No wrapper element needed.

Event attributes on elements:
- `:click` -- fires on mouse click, dispatches the given event vector
- `:change` -- fires on input value change, passes `{:value ...}` as event arg
- `:key` -- fires on Enter key in an input

---

## 6. Effects

Handlers that need side effects return an fx map instead of `db`. The `:db` key is the updated state; all other keys are effect instructions.

```fennel
(reg-handler :event/add-todo
  (fn [db event]
    (let [text (. event 2)]
      {:db (update db :items (fn [items]
             (table.insert items {:text text})
             items))
       :dispatch-later {:ms 500 :dispatch [:event/save]}})))
```

Register a custom effect executor with `reg-fx`:

```fennel
(reg-fx :save
  (fn [params]
    (local json (require :json))
    (local f (io.open "todos.json" "w"))
    (f:write (json.encode params.todos))
    (f:close)))

(reg-handler :event/save
  (fn [db _event]
    {:db   db
     :save {:todos (get db :items)}}))
```

The `:dispatch-later` built-in queues the event and fires it when `poll-timers` is called by the host, once per frame. The handler stays a pure function -- it describes what should happen, not how.

---

## 7. Testing

Handlers and subscriptions are pure data transformations. Test them by initializing state, dispatching events, and asserting on the result -- no renderer required.

```fennel
;; Test that add-todo appends a new item
(dataflow.init {:items [] :input-value "Write tests"})
(dispatch [:todo/add])
(local items (subscribe :items))
(assert (= (length items) 1))
(assert (= (. items 1 :text) "Write tests"))

;; Test effects by stubbing the executor
(local save-calls [])
(reg-fx :save (fn [params] (table.insert save-calls params)))

(dispatch [:event/save])
(assert (= (length save-calls) 1))
```

Stub any effect with `reg-fx` before the test runs, then assert on what was captured.
