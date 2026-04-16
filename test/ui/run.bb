#!/usr/bin/env bb

(babashka.classpath/add-classpath "test/ui")
(require '[redin-test :refer :all]
         '[clojure.string :as str]
         '[babashka.http-client :as http])

(def cli-args *command-line-args*)

(def host (or (some->> cli-args (partition 2 1) (filter #(= (first %) "--host")) first second)
              "localhost"))
(def port (or (some->> cli-args (partition 2 1) (filter #(= (first %) "--port")) first second parse-long)
              (read-port-file)
              8800))

(def test-files
  (or (seq (filter #(and (str/ends-with? % ".bb") (not (str/starts-with? % "--")))
                   (remove #(= % "--host") (remove #(= % "--port") cli-args))))
      (let [dir (clojure.java.io/file "test/ui")]
        (when (.isDirectory dir)
          (->> (.listFiles dir)
               (filter #(and (str/starts-with? (.getName %) "test_")
                             (str/ends-with? (.getName %) ".bb")))
               (map #(.getPath %))
               sort
               seq)))))

;; Check dev server
(print "Checking dev server... ")
(flush)
(try
  (http/get (str "http://" host ":" port "/frames")
            {:headers {"Accept" "application/json"} :timeout 2000})
  (println "OK")
  (catch Exception _
    (println "FAILED")
    (println (str "Dev server not reachable at " host ":" port))
    (println "Start redin with --dev first.")
    (System/exit 2)))

(connect! {:host host :port port})

(def total-passed (atom 0))
(def total-failed (atom 0))

(if (empty? test-files)
  (println "No test files found.")
  (doseq [file test-files]
    (println (str "\nRunning: " file))
    (reset-tests!)
    (try
      (load-file file)
      (let [{:keys [passed failed]} (run-tests!)]
        (swap! total-passed + passed)
        (swap! total-failed + failed))
      (catch Exception e
        (println (str "  ERROR loading: " (.getMessage e)))
        (swap! total-failed inc)))))

(println (str "\n" @total-passed " passed, " @total-failed " failed"))

(disconnect!)

(System/exit (if (> @total-failed 0) 1 0))
