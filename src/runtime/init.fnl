;; init.fnl -- Bootstrap sequence.
;; Loads all runtime modules, registers globals, wires up effect handler.

(local dataflow (require :dataflow))
(local effect (require :effect))
(local frame (require :frame))
(local theme (require :theme))
(local view (require :view))

;; Register globals
(dataflow.register-globals)
(effect.register-globals)

;; Wire effect handler: dataflow dispatch -> effect execute
(dataflow.set-effect-handler effect.execute)

;; Bridge-facing globals (called by Odin host each frame)
(set _G.redin_render_tick view.render-tick)
(set _G.redin_events view.deliver-events)

;; Export for host access
{:dataflow dataflow
 :effect effect
 :frame frame
 :theme theme
 :view view}
