(require '[redin-test :refer :all]
         '[cheshire.core :as json]
         '[babashka.http-client :as http]
         '[clojure.string :as str])

;; ---------------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------------

(defn get-selection []
  (let [resp (http/get (str (base-url) "/selection")
                       {:headers {"Accept" "application/json"}
                        :throw false})]
    (when (= 200 (:status resp))
      (json/parse-string (:body resp) true))))

;; ---------------------------------------------------------------------------
;; Reset helper: click an empty corner to clear any existing selection and
;; wait long enough (>0.4s) that the double-click counter resets.
(defn reset-selection! []
  (click 900 700)
  (wait-ms 600))

;; ---------------------------------------------------------------------------
;; Layout notes (surface padding 24px, font-size 16px):
;;   body text  : y ≈ 24–44  (single line, ~20px tall)
;;   locked text: y ≈ 44–64  (single line, ~20px tall)
;;   input field: y ≈ 64–94  (with 8px vertical padding each side)
;;
;; A single click produces a collapsed caret (start == end) which
;; has_selection() treats as no selection → /selection returns kind:none.
;; A double-click selects a word → start < end → /selection returns kind:text.
;; ---------------------------------------------------------------------------

(deftest no-selection-initially
  (reset-selection!)
  (let [sel (get-selection)]
    (assert (= "none" (:kind sel))
            (str "expected kind:none initially, got " (:kind sel)))))

(deftest double-click-selects-word
  ;; Reset and wait >0.4s so click-count resets to 1, then issue two rapid
  ;; clicks on the body-text line (y ≈ 32).
  (reset-selection!)
  (click 200 32)
  (wait-ms 120)
  (click 200 32)
  (wait-for {:desc "kind=text after double-click"
             :check-fn (fn []
                         (let [s (get-selection)]
                           (and (= "text" (:kind s))
                                (< (:start s) (:end s)))))}
            {:timeout 2000})
  (let [sel (get-selection)
        text (:text sel)]
    (assert (= "text" (:kind sel))
            (str "expected kind:text, got " (:kind sel)))
    (assert (pos? (count (str/trim text)))
            "double-click should produce a non-empty text selection (ignoring trailing space)")
    (assert (not (str/starts-with? text " "))
            (str "selected text should not start with a space, got: " (pr-str text)))))

(deftest opt-out-text-is-not-selectable
  ;; Establish a text selection on the body node via double-click.
  (reset-selection!)
  (click 200 32)
  (wait-ms 120)
  (click 200 32)
  (wait-for {:desc "text selection established"
             :check-fn (fn [] (= "text" (:kind (get-selection))))}
            {:timeout 2000})
  ;; Now click in the locked-text band (y ≈ 50). Because the locked text
  ;; has :selectable false, it carries no Text_Select_Listener, so the
  ;; click-elsewhere-to-clear path fires and the selection becomes none.
  ;; Crucially it must NOT become kind:text.
  (wait-ms 500)
  (click 200 50)
  (wait-ms 300)
  (let [sel (get-selection)]
    (assert (not= "text" (:kind sel))
            (str "locked text should not produce kind:text, got " (:kind sel)))))

(deftest clicking-input-clears-text-selection
  ;; Establish text selection on body text via double-click.
  (reset-selection!)
  (click 200 32)
  (wait-ms 120)
  (click 200 32)
  (wait-for {:desc "text selection established"
             :check-fn (fn [] (= "text" (:kind (get-selection))))}
            {:timeout 2000})
  ;; Click the input field (y ≈ 75). apply_focus calls focus_enter which
  ;; calls clear_text_selection, so selection_kind changes away from .Text.
  (wait-ms 500)
  (click 400 75)
  (wait-ms 300)
  (let [sel (get-selection)]
    (assert (not= "text" (:kind sel))
            (str "clicking input should clear text selection, got " (:kind sel)))))
