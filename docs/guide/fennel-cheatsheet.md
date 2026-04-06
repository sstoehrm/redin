# Fennel syntax cheatsheet

Quick lookup for Fennel patterns used in redin code.

| Pattern | Example | Meaning |
|---|---|---|
| `(fn name [args] body)` | `(fn view [db] [:box])` | Named function definition |
| `#(body)` with `$1 $2` | `(update db :counter #(+ $1 1))` | Anonymous function shorthand; `$1` is first arg |
| `(let [x 1 y 2] body)` | `(let [w 320 h 48] [:box {:w w :h h}])` | Local bindings, scoped to body |
| `(local name value)` | `(local default-font :sans)` | Module-level local (top of file) |
| `(var name value)` | `(var count 0)` | Mutable local |
| `(set name value)` | `(set count (+ count 1))` | Assign to mutable local |
| `{:key val}` | `{:color :red :w 100}` | Table (map / dict) |
| `[:a :b :c]` | `[:box :text :button]` | Sequential table (array) |
| `:keyword` | `:click` | String literal; sugar for `"click"` |
| `(. table key)` | `(. frame :children)` | Table field access |
| `table.key` | `frame.children` | Dot access -- identical to `(. table key)` |
| `(each [k v (pairs t)] body)` | `(each [k v (pairs theme)] (redin.log k v))` | Iterate map (unordered) |
| `(each [_ v (ipairs t)] body)` | `(each [_ item (ipairs items)] (render item))` | Iterate array (ordered, 1-based) |
| `(icollect [_ x (ipairs items)] expr)` | `(icollect [_ item (ipairs items)] [:text item.label])` | List comprehension -- returns new array |
| `(when cond body)` | `(when loading [:spinner])` | If without else; returns nil when false |
| `(if c1 b1 c2 b2 else)` | `(if (= filter :done) done-items (= filter :active) active-items all-items)` | Multi-branch if (cond-style) |
| `(match val pat1 b1 ...)` | `(match event [:click x y] (on-click x y) [:key k _] (on-key k))` | Pattern matching on value |
| `(require :module)` | `(local dataflow (require :dataflow))` | Import module |
| `(tostring x)` | `(tostring (get db :counter))` | Convert value to string |
| `(length t)` | `(length (get db :items))` | Table length; same as `#t` in Lua |
