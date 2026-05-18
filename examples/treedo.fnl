;; treedo — forest-themed pixel-art todo example.

(local dataflow (require :dataflow))
(local theme-mod (require :theme))
(local canvas (require :canvas))

;; ===== Palette (pixel-art forest) =====

(local pal {:night-soil  [22 28 22]
            :bark-dark   [54 38 28]
            :bark-mid    [96 70 48]
            :moss        [70 92 58]
            :leaf-deep   [54 110 56]
            :leaf-mid    [120 170 70]
            :leaf-bright [200 220 110]
            :sunset-gold [228 188 90]
            :mushroom    [180 60 70]
            :bone-white  [232 224 196]})

;; ===== Theme =====

(theme-mod.set-theme
  {:canopy        {:bg [38 46 38] :padding [20 20 20 20] :radius 8}
   :heading       {:font-size 22 :weight 1 :color (. pal :bone-white)}
   :body          {:font-size 14 :color (. pal :bone-white)}
   :count-badge   {:font-size 12 :color (. pal :sunset-gold)}

   :trail         {:padding [4 4 4 4]}
   :trail#hover   {:bg (. pal :moss) :padding [4 4 4 4]}
   :row-vining    {:bg (. pal :leaf-mid)
                   :color (. pal :night-soil)
                   :padding [4 4 4 4]
                   :shadow [0 4 16 [0 0 0 140]]}
   :row-drop-hot  {:bg [90 130 60] :padding [4 4 4 4]}
   :muted-armed   {:bg [48 56 48]}

   :bark          {:bg (. pal :bark-dark)
                   :color (. pal :bone-white)
                   :border (. pal :bark-mid)
                   :border-width 1
                   :radius 4
                   :padding [8 12 8 12]
                   :font-size 14}
   :bark#focus    {:border (. pal :leaf-bright)}

   :leaf          {:bg (. pal :leaf-bright)
                   :color (. pal :night-soil)
                   :radius 6
                   :padding [6 14 6 14]
                   :font-size 13
                   :weight 1}
   :leaf#hover    {:bg [215 230 120]}
   :leaf#active   {:bg [180 200 90]}

   :mushroom         {:bg (. pal :bark-dark) :color [160 150 130]
                      :radius 6 :padding [4 4 4 4] :font-size 16}
   :mushroom#hover   {:color (. pal :mushroom)}
   :mushroom#active  {:bg (. pal :bark-mid)}})

;; ===== State =====

(global redin_get_state (. dataflow :_get-raw-db))

(dataflow.init {:items []
                :input-value ""
                :drag-start-time nil
                :falling-leaves []})

;; ===== Subscriptions =====

(reg-sub :items (fn [db] (get db :items [])))
(reg-sub :input-value (fn [db] (get db :input-value "")))
(reg-sub :drag-start-time (fn [db] (get db :drag-start-time)))
(reg-sub :falling-leaves (fn [db] (get db :falling-leaves [])))

;; ===== View =====

(global main_view
        (fn []
          (let [items (subscribe :items)
                count (length items)]
            [:stack
             {:viewport [[:top_left 0 0 :full :full]
                         [:top_center 0 32 480 :full]]}
             [:vbox {:aspect :canopy}
              [:hbox {:height 32 :layout :center}
               [:text {:aspect :heading} "treedo"]
               [:vbox {:width :full}]
               [:text {:aspect :count-badge} (.. count " items")]]]])))
