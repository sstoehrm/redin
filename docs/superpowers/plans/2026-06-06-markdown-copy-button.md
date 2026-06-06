# Markdown Copy Button Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give opt-in `[:markdown {:copyable true} "src"]` blocks a top-right "Copy" button that puts the verbatim raw markdown on the system clipboard, and make all lowered markdown text non-selectable so the current broken-but-clickable selection is gone (#112).

**Architecture:** Markdown lowering (`src/redin/markdown/lower.odin`) synthesizes a full-width right-aligned `md/copy-bar` hbox holding a `Copy` `NodeButton` whose new `copy_text` field carries the source; the input layer writes `copy_text` to the clipboard host-side on click (no Fennel round-trip), reusing `rl.SetClipboardText`. Lowered text nodes set `not_selectable = true`.

**Tech Stack:** Odin + Raylib (host, input, types, bridge), Fennel (theme defaults), Babashka (`redin-test`) for UI tests.

**Spec:** `docs/superpowers/specs/2026-06-06-markdown-copy-button-design.md`

---

## File map

- Modify `src/redin/types/view_tree.odin` — add `copy_text: string` to `NodeButton`.
- Modify `src/redin/bridge/bridge.odin` — free `copy_text` in `clear_node_strings`; read `:copyable`; pass `source` to `lower`; clone `NodeButton` strings in `flatten_subtree`.
- Modify `src/redin/markdown/lower.odin` — `Wrapper_Attrs.copyable`, `lower` `source` param, emit copy bar, `not_selectable` on lowered text.
- Modify `src/redin/markdown/lower_test.odin` — new lowering tests.
- Modify `src/redin/input/input.odin` — hit-test buttons with `copy_text`; clipboard write on click; `button_clipboard_text` helper.
- Create `src/redin/input/copy_button_test.odin` — helper unit tests.
- Modify `src/runtime/markdown.fnl` — default `md/copy-bar` + `md/copy-button` aspects.
- Modify `test/ui/markdown_app.fnl` + `test/ui/test_markdown.bb` — copyable block + UI assertions.
- Modify `docs/core-api.md` + `.claude/skills/redin-dev/SKILL.md` — document `:copyable`.

---

## Task 1: Add `copy_text` field to `NodeButton`

**Files:**
- Modify: `src/redin/types/view_tree.odin` (`NodeButton`, ~line 168)
- Modify: `src/redin/bridge/bridge.odin` (`clear_node_strings` `NodeButton` case, ~line 347)

- [ ] **Step 1: Add the field**

In `src/redin/types/view_tree.odin`, the `NodeButton` struct currently ends:
```odin
	label:     string,
	aspect:    string,
	drag_handle: bool,
}
```
Change to:
```odin
	label:     string,
	aspect:    string,
	drag_handle: bool,
	copy_text: string,   // #112: non-empty => clicking copies this to the system clipboard
}
```

- [ ] **Step 2: Free it in `clear_node_strings`**

In `src/redin/bridge/bridge.odin`, the `NodeButton` case reads:
```odin
	case types.NodeButton:
		if len(v.click) > 0 do delete(v.click)
		if len(v.label) > 0 do delete(v.label)
		if len(v.aspect) > 0 do delete(v.aspect)
		// #165: release the registry ref taken by lua_get_event_ctx for a
```
Insert the `copy_text` free before the `#165` comment:
```odin
	case types.NodeButton:
		if len(v.click) > 0 do delete(v.click)
		if len(v.label) > 0 do delete(v.label)
		if len(v.aspect) > 0 do delete(v.aspect)
		if len(v.copy_text) > 0 do delete(v.copy_text)   // #112
		// #165: release the registry ref taken by lua_get_event_ctx for a
```

- [ ] **Step 3: Build to verify it compiles**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: exits 0, no errors.

- [ ] **Step 4: Commit**

```bash
git add src/redin/types/view_tree.odin src/redin/bridge/bridge.odin
git commit -m "feat(#112): add copy_text field to NodeButton"
```

---

## Task 2: Lower copyable markdown into a copy button; mark lowered text non-selectable

