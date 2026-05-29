package canvas

import "core:mem"
import "core:testing"

// #182: register clones the provider name as the map key; unregister (and
// re-registration) must free it. Track allocations across a full
// register/re-register/unregister cycle and assert nothing leaks once the
// (empty) registry backing is torn down.
@(test)
test_canvas_register_unregister_frees_key :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	old := context.allocator
	context.allocator = mem.tracking_allocator(&track)
	defer {
		context.allocator = old
		mem.tracking_allocator_destroy(&track)
	}

	// Isolate from the package-global registry for the duration of the test.
	saved := entries
	entries = nil
	defer entries = saved

	register("prov", Canvas_Provider{})
	register("prov", Canvas_Provider{}) // re-register must not leak a second key
	unregister("prov") // must free the cloned key

	// Tear down the now-empty registry; only a leaked key would survive.
	delete(entries)
	entries = nil

	leaks := len(track.allocation_map)
	testing.expectf(
		t,
		leaks == 0,
		"canvas register/re-register/unregister leaked %d allocation(s) (#182)",
		leaks,
	)
}
