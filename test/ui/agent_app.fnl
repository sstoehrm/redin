;; UI test fixture for /agent/* endpoints. Built for the test_agent.bb
;; suite. Needs the binary to be built with -define:REDIN_AGENT=true;
;; otherwise the test runner skips itself.

(local dataflow (require :dataflow))

(dataflow.init {:typed ""})

(reg-handler :event/typed (fn [db ev] (let [ctx (. ev 2)] (assoc db :typed (or ctx.value "")))))
(reg-sub     :sub/typed   (fn [db] (get db :typed "")))

(fn _G.main_view []
  [:vbox {:id :root}
    [:text  {:id :reply       :agent :edit} "default-reply"]
    [:text  {:id :ro-text     :agent :read} "read-only-text"]
    [:input {:id :user-input  :agent :read
             :value (subscribe :sub/typed)
             :change :event/typed} ""]
    [:button {:id :ro-button  :agent :read} "click me"]
    [:vbox  {:id :region      :agent :edit}
      [:text {} "default-child"]]])
