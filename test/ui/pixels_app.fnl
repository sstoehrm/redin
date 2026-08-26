;; Test app for ctx.pixels: 58 sprites of 64x96, the #279 scene shape.
;; Each sprite's RGBA string is built ONCE and cached; the provider then
;; issues one ctx.pixels command per sprite per frame.
(local dataflow (require :dataflow))
(local canvas (require :canvas))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:surface {:bg [24 26 33] :padding [8 8 8 8]}
   :film    {:bg [30 32 40]}})

(dataflow.init {:sprites 58})
(global redin_get_state (. dataflow :_get-raw-db))

(reg-sub :sprites (fn [db] (get db :sprites 58)))

;; Build one 64x96 RGBA byte string, tinted per index (deterministic).
(fn make-sprite [i]
  (let [w 64 h 96
        r (% (* i 37) 256)
        g (% (* i 91) 256)
        b (% (* i 53) 256)
        row-parts []]
    (for [_ 1 w]
      (table.insert row-parts (string.char r g b 255)))
    (let [row (table.concat row-parts)]
      (string.rep row h))))

(local sprite-cache {})
(fn sprite [i]
  (when (not (. sprite-cache i))
    (tset sprite-cache i (make-sprite i)))
  (. sprite-cache i))

(canvas.register :filmstrip
  (fn [ctx]
    (let [cols 10 cw 70 chh 102]
      (for [i 1 58]
        (let [col (% (- i 1) cols)
              row (math.floor (/ (- i 1) cols))]
          (ctx.pixels (* col cw) (* row chh) 64 96 (sprite i)))))))

(global main_view
  (fn []
    [:vbox {:aspect :surface}
     [:canvas {:id :film :provider :filmstrip :aspect :film
               :width 720 :height 640}]]))
