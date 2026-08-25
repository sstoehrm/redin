;; Test app for image component UI tests
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:surface {:bg [46 52 64] :padding [24 24 24 24]}
   :body    {:font-size 14 :color [216 222 233]}
   :logo    {:bg [59 66 82] :opacity 0.8}
   :banner  {:bg [76 86 106]}})

(dataflow.init
  {:show-image true})

(global redin_get_state (. dataflow :_get-raw-db))

(reg-handler :event/toggle
  (fn [db event]
    (update db :show-image (fn [v] (not v)))))

(reg-handler :event/reset
  (fn [db event]
    (assoc db :show-image true)))

(reg-sub :show-image (fn [db] (get db :show-image true)))

(global main_view
  (fn []
    (let [show (subscribe :show-image)]
      [:vbox {:aspect :surface}
       [:text {:id :title :aspect :body} "Image Test"]
       (when show
         [:image {:id :logo :aspect :logo :width 120 :height 40}])
       [:image {:id :banner :aspect :banner :width 300 :height 80}]
       [:image {:id :plain :width 60 :height 60}]
       [:image {:id :sprite :src "test/ui/fixtures/sprite.png"
                :fit :stretch :width 64 :height 64}]
       [:image {:id :sprite-keep :src "test/ui/fixtures/sprite.png"
                :fit :keep :width 64 :height 64}]
       ;; :stretch-x / :stretch-y coverage (#3): the fixture is a square
       ;; (4x4) texture, so fitting it into a rect *taller* than it is wide
       ;; makes :stretch-x letterbox top/bottom (the scaled dest is
       ;; width x width, centered in the taller rect); the mirror rect
       ;; (wider than tall) makes :stretch-y letterbox left/right. Chosen
       ;; deliberately so both fit modes exercise real letterboxing rather
       ;; than scissor-clipped overflow. Wrapped in an hbox with an
       ;; explicit :height: a vbox's default (no :layout) cross-axis
       ;; behaviour stretches children to the container width regardless
       ;; of a declared :width (:width is honored only as an hbox's main
       ;; axis), and an hbox's own :height must be given explicitly or it
       ;; falls back to fill-remaining-space -- which would then stretch
       ;; the image's cross-axis (height) right back out.
       [:hbox {:id :sprite-stretch-x-row :height 64}
        [:image {:id :sprite-stretch-x :src "test/ui/fixtures/sprite.png"
                 :fit :stretch-x :width 32 :height 64}]]
       [:hbox {:id :sprite-stretch-y-row :height 32}
        [:image {:id :sprite-stretch-y :src "test/ui/fixtures/sprite.png"
                 :fit :stretch-y :width 64 :height 32}]]
       [:image {:id :broken :src "test/ui/fixtures/does-not-exist.png"
                :width 64 :height 64}]
       [:button {:id :toggle-btn :aspect :body :width 100 :height 30
                 :click [:event/toggle]} "Toggle"]])))
