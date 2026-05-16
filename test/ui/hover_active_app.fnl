;; Hover/active state-variant test fixture.
;;
;; One themed button at a fixed-size rect. Distinct, easy-to-recognise
;; bg colours per state so the test can pixel-sample and compare exactly:
;;   base   = [50 50 50]     (dark grey)
;;   hover  = [100 100 100]  (mid grey)
;;   active = [200 200 200]  (light grey)
;;
;; No corner radius, no shadow — solid rect makes pixel sampling stable.

(local dataflow (require :dataflow))
(local theme-mod (require :theme))

(theme-mod.set-theme {:bg-fill {:bg [0 0 0]}
                      :btn         {:bg [50 50 50]
                                    :color [255 255 255]
                                    :radius 0
                                    :padding [0 0 0 0]
                                    :font-size 14}
                      :btn#hover   {:bg [100 100 100]}
                      :btn#active  {:bg [200 200 200]}})

(dataflow.init {:clicks 0})

(reg-handler :test/click
             (fn [db event]
               (update db :clicks #(+ $ 1))))

(reg-sub :clicks (fn [db] (get db :clicks 0)))

(global main_view
        (fn []
          [:stack
           {:viewport [[:top_left 0 0 :full :full]]}
           ;; Solid black background fill so anything outside the button
           ;; is obviously not the button.
           [:vbox {:aspect :bg-fill :width :full :height :full}
            [:button {:aspect :btn
                      :width 100
                      :height 40
                      :click [:test/click]}
             ""]]]))
