;; markdown.fnl -- Default theme entries for the `:md/*` aspect family.
;; Registered into theme.set-defaults at runtime startup so apps using
;; [:markdown] render legibly without any theme config.

(local theme (require :theme))

(local M {})

(local defaults
  {;; Body text: paragraphs and list-item content.
   :md/body         {:font :sans :font-size 18 :color [240 240 240] :line-height 1.5}

   ;; Headings — descending size, bold for h1-h4, italic for h5/h6.
   :md/h1           {:font :sans :font-size 32 :color [240 240 240] :weight :bold :line-height 1.3}
   :md/h2           {:font :sans :font-size 26 :color [240 240 240] :weight :bold :line-height 1.3}
   :md/h3           {:font :sans :font-size 22 :color [240 240 240] :weight :bold :line-height 1.3}
   :md/h4           {:font :sans :font-size 19 :color [240 240 240] :weight :bold :line-height 1.4}
   :md/h5           {:font :sans :font-size 17 :color [240 240 240] :line-height 1.4}
   :md/h6           {:font :sans :font-size 16 :color [240 240 240] :line-height 1.4}

   ;; Lists.
   :md/list         {:padding [4 0 4 16]}
   :md/list-item    {:padding [2 0 2 0]}
   :md/list-marker  {:font :sans :font-size 18 :color [240 240 240] :line-height 1.5}

   ;; Inline code (read by span renderer; only font is consumed here —
   ;; bg / color come through resolve too if user overrides).
   :md/code         {:font :mono :font-size 16 :color [240 240 240] :bg [60 60 70]}})

(fn M.install []
  (theme.set-defaults defaults))

M
