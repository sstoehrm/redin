;; Performance test: 10,000 vbox rows, each with 1000 characters of
;; text, inside a single scroll-y container. Run with --profile to
;; observe per-phase costs under load.
;;
;;   ./build/redin --profile examples/perf-10k.fnl
;;   ./build/redin --dev --profile examples/perf-10k.fnl   ; + /profile
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:body      {:font-size 14 :color [40 40 40]}
   :row       {:bg [245 245 245] :padding [6 10 6 10]}
   :row-alt   {:bg [235 235 235] :padding [6 10 6 10]}
   :container {:bg [255 255 255] :padding [8 8 8 8]}})

(dataflow.init {})
(global redin_get_state (. dataflow :_get-raw-db))

;; Roughly 1000 characters of deterministic text.
(local pattern
  "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. ")
(local text-1000 (string.sub (.. pattern pattern pattern pattern) 1 1000))

(local ROW-COUNT 10000)

;; Build the view tree once at load time. main_view returns the same
;; table reference each frame — the Bridge still flattens it fresh,
;; so this measures framework cost rather than Fennel tree-allocation.
(local tree
  (let [root [:vbox {:aspect :container :overflow :scroll-y}]]
    (for [i 1 ROW-COUNT]
      (let [aspect (if (= 0 (% i 2)) :row :row-alt)]
        (table.insert root
          [:vbox {:aspect aspect}
           [:text {:aspect :body} text-1000]])))
    root))

(global main_view (fn [] tree))
