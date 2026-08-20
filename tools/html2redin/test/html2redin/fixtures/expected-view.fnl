[:vbox {:height :full}
  [:hbox {:aspect :toolbar :gap 8}
    [:button {:id :save :aspect :btn} "Save"]
    [:button {:aspect :btn} "Load"]]
  [:vbox {:aspect :content :gap 12 :overflow :scroll-y}
    [:text {:aspect :title} "Notes"]
    [:text {:aspect :p-1 :margin [4 0 4 0]} "Type & save."]
    [:input {:placeholder "Search..."}]
    [:text {:aspect :span-1} "Unsaved changes"]
    [:vbox {}
      [:hbox {}
        [:vbox {}
          [:text {} "Name"]]
        [:vbox {}
          [:text {} "Ready"]]]]]]
