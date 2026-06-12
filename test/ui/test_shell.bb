(require '[redin-test :refer :all])

;; Issue #214: the shell worker thread allocated Shell_Response strings
;; under the thread-default heap allocator while the main thread freed
;; them under the tracking allocator (REDIN_TRACK_MEM, the build-dev.sh
;; default this suite runs against). The first delivered result tripped
;; the tracker's bad-free assertion -> SIGILL. These tests fail hard if
;; that regresses: the app dies on the first delivery and every wait-for
;; below times out.

(deftest shell-success-delivers-stdout
  (dispatch ["shell/run" "tracked"])
  (wait-for (state= "out" "tracked") {:timeout 5000}))

(deftest shell-error-delivers-exit-code
  (dispatch ["shell/run-fail"])
  (wait-for (state= "exit" "1") {:timeout 5000}))

;; A second success proves the app survived freeing the earlier
;; responses (each delivery is one alloc/free cycle across threads).
(deftest shell-survives-repeated-deliveries
  (dispatch ["shell/run" "again"])
  (wait-for (state= "out" "again") {:timeout 5000})
  (assert-state "runs" #(= % 3)))
