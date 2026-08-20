(ns html2redin.cli
  (:require [clojure.string :as str]
            [html2redin.html :as html]
            [html2redin.css :as css]
            [html2redin.cascade :as cascade]
            [html2redin.mapping :as mapping]
            [html2redin.theme :as theme]
            [html2redin.emit :as emit]))

(def default-hr-rule-aspect {:bg [128 128 128]})

(defn run
  "Pure pipeline. :css-sources are external sheets in cascade order
   (before <style> blocks)."
  [{:keys [html html-path css-sources]}]
  (let [{:keys [tree styles] :as parsed} (html/parse html-path html)
        all-sources (concat css-sources
                            (map-indexed (fn [i s]
                                           ;; Prepend (dec line) newlines so
                                           ;; css/parse's own line counting
                                           ;; (relative to this block's text)
                                           ;; comes out as document-absolute
                                           ;; line numbers in warnings.
                                           {:name (str html-path "#style" (inc i))
                                            :text (str (apply str (repeat (dec (:line s)) \newline))
                                                       (:text s))})
                                         styles))
        parsed-css (map #(css/parse (:name %) (:text %)) all-sources)
        ;; renumber :order globally so later sources win ties
        rules (vec (map-indexed (fn [i r] (assoc r :order i))
                                (mapcat :rules parsed-css)))
        resolved (cascade/resolve-tree tree rules)
        synth (theme/synthesize (:tree resolved) html-path)
        mapped (mapping/map-tree (:tree resolved) (:assignments synth) html-path)
        ;; hr maps to a :hr-rule aspect (composed with any class aspect);
        ;; ensure the theme carries a default entry for it whenever an hr
        ;; was actually mapped, without an author-defined :hr-rule losing
        ;; out.
        theme (cond-> (:theme synth)
                (:uses-hr-rule? mapped)
                (update :hr-rule #(or % default-hr-rule-aspect)))]
    {:view (emit/view-fnl (:node mapped))
     :theme (emit/theme-fnl theme)
     :warnings (vec (concat (:warnings parsed)
                            (mapcat :warnings parsed-css)
                            (:warnings resolved)
                            (:warnings synth)
                            (:warnings mapped)))}))
