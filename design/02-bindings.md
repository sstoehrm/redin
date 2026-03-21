# Bindings (interaction map)

Bindings connect **paths** (tree positions) to **events**. Separate from the frame.

The `:path` is a vector of element tags describing the location in the frame tree — like a CSS selector but structural. This means bindings don't require `:id` on every element; they address by shape.

```fennel
[{:path [:vbox :hbox :rect]  :action :click  :event [:counter/inc]}
 {:path [:vbox :hbox :rect]  :action :click  :event [:counter/dec]}
 {:path [:vbox :text]        :action :hover  :event [:counter/tooltip :count]}
 {:path [:vbox :input]       :action :change :event [:search/update]}
 {:path [:vbox :input]       :action :submit :event [:search/go :query]}]
```

When multiple siblings match the same tag, use index notation: `[:vbox :hbox [:rect 0]]` for the first rect, `[:vbox :hbox [:rect 1]]` for the second.

## Event params

Events carry additional params — these get appended when dispatched:
- `[:counter/inc]` dispatches as-is
- `[:search/update]` dispatches as `[:search/update <input-value>]` — the runtime appends context
- `[:counter/tooltip :count]` dispatches as `[:counter/tooltip :count <hover-state>]`

## Properties

- The frame is **pure visual data** — no functions, no closures
- Interactions are **declarative** — an AI can read "what is clickable" without parsing callbacks
- Paths address by tree structure, not by arbitrary IDs
- The same frame can be rebound to different interactions (reuse, testing)
- Actions are a closed set: `:click`, `:hover`, `:change`, `:submit`, `:focus`, `:blur`, `:key`
