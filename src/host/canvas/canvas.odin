// src/host/canvas/canvas.odin
package canvas

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
	provider:  Canvas_Provider,
	lifecycle: Canvas_Lifecycle,
	visited:   bool,
}

entries: map[string]Canvas_Entry
current_name: string

register :: proc(name: string, provider: Canvas_Provider) {
	if existing, ok := entries[name]; ok {
		if existing.provider.stop != nil {
			existing.provider.stop()
		}
	}
	entries[name] = Canvas_Entry {
		provider  = provider,
		lifecycle = .Idle,
		visited   = false,
	}
}

unregister :: proc(name: string) {
	if entry, ok := entries[name]; ok {
		if entry.provider.stop != nil {
			entry.provider.stop()
		}
		delete_key(&entries, name)
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
	}
	delete(entries)
}
