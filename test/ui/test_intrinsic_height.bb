(require '[redin-test :refer :all])

;; Intrinsic (content) height of children in scroll-y containers. Layout
;; is documented in intrinsic_height_app.fnl; every expectation is
;; derived from /frames rects rather than hardcoded font metrics.

(defn- rect [id] (rect-of (find-element {:id id})))

(deftest margined-text-reserves-margin-once
  (let [t1 (rect :t1) t2 (rect :t2) inner (rect :inner) after (rect :after)
        lh (double (:h t2))]
    (assert (pos? lh) "plain text has a non-zero line height")
    (assert (= lh (double (:h t1)))
            (str "margined text is one line tall like its sibling: "
                 (:h t1) " vs " lh))
    (assert (= (+ (double (:y inner)) 10.0) (double (:y t1)))
            "t1 sits below its top margin")
    (assert (= (+ (double (:y t1)) lh 10.0) (double (:y t2)))
            (str "t2 follows t1 + bottom margin, got " (:y t2)))
    (assert (= (+ (* 2 lh) 20.0) (double (:h inner)))
            (str "inner vbox = two lines + both margins, got " (:h inner)))
    (assert (= (+ (double (:y t2)) lh) (double (:y after)))
            (str "'after' starts where t2 ends (no overlap), got "
                 (:y after) " vs t2 end " (+ (double (:y t2)) lh)))))

(deftest hbox-intrinsic-measures-children-at-laid-out-width
  (let [wrap (rect :wrap) ref (rect :ref) row (rect :row) after2 (rect :after2)]
    (assert (= 40.0 (double (:w wrap))) (str "fill text gets the 40px remainder, got " (:w wrap)))
    (assert (= 40.0 (double (:w ref))) "reference text laid out at 40px")
    (assert (> (double (:h ref)) (double (:h after2)))
            "reference text wraps to more than one line at 40px")
    (assert (= (double (:h ref)) (double (:h row)))
            (str "hbox intrinsic height = wrapped text height at its laid-out width: row "
                 (:h row) " vs ref " (:h ref)))
    (assert (= (+ (double (:y row)) (double (:h row))) (double (:y after2)))
            "'after2' follows the row")))
