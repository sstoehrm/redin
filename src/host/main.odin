package host

import "bridge"
import "canvas"
import "core:fmt"
import "core:mem"
import "core:os"
import "font"
import "input"
import "profile"
import "types"
import rl "vendor:raylib"

main :: proc() {
	dev_mode := false
	track_mem := false
	profile_mode := false
	app_file := ""
	for arg in os.args[1:] {
		switch arg {
		case "--dev":        dev_mode = true
		case "--track-mem":  track_mem = true
		case "--profile":    profile_mode = true
		case:                app_file = arg
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
	rl.SetTargetFPS(120)

	font.init()
	defer font.destroy()

	profile.init(profile_mode)

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
		profile.begin_frame()

		free_all(context.temp_allocator)
		bridge.check_hotreload(&b)

		if b.frame_changed {
			delete(listeners)
			listeners = input.extract_listeners(b.paths, b.nodes, b.theme)
		}

		// --- Input (1/4): raw poll ---
		s_input1 := profile.begin(.Input)
		input_events := input.poll()
		profile.end(s_input1)
		defer delete(input_events)

		// --- Devserver: drain pending HTTP requests ---
		s_ds := profile.begin(.Devserver)
		bridge.poll_devserver(&b, &input_events)
		profile.end(s_ds)

		// --- Bridge: all Lua-side work ---
		s_br1 := profile.begin(.Bridge)
		bridge.deliver_events(&b, input_events[:])
		bridge.poll_http(&b)
		bridge.poll_shell(&b)
		bridge.render_tick(&b)
		bridge.poll_timers(&b)
		profile.end(s_br1)

		// --- Input (2/4): listener / focus / drag computation ---
		s_input2a := profile.begin(.Input)
		user_events := input.get_user_events(input_events, listeners, node_rects[:])
		defer delete(user_events)
		applied_events := input.apply_listeners(listeners, input_events, node_rects[:])
		defer delete(applied_events)

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
		if input.state.active && input.focused_idx < 0 {
			input.focus_leave()
		}

		drag_events := input.process_drag(
			input_events[:], listeners[:], b.nodes[:], node_rects[:],
		)
		defer delete(drag_events)

		input.process_text_selection(input_events[:], listeners[:], b.nodes[:], b.paths[:], node_rects[:], b.theme)
		profile.end(s_input2a)

		// --- Bridge: deliver drag events (Lua may mutate state before user events) ---
		s_br2 := profile.begin(.Bridge)
		bridge.deliver_dispatch_events(&b, drag_events[:])
		profile.end(s_br2)

		// --- Input (3/4): user-event computation ---
		s_input2b := profile.begin(.Input)
		dispatch_events := input.process_user_events(
			user_events[:], input_events[:], b.nodes[:], b.paths[:], node_rects[:], b.theme,
		)
		defer delete(dispatch_events)
		profile.end(s_input2b)

		// --- Bridge: deliver user events (Lua may mutate state before scroll apply) ---
		s_br3 := profile.begin(.Bridge)
		bridge.deliver_dispatch_events(&b, dispatch_events[:])
		profile.end(s_br3)

		// --- Input (4/4): scroll application ---
		s_input2c := profile.begin(.Input)
		apply_scroll_events(input_events[:], b.nodes[:])
		profile.end(s_input2c)

		rl.BeginDrawing()
		rl.ClearBackground({255, 255, 255, 255})

		s_layout := profile.begin(.Layout)
		layout_tree(b.theme, b.nodes[:], b.children_list[:])
		profile.end(s_layout)

		input.resolve_text_selection(b.paths[:], b.nodes[:])
		g_paths = b.paths[:]

		s_render := profile.begin(.Render)
		draw_tree(b.theme, b.nodes[:], b.children_list[:])
		profile.end(s_render)

		profile.draw_overlay()

		canvas.end_frame()
		rl.EndDrawing()

		profile.end_frame()
	}
}
