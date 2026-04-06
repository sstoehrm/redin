[:vbox
 [:stack
  [:canvas {:provider :spreadsheet :width :full :height :full}]
  [:vbox {:aspect :surface
          :layout :center}
   [:text {:aspect :heading
           :layout :center}
          "Title"]
   [:input {:aspect :input
            :width 250 
            :height 42
            :change [:test/input]
            :key [:test/add]}]
   [:button {:id "button"
             :width 250
             :height 42
             :click [:test/add]}
            "Add"]
   [:vbox {:overflow :scroll-y
           :aspect :muted}
          [:text {:aspect :body} "Test 1"]
          [:text {:aspect :body} "Test 2"]
          [:text {:aspect :body} "Test 3"]
          [:text {:aspect :body} "Test 4"]]]]]
