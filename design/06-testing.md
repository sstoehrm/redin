# Testing

Frames are pure data — test without rendering:

```fennel
(let [db {:counter 5}
      result (views.counter db)]
  ;; test the visual output
  (assert (deep= result.frame
    [:vbox {:aspect :surface :gap 8}
      [:text {:aspect :heading} "counter"]
      [:text {:id :count :aspect :display} "5"]]))
  ;; test that interactions are wired up
  (assert (some #(= $.path :inc-btn) result.bind)))
```

Handlers are pure functions:

```fennel
(let [db {:counter 5}
      new-db (handlers.counter-inc db [:counter/inc])]
  (assert (= new-db.counter 6)))
```

Aspects are data — test the design system:

```fennel
(let [theme (themes.dark)]
  (assert (= (. theme :button :radius) 4))
  (assert (not= (. theme :button :bg) (. theme :surface :bg))))
```
