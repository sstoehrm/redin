;; Test app for the font glyph set (review C3). Every cell is a fixed
;; 80x80 text node; cells sharing an aspect render identical pixels
;; exactly when they draw the same glyph. raylib substitutes '?' for a
;; codepoint missing from the font atlas, so a missing glyph shows up as
;; a cell that is pixel-identical to the "?" cell of the same font.
;;
;;   q / u / euro / dash / omega : bundled sans font
;;   fq / fu / fomega            : a theme :font-face font (loaded through
;;                                 the bridge's font-face path, not the
;;                                 embedded loader)
;;
;; omega (U+03A9) is deliberately outside the supported range: it is the
;; control proving the comparison really detects the '?' fallback.
;; The font-face cells use an integer multiple of the face's atlas size:
;; font-face atlases are point-filtered, and a fractional scale (e.g.
;; 1.5x) puts pixel centres exactly on texel edges, where the GPU's
;; rounding can differ by screen x and break exact equality.
(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme
  {:font-face {:facetest {:regular "src/redin/font/NotoSerif-Regular.ttf"}}
   :glyph {:font-size 48 :color [0 0 0]}
   :face  {:font :facetest :font-size 64 :color [0 0 0]}})

(dataflow.init {})
(global redin_get_state (. dataflow :_get-raw-db))

(global main_view
  (fn []
    [:vbox {}
     [:hbox {:height 80}
      [:text {:id :q      :aspect :glyph :width 80 :height 80} "?"]
      [:text {:id :u      :aspect :glyph :width 80 :height 80} "ü"]
      [:text {:id :euro   :aspect :glyph :width 80 :height 80} "€"]
      [:text {:id :dash   :aspect :glyph :width 80 :height 80} "—"]
      [:text {:id :omega  :aspect :glyph :width 80 :height 80} "Ω"]
      [:text {:id :fq     :aspect :face  :width 80 :height 80} "?"]
      [:text {:id :fu     :aspect :face  :width 80 :height 80} "ü"]
      [:text {:id :fomega :aspect :face  :width 80 :height 80} "Ω"]]]))