**Files:**
- Modify: `src/redin/markdown/lower.odin` (`Wrapper_Attrs`, `lower`, `emit_text`, `emit_list_item`)
- Test: `src/redin/markdown/lower_test.odin`

- [ ] **Step 1: Write the failing tests**

Append to `src/redin/markdown/lower_test.odin`:
```odin
@(test)
test_lower_copyable_emits_copy_button :: proc(t: ^testing.T) {
	src := "# Title\n\nbody"
	blocks := parse(src, context.temp_allocator)
	tree := lower(blocks, Wrapper_Attrs{copyable = true}, context.temp_allocator, src)
	// local 0 = wrapper vbox, 1 = md/copy-bar hbox, 2 = Copy button.
	bar, bar_ok := tree.nodes[1].(types.NodeHbox)
	testing.expect(t, bar_ok, "node 1 must be the copy-bar hbox")
	testing.expect_value(t, bar.aspect, "md/copy-bar")
	testing.expect_value(t, tree.parent_indices[1], i32(0))
	btn, btn_ok := tree.nodes[2].(types.NodeButton)
	testing.expect(t, btn_ok, "node 2 must be the Copy button")
	testing.expect_value(t, btn.label, "Copy")
	testing.expect_value(t, btn.aspect, "md/copy-button")
	testing.expect_value(t, btn.copy_text, src)
	testing.expect_value(t, tree.parent_indices[2], i32(1))
}

@(test)
test_lower_not_copyable_has_no_button :: proc(t: ^testing.T) {
	blocks := parse("# Title", context.temp_allocator)
	tree := lower(blocks, Wrapper_Attrs{}, context.temp_allocator)
	for n in tree.nodes {
		_, is_btn := n.(types.NodeButton)
		testing.expect(t, !is_btn, "non-copyable markdown must not emit a button")
	}
}

@(test)
test_lower_text_is_not_selectable :: proc(t: ^testing.T) {
	blocks := parse("# Title\n\nbody\n\n- item", context.temp_allocator)
	tree := lower(blocks, Wrapper_Attrs{}, context.temp_allocator)
	for n in tree.nodes {
		if tn, ok := n.(types.NodeText); ok {
			testing.expectf(t, tn.not_selectable,
				"lowered text node (aspect %q) must be not_selectable", tn.aspect)
		}
	}
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit`
Expected: FAIL — `lower` has no 4th `source` parameter (compile error), and `copyable`/`not_selectable` behaviors don't exist yet.

- [ ] **Step 3: Add `copyable` to `Wrapper_Attrs`**

In `src/redin/markdown/lower.odin`, `Wrapper_Attrs` ends with `overflow: string,`. Add:
```odin
	overflow: string,
	copyable: bool,   // #112: render a copy-to-clipboard button
}
```

- [ ] **Step 4: Add the `source` param to `lower` and emit the copy bar**

Change the signature (note `source` is added AFTER `allocator` so the 5 existing 3-arg call sites stay valid):
```odin
lower :: proc(blocks: []Block, attrs: Wrapper_Attrs, allocator := context.allocator, source := "") -> LoweredTree {
```
Then, right after the wrapper is appended:
```odin
	append(&nodes, wrapper)
	append(&parents, i32(-1))
```
insert:
```odin
	// #112: opt-in copy button as the wrapper's first child — a full-width,
	// right-aligned bar holding a "Copy" button whose copy_text is the raw
	// source. Emitted before the content blocks so it renders at the top.
	if attrs.copyable {
		bar_idx := i32(len(nodes))
		append(&nodes, types.NodeHbox{
			aspect = "md/copy-bar",
			layout = .CENTER_RIGHT,
			width  = types.SizeValue.FULL,
		})
		append(&parents, 0)
		append(&nodes, types.NodeButton{
			aspect    = "md/copy-button",
			label     = "Copy",
			copy_text = source,
		})
		append(&parents, bar_idx)
	}
```

- [ ] **Step 5: Mark lowered text non-selectable**

