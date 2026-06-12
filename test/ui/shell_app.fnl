;; Minimal app exercising the :shell effect.
;; Regression coverage for issue #214: REDIN_TRACK_MEM builds (what
;; build-dev.sh produces, and what this suite runs against) crashed with
;; SIGILL when the first shell result was delivered.
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:body {:font-size 14 :color [216 222 233]}})

(dataflow.init {:out "" :exit "" :runs 0})

;; Expose state to dev server (GET /state endpoint)
(global redin_get_state (. dataflow :_get-raw-db))

;; Absolute paths in :cmd — the shell env allowlist is deny-by-default,
;; so children get no PATH to resolve against.
(reg-handler :shell/run
  (fn [db event]
    {:db db
     :shell {:cmd ["/bin/echo" "-n" (. event 2)]
             :on-success :shell/ok
             :on-error :shell/fail}}))

(reg-handler :shell/run-fail
  (fn [db event]
    {:db db
     :shell {:cmd ["/bin/false"]
             :on-success :shell/ok
             :on-error :shell/fail}}))

(reg-handler :shell/ok
  (fn [db event]
    (let [resp (. event 2)]
      (update (assoc db :out (or (. resp :stdout) ""))
              :runs #(+ $1 1)))))

;; exit-code arrives as a Lua number; store it as a string so the test
;; isn't comparing JSON doubles to integers.
(reg-handler :shell/fail
  (fn [db event]
    (let [resp (. event 2)]
      (update (assoc db :exit (tostring (. resp :exit-code)))
              :runs #(+ $1 1)))))

(reg-sub :sub/out (fn [db] (get db :out)))

(global main_view
  (fn []
    (let [out (subscribe :sub/out)]
      [:vbox {}
       [:text {:id :out :aspect :body} (tostring out)]])))
