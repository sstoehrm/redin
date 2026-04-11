;; theme.fnl -- Theme storage and aspect resolution.

(local M {})

(var theme-table {})

(fn M.set-theme [t]
  (set theme-table t)
  ;; Also push to host
  (let [redin-tbl (rawget _G :redin)]
    (when (and redin-tbl (rawget redin-tbl :set_theme))
      ((rawget redin-tbl :set_theme) t))))

(fn M.reset []
  (set theme-table {}))

(fn shallow-merge [base overlay]
  (let [result {}]
    (each [k v (pairs base)]
      (tset result k v))
    (each [k v (pairs overlay)]
      (tset result k v))
    result))

(fn M.resolve [aspect states]
  (if (= (type aspect) "table")
    (do
      (var props {})
      (each [_ key (ipairs aspect)]
        (let [base (or (. theme-table key) {})]
          (set props (shallow-merge props base))))
      (each [_ key (ipairs aspect)]
        (each [_ state (ipairs states)]
          (let [variant-key (.. key "#" state)
                variant (. theme-table variant-key)]
            (when variant
              (set props (shallow-merge props variant))))))
      props)
    (do
      (var props (or (. theme-table aspect) {}))
      (each [_ state (ipairs states)]
        (let [variant-key (.. aspect "#" state)
              variant (. theme-table variant-key)]
          (when variant
            (set props (shallow-merge props variant)))))
      props)))

;; ===== Property consumption matrix =====

(local consumption
  {:text    {:color true :font true :font-size true :weight true :line-height true :align true :opacity true}
   :image   {:opacity true}
   :hbox    {:bg true :padding true :gap true :opacity true}
   :vbox    {:bg true :padding true :gap true :opacity true}
   :input   {:bg true :color true :border true :font true :font-size true :weight true :line-height true :align true :padding true :radius true :border-width true :opacity true}
   :modal   {:bg true :opacity true}
   :popout  {:bg true :border true :padding true :radius true :border-width true :opacity true :shadow true}
   :canvas  {:bg true :border true :padding true :radius true :border-width true :opacity true}})

(fn M.props-for [tag resolved-props]
  (let [consumed (or (. consumption tag) {})
        result {}]
    (each [k v (pairs resolved-props)]
      (when (. consumed k)
        (tset result k v)))
    result))

;; ===== Validation =====

(local color-props {:bg true :color true :border true :cursor true :selection true :placeholder true :scrollbar true})
(local weight-values {:normal true :bold true})
(local align-values {:left true :center true :right true})
(local numeric-props {:font-size true :radius true :border-width true :gap true :line-height true :scrollbar-width true :scrollbar-radius true})

(fn validate-color [v aspect prop errors]
  (if (~= (type v) "table")
    (table.insert errors {:aspect aspect :property prop :message "expected [r g b] or [r g b a]"})
    (do
      (let [len (length v)]
        (when (and (~= len 3) (~= len 4))
          (table.insert errors {:aspect aspect :property prop :message (.. "color must have 3 or 4 elements, got " len)})))
      (each [i c (ipairs v)]
        (when (or (~= (type c) "number") (< c 0) (> c 255))
          (table.insert errors {:aspect aspect :property prop :message (.. "color component " i " must be number 0-255")}))))))

(fn validate-padding [v aspect errors]
  (if (= (type v) "number") nil
    (= (type v) "table")
    (let [len (length v)]
      (when (and (~= len 2) (~= len 4))
        (table.insert errors {:aspect aspect :property :padding :message (.. "padding must be number, [v h], or [t r b l], got " len " elements")})))
    (table.insert errors {:aspect aspect :property :padding :message "padding must be number or table"})))

(fn validate-shadow [v aspect errors]
  (if (~= (type v) "table")
    (table.insert errors {:aspect aspect :property :shadow :message "shadow must be [x y blur [r g b a]]"})
    (do
      (when (~= (length v) 4)
        (table.insert errors {:aspect aspect :property :shadow :message (.. "shadow must have 4 elements [x y blur color], got " (length v))}))
      (for [i 1 (math.min 3 (length v))]
        (when (~= (type (. v i)) "number")
          (table.insert errors {:aspect aspect :property :shadow :message (.. "shadow element " i " must be a number")})))
      (when (>= (length v) 4)
        (let [color (. v 4)]
          (when (or (~= (type color) "table") (~= (length color) 4))
            (table.insert errors {:aspect aspect :property :shadow :message "shadow color must be [r g b a]"})))))))

(fn M.validate [theme-to-validate]
  (let [errors []]
    (each [aspect props (pairs theme-to-validate)]
      (each [prop v (pairs props)]
        (when (. color-props prop) (validate-color v aspect prop errors))
        (when (= prop :font)
          (when (~= (type v) "string")
            (table.insert errors {:aspect aspect :property prop :message (.. "font must be a string, got: " (type v))})))
        (when (= prop :weight)
          (when (not (. weight-values v))
            (table.insert errors {:aspect aspect :property prop :message (.. "weight must be normal or bold, got: " (tostring v))})))
        (when (= prop :align)
          (when (not (. align-values v))
            (table.insert errors {:aspect aspect :property prop :message (.. "align must be left, center, or right, got: " (tostring v))})))
        (when (= prop :opacity)
          (when (or (~= (type v) "number") (< v 0) (> v 1))
            (table.insert errors {:aspect aspect :property prop :message "opacity must be number 0-1"})))
        (when (. numeric-props prop)
          (when (~= (type v) "number")
            (table.insert errors {:aspect aspect :property prop :message (.. prop " must be a number")})))
        (when (= prop :padding) (validate-padding v aspect errors))
        (when (= prop :shadow) (validate-shadow v aspect errors))))
    (if (= (length errors) 0)
      {:ok true}
      {:ok false :errors errors})))

M
