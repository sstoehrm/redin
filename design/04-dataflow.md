# Data flow

```
event ──▶ handler ──▶ new app-db ──▶ subscriptions ──▶ view fn
                                                         │
                                                    ┌────┴────┐
                                                    │  frame  │  (visual tree)
                                                    │  bind   │  (interaction map)
                                                    │  aspects│  (design tokens)
                                                    └────┬────┘
                                                         │
                                                    ┌────┴────┐
                                                    │ renderer│──▶ pixels
                                                    │ server  │◄─▶ AI
                                                    │ tests   │──▶ assertions
                                                    └─────────┘
```

1. **app-db** — single Lua table. The entire application state.
2. **events** — `[:counter/inc]` style vectors. Pure data, logged, replayable.
3. **handlers** — `(fn [db event] new-db)`. Pure functions. No side effects.
4. **effects** — handlers can return an fx map: `{:db new-db :http {...}}`. The runtime executes effects.
5. **subscriptions** — derived views of app-db. Memoized.
6. **view functions** — return `{:frame ... :bind ... :aspects ...}`. Pure data out.
