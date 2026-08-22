(ns html2redin.script-test
  (:require [clojure.test :refer [deftest is]]
            [clojure.string :as str]
            [babashka.fs :as fs]
            [babashka.process :as p]))

;; Audit #277 M1: <link href> values come from the HTML *data*, so the
;; script must refuse to read stylesheets outside the page's directory.
;; Runs the real entry script end to end.

(def ^:private script "tools/html2redin/html2redin.bb")

(deftest link-href-confined-to-page-directory
  (let [tmp (fs/create-temp-dir)
        pages (fs/create-dirs (fs/path tmp "pages"))
        secret-marker "SECRET-CANARY-277"]
    (try
      (spit (str (fs/path tmp "secret.css"))
            (str ".leak { color: #123456; } /* " secret-marker " */"))
      (spit (str (fs/path pages "ok.css")) "p { color: #ff0000; }")
      (spit (str (fs/path pages "page.html"))
            (str "<html><head>"
                 "<link rel=\"stylesheet\" href=\"../secret.css\">"
                 "<link rel=\"stylesheet\" href=\"/etc/hostname\">"
                 "<link rel=\"stylesheet\" href=\"ok.css\">"
                 "</head><body><p>hi</p></body></html>"))
      (let [out-prefix (str (fs/path tmp "out"))
            {:keys [exit out err]}
            (p/sh {:out :string :err :string}
                  "bb" script (str (fs/path pages "page.html")) "-o" out-prefix)
            view (slurp (str out-prefix "-view.fnl"))
            theme (slurp (str out-prefix "-theme.fnl"))]
        (is (zero? exit))
        (is (= 2 (count (re-seq #"escapes the page directory — skipped" err)))
            "both the ../ and the absolute href must be refused")
        (doseq [text [out err view theme]]
          (is (not (str/includes? text secret-marker))
              "no byte of the out-of-tree file may reach any output"))
        (is (str/includes? theme "[255 0 0]")
            "the legitimate sibling stylesheet still applies"))
      (finally
        (fs/delete-tree tmp)))))
