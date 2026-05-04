package main

// Compile-time flag enabling the tracking allocator. Default is false;
// set with `odin build ... -define:REDIN_TRACK_MEM=true`. When false,
// the tracker setup and leak dump compile out to zero bytes.
REDIN_TRACK_MEM :: #config(REDIN_TRACK_MEM, false)

import "core:fmt"
import "core:mem"
import "core:os"
import redin "../../redin"

main :: proc() {
	cfg: redin.Config
	for arg in os.args[1:] {
		cfg.app = arg
	}

	when REDIN_TRACK_MEM {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		fmt.eprintln("Memory tracking enabled (REDIN_TRACK_MEM)")
		// Assign at proc scope. Odin's `context` is block-scoped: setting
		// context.allocator inside an `if` block reverts when the block
		// ends, so the tracker never reaches `redin.run` and reports zero
		// activity. Compile-time `when` inlines its body at proc scope, so
		// this assignment IS at effective proc scope when the flag is true.
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

	redin.run(cfg)
}
