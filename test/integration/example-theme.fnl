{;; Backgrounds
   :surface             {:bg [46 52 64] :padding [24 24 24 24]}
   :surface.alt         {:bg [59 66 82] :radius 4 :padding [8 12 8 12]}

   ;; Typography
   :heading             {:font-size 24 :color [236 239 244] :weight 1}
   :body                {:font-size 14 :color [216 222 233]}
   :muted               {:font-size 13 :color [76 86 106]}

   ;; Input
   :input               {:bg [59 66 82] :color [236 239 244]
                         :border [76 86 106] :border-width 1
                         :radius 4 :padding [8 12 8 12] :font-size 14}
   :input#focus         {:border [136 192 208]}

   ;; Primary button (Add, active filter)
   :button              {:bg [76 86 106] :color [236 239 244]
                         :radius 6 :padding [6 14 6 14] :font-size 13}
   :button#hover        {:bg [94 105 126]}
   :button#active       {:bg [59 66 82]}

   ;; Secondary button (inactive filter)
   :button.secondary       {:bg [59 66 82] :color [216 222 233]
                             :radius 6 :padding [6 14 6 14] :font-size 13}
   :button.secondary#hover {:bg [67 76 94]}

   ;; Danger button (delete)
   :danger              {:bg [191 97 106] :color [236 239 244]
                         :radius 6 :padding [6 14 6 14] :font-size 13}
   :danger#hover        {:bg [210 115 124]}}
