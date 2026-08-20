(ns html2redin.runner
  (:require [clojure.test :as t]))

(def test-namespaces
  '[html2redin.values-test html2redin.html-test html2redin.css-test
    html2redin.cascade-test html2redin.mapping-test html2redin.theme-test
    html2redin.emit-test html2redin.cli-test html2redin.e2e-test])

(defn -main [& _]
  (doseq [ns test-namespaces]
    (try (require ns) (catch Exception _)))  ; later namespaces don't exist yet
  (let [loaded (filter find-ns test-namespaces)
        result (apply t/run-tests loaded)]
    (when (pos? (+ (:fail result) (:error result)))
      (System/exit 1))))
