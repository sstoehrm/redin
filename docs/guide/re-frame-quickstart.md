# re-frame quickstart for redin

A translation guide for developers who know re-frame. The programming model is the same; the surface is different.

## Concept mapping

| re-frame | redin | Notes |
|----------|-------|-------|
| `app-db` (atom) | `app-db` (Lua table) | Mutable in-place, not immutable |
| `reg-event-db` | `reg-handler` | Handler receives db, returns db |
| `reg-event-fx` | `reg-handler` (return fx map) | Return `{:db ... :http ...}` |
| `reg-sub` | `reg-sub` | Same pattern |
| `@(subscribe [:key])` | `(subscribe :sub/key)` | Direct call, no deref |
| `dispatch` | `dispatch` | Same |
| Hiccup `[:div {:class "x"} ...]` | Frame `[:vbox {:aspect :x} ...]` | No CSS -- use aspects |
| Reagent components | Fennel functions | No reactivity in components |
| Interceptors | Effects | Handlers return fx maps |
| `reg-fx` | `reg-fx` | Same |

## Key differences

**State is mutable.** `assoc`/`update` mutate in-place and return the same table. Path tracking handles invalidation; reference equality is never checked.

**Keywords are strings.** `:counter` in Fennel compiles to `"counter"` in Lua. Handler keys, sub keys, and effect keys are plain strings. Event vector position 1 is the key string, position 2 onward are arguments.

**Tables are 1-indexed.** Lua convention. Use path notation as-is with `get-in`/`assoc-in`; the accessors handle the indexing.

**No namespaced keywords.** Use `/` in strings: `"event/increment"`, `"sub/counter"`.

**Visual properties belong in the theme only.** Never put `color`, `bg`, `font-size`, etc. on a frame element. Define an aspect in the theme and reference it: `{:aspect :button}`. Elements carry structural attributes only (`gap`, `padding`, `width`, `align`).

**State variants use `#`.** Theme keys like `:button#hover` and `:input#focus` use `#` as the separator between the base aspect and the state variant.

**Events are inline on elements.** Instead of a separate binding table, event handlers are declared directly as element attributes: `:click`, `:change`, `:key`. The view returns `{:frame [...] :bind {}}` with an empty bind map.

## Translation recipe

### State

```fennel
;; re-frame: (reg-event-db :init-db (fn [_ _] {:counter 0}))
(local dataflow (require :dataflow))
(dataflow.init {:counter 0})
```

### Handlers

```fennel
;; Pure state update (reg-event-db equivalent)
(reg-handler :event/increment
  (fn [db event]
    (update db :counter #(+ $1 1))))

;; With side effects (reg-event-fx equivalent)
(reg-handler :event/fetch
  (fn [db event]
    {:db   (assoc db :loading true)
     :http {:url "/api" :on-success :event/loaded}}))
```

### Subscriptions

```fennel
;; No Layer 2/3 signals needed -- deps are recorded automatically
(reg-sub :sub/counter
  (fn [db] (get db :counter)))

(reg-sub :sub/active-items
  (fn [db]
    (icollect [_ item (ipairs (get db :items))]
      (when (not item.done) item))))
```

### View

```fennel
;; main_view is a plain function, not a reactive component.
;; The runtime calls it each tick after invalidated subs recompute.
(global main_view
  (fn []
    (let [count (subscribe :sub/counter)]
      {:frame
       [:vbox {:gap 16 :padding [24 24 24 24]}
         [:text {:aspect :heading} (tostring count)]
         [:button {:aspect :button :click [:event/increment]} "+1"]]
       :bind {}})))
```

### Inline events replace binding tables

In re-frame, dispatch happens inside `:on-click`. In redin, events are declared as element attributes. The runtime dispatches for you. Context (coordinates, input value) is appended automatically.

```fennel
;; Click on the button fires [:event/increment]
[:button {:aspect :button :click [:event/increment]} "+1"]

;; Input change and enter key
[:input {:aspect :input :value val
         :change [:event/update-draft] :key [:event/submit]}]
```

To dispatch from an effect:

```fennel
{:db (assoc db :status :done)
 :dispatch [:event/notify "Saved"]}
```
