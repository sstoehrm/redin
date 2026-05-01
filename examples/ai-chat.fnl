;; AI chat example -- requires a build with -define:REDIN_AGENT=true.
;;
;; The :reply text is :agent :edit -- the agent posts content via
;;   PUT /agent/content/reply
;; and it appears here.
;;
;; The :user-input is :agent :read -- the agent polls
;;   GET /agent/content/user-input
;; to see what the user is currently typing.
;;
;; Markdown rendering for the reply is tracked in issue #100.

(local dataflow (require :dataflow))
(local theme    (require :theme))

(theme.set-theme
  {:surface       {:bg [30 33 42] :padding [16 16 16 16]}
   :user-bubble   {:bg [60 80 110] :color [240 240 240]
                   :padding [8 12 8 12] :radius 6}
   :agent-bubble  {:bg [40 50 60]  :color [220 230 240]
                   :padding [8 12 8 12] :radius 6}
   :user-input    {:bg [25 28 35] :color [240 240 240]
                   :padding [8 8 8 8] :radius 4}})

(dataflow.init {:typed ""})

(reg-handler :event/typed     (fn [db ev] (let [ctx (. ev 2)] (assoc db :typed (or ctx.value "")))))
(reg-handler :event/submitted (fn [db _]  (assoc db :typed "")))

(reg-sub :sub/typed (fn [db] (get db :typed "")))

(fn _G.main_view []
  [:vbox {:aspect :surface :width :full :height :full}
    [:text  {:id :reply :agent :edit :aspect :agent-bubble} "…"]
    [:input {:id :user-input :agent :read :aspect :user-input
             :value (subscribe :sub/typed)
             :change :event/typed
             :submit :event/submitted}
            ""]])
