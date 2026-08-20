(ns html2redin.runner
  (:require [clojure.test :as t]))

(def test-namespaces
  '[html2redin.values-test html2redin.html-test html2redin.css-test
    html2redin.cascade-test html2redin.mapping-test html2redin.theme-test
    html2redin.emit-test html2redin.cli-test html2redin.e2e-test])

(defn -main [& _]
  ;; Plain require -- a namespace that fails to compile must fail the run
  ;; loudly (an uncaught exception here), not be silently skipped.
  (doseq [ns test-namespaces]
    (require ns))
  (let [result (apply t/run-tests test-namespaces)]
    (when (pos? (+ (:fail result) (:error result)))
      (System/exit 1))))
