;; Test app for input component UI tests
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:surface {:bg [46 52 64] :padding [24 24 24 24]}
   :heading {:font-size 24 :color [236 239 244] :weight 1}
   :body    {:font-size 14 :color [216 222 233]}
   :input   {:bg [59 66 82] :color [236 239 244]
             :border [76 86 106] :border-width 1
             :radius 4 :padding [8 12 8 12] :font-size 14}
   :input-top {:bg [59 66 82] :color [236 239 244]
               :border [76 86 106] :border-width 1
               :radius 4 :padding [8 12 8 12] :font-size 14
               :text-align :top}
   :input#focus {:border [136 192 208]}})

(dataflow.init
  {:input-value ""
   :multiline-value ""
   :submitted []
   :last-key nil})

;; Expose state to dev server (GET /state endpoint)
(global redin_get_state (. dataflow :_get-raw-db))

;; Change handler — updates input-value from the host
(reg-handler :event/input-change
  (fn [db event]
    (let [ctx (. event 2)]
      (assoc db :input-value (or ctx.value "")))))

;; Key handler — on Enter, append current value to submitted list
(reg-handler :event/input-key
  (fn [db event]
    (let [ctx (. event 2)]
      (assoc db :last-key ctx.key)
      (when (= ctx.key :enter)
        (let [val (get db :input-value "")]
          (when (> (string.len val) 0)
            (update db :submitted (fn [items]
              (table.insert items val)
              items))
            (assoc db :input-value ""))))
      db)))

;; Direct set for testing dispatch-driven value changes
(reg-handler :event/set-input
  (fn [db event]
    (assoc db :input-value (or (. event 2) ""))))

;; Multi-line input: no :key handler, so Enter inserts \n in the buffer
;; (host/input/input.odin:293) and the value comes back via :change.
(reg-handler :event/multiline-change
  (fn [db event]
    (let [ctx (. event 2)]
      (assoc db :multiline-value (or ctx.value "")))))

(reg-handler :event/reset
  (fn [db event]
    (-> db
        (assoc :input-value "")
        (assoc :multiline-value "")
        (assoc :submitted [])
        (assoc :last-key nil))))

(reg-sub :input-value (fn [db] (get db :input-value "")))
(reg-sub :multiline-value (fn [db] (get db :multiline-value "")))
(reg-sub :submitted (fn [db] (get db :submitted [])))
(reg-sub :last-key (fn [db] (get db :last-key)))
(reg-sub :submitted-count (fn [db] (length (get db :submitted []))))

(global main_view
  (fn []
    (let [input-val (subscribe :input-value)
          multiline-val (subscribe :multiline-value)
          items (subscribe :submitted)
          count (subscribe :submitted-count)
          last-key (subscribe :last-key)]
      [:vbox {}
       [:text {:id :title :aspect :heading} "Input Test"]
       [:input {:id :test-input :aspect :input :width 250 :height 42
                :value input-val
                :placeholder "Type here..."
                :change [:event/input-change] :key [:event/input-key]}]
       [:text {:id :current-value :aspect :body} (.. "value:" input-val)]
       [:text {:id :submitted-count :aspect :body} (.. "count:" (tostring count))]
       [:text {:id :last-key :aspect :body} (.. "key:" (or last-key ""))]
       [:input {:id :multiline-input :aspect :input :width 250 :height 80
                :value multiline-val
                :placeholder "Multi-line (Enter for new line)..."
                :change [:event/multiline-change]}]
       [:text {:id :multiline-current :aspect :body} (.. "ml:" multiline-val)]
       [:vbox {:id :submitted-list}
        (icollect [i item (ipairs (or items []))]
          [:text {:id (.. :item- (tostring i)) :aspect :body} item])]])))