In `emit_text`, change the node literal to:
```odin
	t := types.NodeText{
		aspect         = aspect,
		content        = plain,
		inline_spans   = spans,
		not_selectable = true,   // #112: markdown text isn't mouse-selectable
	}
```
In `emit_list_item`, change the marker append to:
```odin
	append(nodes, types.NodeText{
		aspect         = "md/list-marker",
		content        = marker_text,
		width          = f32(MARKER_COLUMN_WIDTH),
		not_selectable = true,   // #112
	})
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit`
Expected: PASS — all existing markdown tests plus the three new ones.

- [ ] **Step 7: Commit**

```bash
git add src/redin/markdown/lower.odin src/redin/markdown/lower_test.odin
git commit -m "feat(#112): lower copyable markdown to a Copy button; lowered text non-selectable"
```

---

## Task 3: Bridge — read `:copyable`, pass source, clone button strings

**Files:**
- Modify: `src/redin/bridge/bridge.odin` (markdown branch ~1343-1358; `flatten_subtree` Pass 1 ~1251-1271)

- [ ] **Step 1: Read `:copyable` and pass `source` to `lower`**

In the markdown branch of `lua_flatten_node`, the attr block ends:
```odin
			attrs.overflow = lua_get_string_field_raw(L, attrs_idx, "overflow")
			lua_pop(L, 1)
		}
```
Change to:
```odin
			attrs.overflow = lua_get_string_field_raw(L, attrs_idx, "overflow")
			if cp, exists := lua_get_bool_field_opt(L, attrs_idx, "copyable"); exists {
				attrs.copyable = cp   // #112
			}
			lua_pop(L, 1)
		}
```
Then change the `lower` call:
```odin
		tree   := markdown.lower(blocks, attrs, context.temp_allocator)
```
to:
```odin
		tree   := markdown.lower(blocks, attrs, context.temp_allocator, source)
```

- [ ] **Step 2: Clone `NodeButton` strings in `flatten_subtree` Pass 1**

In `flatten_subtree`, the deep-copy chain currently handles `NodeText`/`NodeVbox`/`NodeHbox`, ending:
```odin
			} else if t, ok := &owned_node.(types.NodeHbox); ok {
				if len(t.aspect)   > 0 do t.aspect   = strings.clone(t.aspect)
				if len(t.overflow) > 0 do t.overflow = strings.clone(t.overflow)
			}
```
Add a `NodeButton` branch (lowering now produces buttons, which carry owned `aspect`/`label`/`copy_text`):
```odin
			} else if t, ok := &owned_node.(types.NodeHbox); ok {
				if len(t.aspect)   > 0 do t.aspect   = strings.clone(t.aspect)
				if len(t.overflow) > 0 do t.overflow = strings.clone(t.overflow)
			} else if t, ok := &owned_node.(types.NodeButton); ok {
				if len(t.aspect)    > 0 do t.aspect    = strings.clone(t.aspect)
				if len(t.label)     > 0 do t.label     = strings.clone(t.label)
				if len(t.copy_text) > 0 do t.copy_text = strings.clone(t.copy_text)
			}
```

- [ ] **Step 3: Build and run bridge tests**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: exits 0.
Run: `odin test src/redin/bridge -collection:lib=lib -collection:luajit=vendor/luajit`
Expected: PASS (existing bridge tests still green; `http request failed` lines are normal error-path output).

- [ ] **Step 4: Commit**

```bash
git add src/redin/bridge/bridge.odin
git commit -m "feat(#112): bridge reads :copyable, passes source, clones button strings"
```

---

## Task 4: Input — clipboard write on copy-button click

**Files:**
- Modify: `src/redin/input/input.odin` (`extract_listeners` NodeButton case ~129; `process_user_events` ~309)
- Create: `src/redin/input/copy_button_test.odin`

- [ ] **Step 1: Write the failing helper tests**

