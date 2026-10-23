;; test/ui/aspect_compose_app.fnl
;; Composed aspects: `:aspect [:a :b]` merges left-to-right (later wins),
;; and state variants compose per aspect in the same order
;; (docs/reference/theme.md § Composition + state merge order).

(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:surface      {:bg [255 255 255]}
   ;; The html2redin `<hr class="sep">` shape: a colour aspect plus a
   ;; rule aspect that contributes no bg of its own.
   :red          {:bg [220 0 0]}
   :hr-rule      {:padding [0 0 0 0] :radius 0}
   ;; Later wins: [:base :tint] must draw the tint colour.
   :base         {:bg [0 160 0]}
   :tint         {:bg [0 0 200]}
   ;; State composition: btn < danger < btn#hover < danger#hover.
   :btn          {:bg [80 80 80] :color [255 255 255]}
   :danger       {:bg [190 30 30]}
   :btn#hover    {:bg [30 150 30]}
   :danger#hover {:radius 0}})

(dataflow.init {:clicks 0})

(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :ev/click (fn [db _] (update db :clicks #(+ $1 1))))

(global main_view
  (fn []
    [:vbox {:aspect :surface}
     [:vbox {:id :rule :aspect [:red :hr-rule] :height 20 :width 100}]
     [:vbox {:id :later-wins :aspect [:base :tint] :height 20 :width 100}]
     [:vbox {:id :missing-part :aspect [:nope :red] :height 20 :width 100}]
     [:button {:id :composed-btn :aspect [:btn :danger] :click [:ev/click]
               :width 100 :height 30} ""]]))
