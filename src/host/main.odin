package host

import "bridge"
import "canvas"
import "core:fmt"
import "core:mem"
import "core:os"
import "input"
import "types"
import rl "vendor:raylib"

main :: proc() {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)

		defer {
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
	}

	dev_mode := false
	app_file := ""
	for arg in os.args[1:] {
		if arg == "--dev" {
			dev_mode = true
		} else {
			app_file = arg
		}
	}

	rl.SetConfigFlags({.WINDOW_RESIZABLE, .WINDOW_HIGHDPI, .MSAA_4X_HINT})
	rl.InitWindow(1280, 800, "redin")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	b: bridge.Bridge
	bridge.init(&b, dev_mode)
	defer bridge.destroy(&b)
	defer canvas.destroy()

	bridge.load_app(&b, app_file)

	listeners: [dynamic]types.Listener
	defer delete(listeners)

	for !rl.WindowShouldClose() && !bridge.is_shutdown_requested(&b) {
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
		bridge.render_tick(&b)
		bridge.poll_timers(&b)

		user_events := input.get_user_events(input_events, listeners, node_rects[:])
		defer delete(user_events)

		applied_events := input.apply_listeners(listeners, input_events, node_rects[:])
		defer delete(applied_events)

		rl.BeginDrawing()
		rl.ClearBackground({255, 255, 255, 255})

		render_tree(b.theme, b.nodes[:], b.children_list[:])
		canvas.end_frame()

		rl.EndDrawing()
	}
}
