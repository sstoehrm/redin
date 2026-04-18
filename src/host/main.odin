package host

import "bridge"
import "canvas"
import "core:fmt"
import "core:mem"
import "core:os"
import "font"
import "input"
import "types"
import rl "vendor:raylib"

main :: proc() {
	dev_mode := false
	track_mem := false
	app_file := ""
	for arg in os.args[1:] {
		if arg == "--dev" {
			dev_mode = true
		} else if arg == "--track-mem" {
			track_mem = true
		} else {
			app_file = arg
		}
	}

	track: mem.Tracking_Allocator
	if track_mem {
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		fmt.eprintln("Memory tracking enabled (--track-mem)")
	}
	defer if track_mem {
		if len(track.allocation_map) > 0 {
			fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
			for _, entry in track.allocation_map {
				fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
			}
		}
		if len(track.bad_free_array) > 0 {
			fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
			for entry in track.bad_free_array {
				fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
			}
		}
		mem.tracking_allocator_destroy(&track)
	}

	// WINDOW_HIGHDPI is intentionally off until Odin ships Raylib 5.6+
	// with raysan5/raylib#4836 — on HiDPI displays the viewport is not
	// re-scaled after a resize, leaving most of the framebuffer black.
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT})
	rl.InitWindow(1280, 800, "redin")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	font.init()
	defer font.destroy()

	b: bridge.Bridge
	bridge.init(&b, dev_mode)
	defer bridge.destroy(&b)
	defer canvas.destroy()

	bridge.load_app(&b, app_file)

	input.state_init()
	defer input.state_destroy()

	listeners: [dynamic]types.Listener
	defer delete(listeners)

	for !rl.WindowShouldClose() && !bridge.is_shutdown_requested(&b) {
		free_all(context.temp_allocator)
		bridge.check_hotreload(&b)

		if b.frame_changed {
			delete(listeners)
			listeners = input.extract_listeners(b.paths, b.nodes, b.theme)
		}

		input_events := input.poll()
		defer delete(input_events)

		bridge.poll_devserver(&b, &input_events)
		bridge.deliver_events(&b, input_events[:])
		bridge.poll_http(&b)
		bridge.poll_shell(&b)
		bridge.render_tick(&b)
		bridge.poll_timers(&b)

		user_events := input.get_user_events(input_events, listeners, node_rects[:])
		defer delete(user_events)

		applied_events := input.apply_listeners(listeners, input_events, node_rects[:])
		defer delete(applied_events)

		// Handle focus changes for input state
		for ae in applied_events {
			switch a in ae {
			case types.ApplyFocus:
				if a.idx < len(b.nodes) {
					if n, ok := b.nodes[a.idx].(types.NodeInput); ok {
						input.focus_enter(n.value)
					} else {
						input.focus_leave()
					}
				}
			case types.ApplyActive:
			}
		}
		// If focus was cleared (click outside), leave input state
		if input.state.active && input.focused_idx < 0 {
			input.focus_leave()
		}

		// Process drag state machine
		drag_events := input.process_drag(
			input_events[:], listeners[:], b.nodes[:], node_rects[:],
		)
		defer delete(drag_events)
		bridge.deliver_dispatch_events(&b, drag_events[:])

		dispatch_events := input.process_user_events(
			user_events[:], input_events[:], b.nodes[:], node_rects[:], b.theme,
		)
		defer delete(dispatch_events)
		bridge.deliver_dispatch_events(&b, dispatch_events[:])

		apply_scroll_events(input_events[:], b.nodes[:])

		rl.BeginDrawing()
		rl.ClearBackground({255, 255, 255, 255})

		render_tree(b.theme, b.nodes[:], b.children_list[:])
		canvas.end_frame()

		rl.EndDrawing()
	}
}
