(local frame (require :frame))

(local t {})

;; --- flatten ---

(fn t.test-flatten-no-change []
  (let [f [:vbox {} [:text {} "hello"]]]
    (let [result (frame.flatten f)]
      (assert (= (. result 1) :vbox) "tag preserved")
      (assert (= (. (. result 3) 1) :text) "child preserved"))))

(fn t.test-flatten-nested-list []
  (let [items [[:text {} "a"] [:text {} "b"]]
        f [:vbox {} [:text {} "header"] items [:text {} "footer"]]]
    (let [result (frame.flatten f)]
      (assert (= (length result) 6) "nested list spliced")
      (assert (= (. (. result 3) 3) "header") "header preserved")
      (assert (= (. (. result 4) 3) "a") "first item spliced")
      (assert (= (. (. result 5) 3) "b") "second item spliced")
      (assert (= (. (. result 6) 3) "footer") "footer preserved"))))

(fn t.test-flatten-recursive []
  (let [inner [[:text {} "inner"]]
        f [:vbox {} [:hbox {} inner]]]
    (let [result (frame.flatten f)]
      (let [hbox (. result 3)]
        (assert (= (. (. hbox 3) 3) "inner") "nested list in child flattened")))))

(fn t.test-flatten-empty-children []
  (let [f [:vbox {}]]
    (let [result (frame.flatten f)]
      (assert (= (length result) 2) "no children preserved"))))

(fn t.test-flatten-string-content []
  (let [f [:text {} "hello"]]
    (let [result (frame.flatten f)]
      (assert (= (. result 3) "hello") "string content preserved"))))

t
