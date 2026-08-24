#!/usr/bin/env bb
(ns html2redin
  (:require [babashka.classpath]
            [babashka.fs :as fs]
            [clojure.string :as str]))

;; make src/ requirable when run as a script
(babashka.classpath/add-classpath
 (str (fs/parent *file*) "/src"))
(require '[html2redin.cli :as cli]
         '[html2redin.html :as html])

(defn- fail [msg] (binding [*out* *err*] (println msg)) (System/exit 1))

(defn -main [& args]
  (loop [args args, html-path nil, css-paths [], out nil]
    (if-let [[a & more] (seq args)]
      (case a
        "-c" (recur (rest more) html-path (conj css-paths (first more)) out)
        "-o" (recur (rest more) html-path css-paths (first more))
        (recur more (or html-path a) css-paths out))
      (do
        (when-not html-path (fail "usage: html2redin.bb page.html [-c styles.css]... [-o prefix]"))
        (when-not (fs/exists? html-path) (fail (str html-path ": not found")))
        (let [html-text (slurp html-path)
              ;; <link ...stylesheet.../> resolved relative to the html;
              ;; rel= and href= may appear in either order, so match each
              ;; whole <link> tag first, then extract rel/href independently.
              link-tags (re-seq #"(?i)<link[^>]*>" html-text)
              links (keep (fn [tag]
                            (when (re-find #"(?i)rel=[\"']?stylesheet[\"']?" tag)
                              (when-let [[_ href] (re-find #"(?i)href=[\"']?([^\s\"'>]+)[\"']?" tag)]
                                href)))
                          link-tags)
              ;; href comes from the HTML *data*, so confine it to the page's
              ;; directory: no absolute paths, no .. segments. Otherwise a
              ;; hostile page can make the tool slurp any file the invoking
              ;; uid can read (/etc/shadow, ~/.ssh/...) into the warning
              ;; stream and the emitted .fnl output. Audit #277 M1.
              link-sources (keep (fn [href]
                                   (let [hp (fs/path href)
                                         p (str (fs/path (or (fs/parent html-path) ".") href))]
                                     (cond
                                       (or (fs/absolute? hp)
                                           (some #(= ".." (str %)) hp))
                                       (do (binding [*out* *err*]
                                             (println (str html-path " warning: linked stylesheet "
                                                           href " escapes the page directory — skipped")))
                                           nil)
                                       (fs/exists? p)
                                       {:name href :text (slurp p)}
                                       :else
                                       (do (binding [*out* *err*]
                                             (println (str html-path " warning: linked stylesheet "
                                                           href " not found — skipped")))
                                           nil))))
                                 links)
              c-sources (map (fn [p] (when-not (fs/exists? p) (fail (str p ": not found")))
                               {:name p :text (slurp p)}) css-paths)
              {:keys [view theme warnings]}
              (cli/run {:html html-text :html-path html-path
                        :css-sources (concat c-sources link-sources)})]
          (binding [*out* *err*] (doseq [w warnings] (println w)))
          (if out
            (do (spit (str out "-view.fnl") (str view "\n"))
                (spit (str out "-theme.fnl") (str theme "\n"))
                (println (str "wrote " out "-view.fnl, " out "-theme.fnl")))
            (do (println view) (println ";; ---- theme ----") (println theme))))))))

(apply -main *command-line-args*)
