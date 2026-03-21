# Frames (visual data)

Frames describe **what to draw**. Nothing else. No callbacks, no behavior.

```fennel
[:vbox {:aspect :surface :gap 8}
  [:text {:aspect :heading} "counter"]
  [:hbox {:gap 4}
    [:text {:id :count :aspect :display} "42"]
    [:rect {:id :inc-btn :aspect :button} [:text {} "+"]]
    [:rect {:id :dec-btn :aspect :button} [:text {} "-"]]]]
```

Frames are:
- Serializable (Lua tables / JSON)
- Diffable (for tests: `deep=` on two frames)
- Readable by AI (structured, no opaque callbacks)
- Addressable by `:id` for binding interactions and AI injection

## Element catalog (minimal)

| element   | purpose                |
|-----------|------------------------|
| `:text`   | text run               |
| `:rect`   | rectangle / container  |
| `:image`  | texture from path      |
| `:hbox`   | horizontal layout      |
| `:vbox`   | vertical layout        |
| `:scroll` | scrollable container   |
| `:input`  | text field (visual)    |

## Attributes (visual only)

```
:id                                   — identity for binding + AI targeting
:aspect                               — design token name (see aspects)
:width :height :min-width :max-width  — dimensions (px, :fill, :hug)
:padding :gap                         — spacing
:visible                              — conditional display
```

No `:color`, `:bg`, `:font-size` on elements directly — those come from aspects.
