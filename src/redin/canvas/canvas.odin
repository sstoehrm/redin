// src/redin/canvas/canvas.odin
package canvas

// Same compile-time flag declared in bridge — Odin's `#config` reads
// the same -define value regardless of which package declares it, so
// this stays in lockstep without a cross-package import.
REDIN_DEV :: #config(REDIN_DEV, false)

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

Canvas_Provider :: struct {
	start:   proc(rect: rl.Rectangle),
	update:  proc(rect: rl.Rectangle),
	suspend: proc(),
	stop:    proc(),
}

Canvas_Lifecycle :: enum {
	Idle,
	Running,
	Suspended,
}

Canvas_Entry :: struct {
	provider:   Canvas_Provider,
	lifecycle:  Canvas_Lifecycle,
	visited:    bool,
	name_owned: string, // #182: heap-owned map key; freed on unregister/destroy
}

entries: map[string]Canvas_Entry
current_name: string

register :: proc(name: string, provider: Canvas_Provider) {
	if existing, ok := &entries[name]; ok {
		when REDIN_DEV {
			fmt.eprintfln("redin: warn: canvas.register(%q) replaces an existing provider", name)
		}
		if existing.provider.stop != nil {
			existing.provider.stop()
		}
		// #182: reuse the existing owned key; only the value changes. (The
		// incoming `name` is transient — Odin keeps the original map key on
		// assignment to an existing slot — so storing it would dangle and
		// re-cloning it would leak.)
		existing.provider = provider
		existing.lifecycle = .Idle
		existing.visited = false
		return
	}
	// #182: own the key so it can be freed on unregister/destroy. Callers
	// pass a transient name.
	owned := strings.clone(name)
	entries[owned] = Canvas_Entry {
		provider   = provider,
		lifecycle  = .Idle,
		visited    = false,
		name_owned = owned,
	}
}

unregister :: proc(name: string) {
	if entry, ok := entries[name]; ok {
		if entry.provider.stop != nil {
			entry.provider.stop()
		}
		// #182: free the heap-owned key; delete_key only erases the slot.
		key := entry.name_owned
		delete_key(&entries, name)
		delete(key)
	}
}

// Called by render.odin when it hits a NodeCanvas.
// Handles lifecycle transitions and calls update.
process :: proc(provider_name: string, rect: rl.Rectangle) {
	entry, ok := &entries[provider_name]
	if !ok do return
	current_name = provider_name

	switch entry.lifecycle {
	case .Idle, .Suspended:
		if entry.provider.start != nil {
			entry.provider.start(rect)
		}
		entry.lifecycle = .Running
		if entry.provider.update != nil {
			entry.provider.update(rect)
		}
	case .Running:
		if entry.provider.update != nil {
			entry.provider.update(rect)
		}
	}
	entry.visited = true
}

// Called once after the render pass. Suspends any Running provider
// that was not visited this frame, then resets all visited flags.
end_frame :: proc() {
	for _, &entry in entries {
		if entry.lifecycle == .Running && !entry.visited {
			if entry.provider.suspend != nil {
				entry.provider.suspend()
			}
			entry.lifecycle = .Suspended
		}
		entry.visited = false
	}
}

// Called on shutdown. Stops all providers and clears the registry.
destroy :: proc() {
	for _, &entry in entries {
		if entry.provider.stop != nil {
			entry.provider.stop()
		}
		// #182: keys are heap-cloned in `register` (name_owned); free each.
		delete(entry.name_owned)
	}
	delete(entries)
}
