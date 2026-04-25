package main

import "core:fmt"
import "core:mem"
import "core:os"
import redin "../../redin"

main :: proc() {
	cfg: redin.Config
	track_mem := false
	for arg in os.args[1:] {
		switch arg {
		case "--dev":       cfg.dev = true
		case "--track-mem": track_mem = true
		case "--profile":   cfg.profile = true
		case:               cfg.app = arg
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

	redin.run(cfg)
}
