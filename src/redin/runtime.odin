package redin

import "bridge"
import "canvas"
import "core:fmt"
import "font"
import "input"
import "profile"
import "types"
import rl "vendor:raylib"

// ---------------------------------------------------------------------------
// Public configuration
// ---------------------------------------------------------------------------

Config :: struct {
	app:     string,
	dev:     bool,
	profile: bool,
}

// Hook callback types. Hooks are typed as default-convention `proc()` so
// Odin's context auto-propagates from `run`'s frame — no `proc "c"` and no
// manual `context = ...` ceremony required in user code.
On_Init_Proc     :: #type proc()
On_Input_Proc    :: #type proc(events: []types.InputEvent) -> []types.InputEvent
On_Frame_Proc    :: #type proc()
On_Shutdown_Proc :: #type proc()

// ---------------------------------------------------------------------------
// Internal state (file-private)
// ---------------------------------------------------------------------------

@(private = "file")
Window_Config :: struct {
	width, height: i32,
	title:         cstring,
	flags:         rl.ConfigFlags,
}

// WINDOW_HIGHDPI is intentionally off until Odin ships Raylib 5.6+ with
// raysan5/raylib#4836 — on HiDPI displays the viewport is not re-scaled
// after a resize, leaving most of the framebuffer black.
@(private = "file")
g_window_config := Window_Config {
	width  = 1280,
	height = 800,
	title  = "redin",
	flags  = {.WINDOW_RESIZABLE, .MSAA_4X_HINT},
}

@(private = "file")
g_run_started: bool

@(private = "file")
g_user_requested_shutdown: bool

@(private = "file")
g_on_init: On_Init_Proc

@(private = "file")
g_on_input: On_Input_Proc

@(private = "file")
g_on_frame: On_Frame_Proc

@(private = "file")
g_on_shutdown: On_Shutdown_Proc

// ---------------------------------------------------------------------------
// Public API: window configuration
// ---------------------------------------------------------------------------

// Configure the window. Call before `run`. Calling after `run` has started
// logs an error to stderr and is ignored.
set_window :: proc(width, height: i32, title: cstring, flags: rl.ConfigFlags) {
	if g_run_started {
		fmt.eprintln("redin: error: set_window called after run; ignored. Call before redin.run().")
		return
	}
	g_window_config.width = width
	g_window_config.height = height
	g_window_config.title = title
	g_window_config.flags = flags
}

// Resize the window at runtime. Call after `run` has started. Calling
// before `run` logs an error to stderr and is ignored.
//
// Named `set_size` (not `resize`) to avoid shadowing the auto-imported
// `runtime.resize` builtin used inside render.odin.
set_size :: proc(width, height: i32) {
	if !g_run_started {
		fmt.eprintln("redin: error: set_size called before run; use set_window. Ignored.")
		return
	}
	rl.SetWindowSize(width, height)
}

// Update the window title at runtime.
set_title :: proc(title: cstring) {
	if !g_run_started {
		fmt.eprintln("redin: error: set_title called before run; use set_window. Ignored.")
		return
	}
	rl.SetWindowTitle(title)
}

// ---------------------------------------------------------------------------
// Public API: hooks
// ---------------------------------------------------------------------------

on_init     :: proc(fn: On_Init_Proc)     { g_on_init = fn }
on_input    :: proc(fn: On_Input_Proc)    { g_on_input = fn }
on_frame    :: proc(fn: On_Frame_Proc)    { g_on_frame = fn }
on_shutdown :: proc(fn: On_Shutdown_Proc) { g_on_shutdown = fn }

// ---------------------------------------------------------------------------
// Public API: shutdown
// ---------------------------------------------------------------------------

// Request a graceful shutdown. The render loop exits at the start of the
// next iteration. Same flag the dev server's POST /shutdown endpoint uses.
request_shutdown :: proc() {
	g_user_requested_shutdown = true
}

// ---------------------------------------------------------------------------
// Public API: run
// ---------------------------------------------------------------------------

// Block until the window closes or `request_shutdown` is called. Sets up
// the window, bridge, and dev server (if cfg.dev), then runs the loop.
//
// Per-frame call order:
//   poll_input -> on_input(filter) -> bridge tick -> on_frame -> render
run :: proc(cfg: Config) {
	g_run_started = true
	defer g_run_started = false
	defer g_user_requested_shutdown = false

	rl.SetConfigFlags(g_window_config.flags)
	rl.InitWindow(g_window_config.width, g_window_config.height, g_window_config.title)
	defer rl.CloseWindow()
	rl.SetTargetFPS(120)
	// Disable Raylib's default Escape-closes-window behavior. Apps own the
	// Escape key (drag-cancel, modal-dismiss, etc.); the window closes via
	// the close button or `redin.request_shutdown()`.
	rl.SetExitKey(.KEY_NULL)

	font.init()
	defer font.destroy()

	profile.init(cfg.profile)

	canvas.set_dev_mode(cfg.dev)

	b: bridge.Bridge
	bridge.init(&b, cfg.dev)
	defer bridge.destroy(&b)
	defer canvas.destroy()

	bridge.load_app(&b, cfg.app)

	input.state_init()
	defer input.state_destroy()

	if g_on_init != nil {
		g_on_init()
	}
	defer if g_on_shutdown != nil {
		g_on_shutdown()
	}

	listeners: [dynamic]types.Listener
	defer delete(listeners)

	for !rl.WindowShouldClose() &&
	    !bridge.is_shutdown_requested(&b) &&
	    !g_user_requested_shutdown {
		profile.begin_frame()

		free_all(context.temp_allocator)
		bridge.check_hotreload(&b)

		if b.frame_changed {
			delete(listeners)
			listeners = input.extract_listeners(b.paths, b.nodes, b.theme)
		}

		// --- Input (1/4): raw poll + user filter ---
		s_input1 := profile.begin(.Input)
		input_events := input.poll()
		profile.end(s_input1)
		defer delete(input_events)

		if g_on_input != nil {
			filtered := g_on_input(input_events[:])
			// User may return a fresh slice or a sub-slice. Replace the
			// dynamic array contents with their result.
			clear(&input_events)
			append(&input_events, ..filtered)
		}

		// --- Devserver: drain pending HTTP requests ---
		s_ds := profile.begin(.Devserver)
		bridge.poll_devserver(&b, &input_events, node_rects[:])
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
		input.set_hover_cursor(listeners[:], node_rects[:])
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

		// --- User per-frame hook (non-visual native work) ---
		if g_on_frame != nil {
			g_on_frame()
		}

		rl.BeginDrawing()
		rl.ClearBackground({255, 255, 255, 255})

		s_layout := profile.begin(.Layout)
		layout_tree(b.theme, b.nodes[:], b.children_list[:])
		profile.end(s_layout)

		input.resolve_text_selection(b.paths[:], b.nodes[:])
		g_paths = b.paths[:]

		s_render := profile.begin(.Render)
		draw_tree(b.theme, b.nodes[:], b.children_list[:])
		render_drag_preview(b.nodes[:], b.children_list[:], b.theme)
		profile.end(s_render)

		profile.draw_overlay()

		canvas.end_frame()
		rl.EndDrawing()

		profile.end_frame()
	}
}
