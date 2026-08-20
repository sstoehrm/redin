(ns html2redin.cli
  (:require [html2redin.html :as html]
            [html2redin.css :as css]
            [html2redin.cascade :as cascade]
            [html2redin.mapping :as mapping]
            [html2redin.theme :as theme]
            [html2redin.emit :as emit]))

(defn run
  "Pure pipeline. :css-sources are external sheets in cascade order
   (before <style> blocks)."
  [{:keys [html html-path css-sources]}]
  (let [{:keys [tree styles] :as parsed} (html/parse html-path html)
        all-sources (concat css-sources
                            (map-indexed (fn [i s] {:name (str html-path "#style" (inc i))
                                                    :text (:text s)})
                                         styles))
        parsed-css (map #(css/parse (:name %) (:text %)) all-sources)
        ;; renumber :order globally so later sources win ties
        rules (vec (map-indexed (fn [i r] (assoc r :order i))
                                (mapcat :rules parsed-css)))
        resolved (cascade/resolve-tree tree rules)
        synth (theme/synthesize (:tree resolved) html-path)
        mapped (mapping/map-tree (:tree resolved) (:assignments synth) html-path)]
    {:view (emit/view-fnl (:node mapped))
     :theme (emit/theme-fnl (:theme synth))
     :warnings (vec (concat (:warnings parsed)
                            (mapcat :warnings parsed-css)
                            (:warnings resolved)
                            (:warnings synth)
                            (:warnings mapped)))}))