Create `src/redin/input/copy_button_test.odin`:
```odin
package input

import "core:testing"
import "../types"

@(test)
test_button_clipboard_text_present :: proc(t: ^testing.T) {
	n := types.NodeButton{copy_text = "hello"}
	text, ok := button_clipboard_text(n)
	testing.expect(t, ok, "button with copy_text must report ok")
	testing.expect_value(t, text, "hello")
}

@(test)
test_button_clipboard_text_absent :: proc(t: ^testing.T) {
	n := types.NodeButton{click = "x/click"}
	text, ok := button_clipboard_text(n)
	testing.expect(t, !ok, "button without copy_text must report not-ok")
	testing.expect_value(t, text, "")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `odin test src/redin/input -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1`
Expected: FAIL — `button_clipboard_text` is undefined (compile error).

- [ ] **Step 3: Add the helper and wire it into the click handler**

In `src/redin/input/input.odin`, add the helper just above `process_user_events`:
```odin
// #112: a button with non-empty copy_text copies that text to the system
// clipboard when clicked. Pure decision, factored out for unit testing.
button_clipboard_text :: proc(n: types.NodeButton) -> (text: string, ok: bool) {
	if len(n.copy_text) > 0 do return n.copy_text, true
	return "", false
}
```
Replace the click loop body in `process_user_events`:
```odin
	for ue in user_events {
		if ue.event != .CLICK do continue
		if ue.node_idx < 0 || ue.node_idx >= len(nodes) do continue
		if btn, ok := nodes[ue.node_idx].(types.NodeButton); ok && len(btn.click) > 0 {
			append(&dispatch, types.Dispatch_Event(types.Click_Event{
				event_name  = btn.click,
				context_ref = btn.click_ctx,
			}))
		}
	}
```
with:
```odin
	for ue in user_events {
		if ue.event != .CLICK do continue
		if ue.node_idx < 0 || ue.node_idx >= len(nodes) do continue
		btn, ok := nodes[ue.node_idx].(types.NodeButton)
		if !ok do continue
		if clip, has := button_clipboard_text(btn); has {   // #112
			cstr := strings.clone_to_cstring(clip, context.temp_allocator)
			rl.SetClipboardText(cstr)
		}
		if len(btn.click) > 0 {
			append(&dispatch, types.Dispatch_Event(types.Click_Event{
				event_name  = btn.click,
				context_ref = btn.click_ctx,
			}))
		}
	}
```

- [ ] **Step 4: Make the copy button hit-testable**

In `extract_listeners`, the `NodeButton` case reads:
```odin
		case types.NodeButton:
			aspect = n.aspect
			if len(n.click) > 0 {
				append(&listeners, types.Listener(types.ClickListener{node_idx = idx}))
			}
```
Change the condition so a copy-only button (no `click`) is still clickable:
```odin
		case types.NodeButton:
			aspect = n.aspect
			if len(n.click) > 0 || len(n.copy_text) > 0 {   // #112
				append(&listeners, types.Listener(types.ClickListener{node_idx = idx}))
			}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `odin test src/redin/input -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1`
Expected: PASS — the two new helper tests plus all existing input tests.

- [ ] **Step 6: Commit**

```bash
git add src/redin/input/input.odin src/redin/input/copy_button_test.odin
git commit -m "feat(#112): copy button writes copy_text to clipboard on click"
```

---

## Task 5: Theme defaults for the copy bar + button

**Files:**
- Modify: `src/runtime/markdown.fnl` (the `set-theme` map inside `M.install`)

- [ ] **Step 1: Add the two aspects**

In `src/runtime/markdown.fnl`, the theme map includes `:md/code {...}`. Add two entries alongside it (before the closing `}` of the map):
```fennel
   :md/copy-bar     {:padding [0 0 8 0]}
   :md/copy-button  {:bg [60 60 70] :color [240 240 240] :radius 4
                     :padding [4 10 4 10] :font :sans :font-size 14}
```

- [ ] **Step 2: Run the Fennel runtime tests**

Run: `luajit test/lua/runner.lua test/lua/test_*.fnl`
Expected: `... passed, 0 failed` (theme install still loads cleanly).

- [ ] **Step 3: Commit**

```bash
git add src/runtime/markdown.fnl
git commit -m "feat(#112): default md/copy-bar and md/copy-button theme aspects"
```

---

## Task 6: UI test — button present + selection disabled

