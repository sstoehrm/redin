package bridge

import rl "vendor:raylib"

// Scissor stack — raylib's BeginScissorMode / EndScissorMode operate on
// a single global scissor state (no stack), so nested Begin/End pairs in
// independent render paths tear each other down. The renderer uses four
// such pairs (scrollable container, draw_input, draw_text-with-clip,
// execute_canvas_commands), and at least one nests inside the others in
// every non-trivial layout. The stack here lets push/pop callers compose
// safely: each push intersects with the current top, each pop re-applies
// the new top (or disables scissor when the stack empties).
//
// Lives in package bridge because both render.odin (package redin) and
// bridge.odin (the canvas command executor) need to call it, and bridge
// is below redin in the import graph — putting it here avoids a cycle.

@(private="package")
scissor_stack: [dynamic]rl.Rectangle

push_scissor :: proc(rect: rl.Rectangle) {
	effective := rect
	if len(scissor_stack) > 0 {
		effective = scissor_intersect(effective, scissor_stack[len(scissor_stack) - 1])
	}
	append(&scissor_stack, effective)
	rl.BeginScissorMode(
		i32(effective.x), i32(effective.y),
		i32(effective.width), i32(effective.height),
	)
}

pop_scissor :: proc() {
	if len(scissor_stack) == 0 do return
	pop(&scissor_stack)
	if len(scissor_stack) > 0 {
		r := scissor_stack[len(scissor_stack) - 1]
		rl.BeginScissorMode(i32(r.x), i32(r.y), i32(r.width), i32(r.height))
	} else {
		rl.EndScissorMode()
	}
}

// Safety net for frame-start: callers that forgot to pop don't leak
// their scissor into the next frame's draws. Render runtime calls this
// once at the top of each frame, before any push.
reset_scissor :: proc() {
	if len(scissor_stack) > 0 {
		clear(&scissor_stack)
		rl.EndScissorMode()
	}
}

destroy_scissor :: proc() {
	delete(scissor_stack)
	scissor_stack = nil
}

scissor_intersect :: proc(a, b: rl.Rectangle) -> rl.Rectangle {
	x := max(a.x, b.x)
	y := max(a.y, b.y)
	r := min(a.x + a.width, b.x + b.width)
	bo := min(a.y + a.height, b.y + b.height)
	w := max(0, r - x)
	h := max(0, bo - y)
	return rl.Rectangle{x, y, w, h}
}
