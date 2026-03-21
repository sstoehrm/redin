# Aspects (design system)

Aspects replace CSS/inline styles. They are **named bundles of visual properties** — the design system as data.

```fennel
;; theme definition
{:surface    {:bg [30 30 40] :padding 16 :radius 4}
 :heading    {:font-size 24 :color [255 255 255] :weight :bold}
 :display    {:font-size 48 :color [200 220 255] :font :mono}
 :button     {:bg [60 60 80] :padding [8 16] :radius 4 :color [255 255 255]}
 :button.hover {:bg [80 80 110]}
 :input      {:bg [20 20 30] :border [60 60 80] :padding [8 12] :color [255 255 255]}
 :input.focus {:border [100 120 255]}
 :danger     {:color [255 80 80]}
 :muted      {:color [120 120 140]}}
```

## Key properties

- **Composable** — an element can have multiple aspects: `{:aspect [:button :danger]}` merges right-to-left
- **Stateful variants** — `button.hover`, `input.focus` are resolved by the renderer based on interaction state. The app code never manages hover/focus styling.
- **Themeable** — swap the aspect table, the entire app changes look. Light/dark is just two aspect maps.
- **Inspectable** — an AI can read the full aspect map to understand the design language

## Aspect properties

```
:bg :color :border               — colors as [r g b] or [r g b a]
:font-size :font :weight         — typography
:padding :radius                 — spacing and shape
:border-width                    — stroke
:opacity                         — transparency
```

Elements **never** set these directly. All visual styling goes through aspects.
