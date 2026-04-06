;; frame.fnl -- Frame format nested list flattening.

(local M {})

(fn nested-list? [v]
  (and (= (type v) "table")
       (> (length v) 0)
       (= (type (. v 1)) "table")))

(fn M.flatten [node]
  (if (not= (type node) "table")
    node
    (let [tag (. node 1)]
      (if (not= (type tag) "string")
        node
        (let [result [tag (. node 2)]]
          (for [i 3 (length node)]
            (let [child (. node i)]
              (if (nested-list? child)
                (each [_ c (ipairs child)]
                  (table.insert result (M.flatten c)))
                (if (= (type child) "table")
                  (table.insert result (M.flatten child))
                  (table.insert result child)))))
          result)))))

M