**Files:**
- Modify: `test/ui/redin_test.bb` (add shared `get-selection` helper)
- Modify: `test/ui/test_text_select.bb` (drop now-redundant local `get-selection`)
- Modify: `test/ui/markdown_app.fnl`
- Modify: `test/ui/test_markdown.bb`

- [ ] **Step 1: Add a shared `get-selection` helper to redin-test**

In `test/ui/redin_test.bb`, just below the existing `cursor-kind` helper, add (it reuses the file's `get-json`, which already does authed GET + JSON parse):
```clojure
(defn get-selection
  "Fetch the active selection via GET /selection.
   Returns a map like {:kind \"none\"} or
   {:kind \"text\" :start N :end N :text \"...\"}."
  []
  (get-json "/selection"))
```

- [ ] **Step 2: Remove the duplicate local helper from test_text_select.bb**

`test/ui/test_text_select.bb` already does `(require '[redin-test :refer :all])`, so its file-local `(defn get-selection [] …)` would now shadow the shared one and warn. Delete that local `(defn get-selection …)` block from `test_text_select.bb`; its tests keep working via the referred helper.

- [ ] **Step 3: Add a copyable block to the test app**

In `test/ui/markdown_app.fnl`, the main view's vbox currently holds the `:id :md` markdown and the `:id :sentinel` text. Insert a copyable block between them:
```fennel
    [:markdown {:id :md-copy :aspect :card :width :full :copyable true}
      "# Copyable\n\nThis block has a copy button."]
```
so the vbox children are, in order: `:md` markdown, `:md-copy` markdown, `:sentinel` text.

- [ ] **Step 4: Write the failing UI assertions**

Append to `test/ui/test_markdown.bb` (no local helper needed — `get-selection` now comes from `redin-test`):
```clojure
(deftest copyable-block-renders-copy-button
  (let [btn (find-element {:aspect :md/copy-button})]
    (assert btn "a :copyable markdown block must render an md/copy-button")
    (assert (= "button" (first btn))
            (str "copy affordance must be a button; got " (pr-str (first btn))))))

(deftest non-copyable-block-has-no-copy-button
  ;; The :id :md block is not copyable; with exactly one copyable block in
  ;; the app there must be exactly one copy button total.
  (let [btns (find-elements {:aspect :md/copy-button})]
    (assert (= 1 (count btns))
            (str "expected exactly one copy button; got " (count btns)))))

(deftest clicking-markdown-text-does-not-select
  ;; Lowered markdown text is non-selectable: clicking inside the rendered
  ;; body must leave /selection at {kind:none}, not start a text selection.
  (let [md (find-element {:id :md})
        r  (rect-of md)]
    (assert r (str "markdown wrapper must have a rect; got " (pr-str (frame-attrs md))))
    ;; Click low in the block (body area) to land on paragraph text.
    (click (int (+ (:x r) 20)) (int (+ (:y r) (* 0.7 (:h r)))))
    (wait-ms 120)
    (let [s (get-selection)]
      (assert (= "none" (:kind s))
              (str "markdown text must not be selectable; got selection " (pr-str s))))))
```

- [ ] **Step 5: Build dev binary and run the UI test to verify new assertions pass**

```bash
./build-dev.sh
./build/redin test/ui/markdown_app.fnl &
bb test/ui/run.bb test/ui/test_markdown.bb
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/shutdown
```
Expected: all `test_markdown.bb` tests pass, including the three new ones.

- [ ] **Step 6: Run the text-select suite to confirm the shared helper still works**

```bash
./build/redin test/ui/text_select_app.fnl &
bb test/ui/run.bb test/ui/test_text_select.bb
PORT=$(cat .redin-port); TOKEN=$(cat .redin-token)
curl -s -X POST -H "Authorization: Bearer $TOKEN" http://localhost:$PORT/shutdown
```
Expected: `test_text_select.bb` still passes using the `redin-test` `get-selection`.

- [ ] **Step 7: Commit**

```bash
git add test/ui/redin_test.bb test/ui/test_text_select.bb test/ui/markdown_app.fnl test/ui/test_markdown.bb
git commit -m "test(#112): copy button renders; markdown text not selectable"
```

---

## Task 7: Documentation

**Files:**
- Modify: `docs/core-api.md` (`:markdown` section ~201)
- Modify: `.claude/skills/redin-dev/SKILL.md` (markdown node note)

- [ ] **Step 1: Document `:copyable` in core-api.md**

In the `### \`:markdown\`` section of `docs/core-api.md`, add a paragraph after the attribute description:
```markdown
`:copyable true` (optional, default false) renders a right-aligned **Copy**
button above the rendered content. Clicking it copies the block's verbatim raw
markdown source to the system clipboard. The button is themed via the
`:md/copy-bar` (the right-aligned row) and `:md/copy-button` aspects, both
shipped as framework defaults and overridable with `theme.set-theme`. Note:
rendered markdown text is **not** mouse-selectable — use the copy button to
copy a block.
```

- [ ] **Step 2: Note it in the redin-dev skill**

In `.claude/skills/redin-dev/SKILL.md`, find the markdown note in the "Node types" section (the paragraph describing the `[:markdown ...]` element and `md/*` aspects) and append:
```markdown
Add `:copyable true` to render a top-right Copy button that copies the raw markdown source to the clipboard (aspects `md/copy-bar`, `md/copy-button`); rendered markdown text itself is non-selectable.
```

- [ ] **Step 3: Commit**

```bash
git add docs/core-api.md .claude/skills/redin-dev/SKILL.md
git commit -m "docs(#112): document :copyable markdown attribute + copy aspects"
```

---

## Task 8: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Release build**

Run: `odin build src/cmd/redin -collection:lib=lib -collection:luajit=vendor/luajit -out:build/redin`
Expected: exits 0.

- [ ] **Step 2: Fennel runtime tests**

Run: `luajit test/lua/runner.lua test/lua/test_*.fnl`
Expected: `... passed, 0 failed`.

- [ ] **Step 3: Odin unit tests (changed packages)**

```bash
odin test src/redin/markdown -collection:lib=lib -collection:luajit=vendor/luajit
odin test src/redin/input    -collection:lib=lib -collection:luajit=vendor/luajit -define:ODIN_TEST_THREADS=1
odin test src/redin/bridge   -collection:lib=lib -collection:luajit=vendor/luajit
```
Expected: all PASS.

- [ ] **Step 4: Full UI suite (headless) + leak check**

Run: `bash test/ui/run-all.sh --headless`
Expected: `All test suites passed`; no `leak`/`outstanding` lines (dev build's tracker is active).

- [ ] **Step 5: Visual sanity (optional)**

Run the dev binary on `test/ui/markdown_app.fnl`, `GET /screenshot`, and confirm the copyable block shows a right-aligned Copy button above its content.

- [ ] **Step 6: Push branch and open PR**

```bash
git push -u origin feat/markdown-copy-button
gh pr create --base main --head feat/markdown-copy-button \
  --title "feat(#112): copyable markdown blocks + non-selectable markdown text" \
  --body "Closes #112. Opt-in [:markdown {:copyable true}] renders a top-right Copy button that copies the raw source to the clipboard; lowered markdown text is now non-selectable. See docs/superpowers/specs/2026-06-06-markdown-copy-button-design.md."
```

---

## Self-review notes
- **Spec coverage:** API/opt-in (Task 2,3), placement+full-width right-align (Task 2), copy verbatim source (Task 2,3), host-side clipboard via SetClipboardText (Task 4), `copy_text` field + lifetime/free + clone (Task 1,3), non-selectable text (Task 2), theme aspects (Task 5), tests structural+unit (Task 2,4,6), docs (Task 7), no `/clipboard` endpoint (honored — Task 6 asserts structure only). All covered.
- **Type consistency:** `copy_text` (Task 1) used identically in lower (Task 2), bridge clone (Task 3), input helper (Task 4). `button_clipboard_text` defined and tested in Task 4. `Wrapper_Attrs.copyable` defined Task 2, read Task 3. `lower(blocks, attrs, allocator, source)` ordering consistent between Task 2 definition and Task 3 call.
- **Non-goals honored:** no partial selection, no feedback animation, no hover-reveal, no public `:copy` attribute, no `/clipboard` endpoint.
