package input

// #225 L5: a mid-drag re-flatten can leave over_zone_idx / over_drop_idx
// pointing at a different node than the one entered. drag_over_idx_valid /
// dropable_idx_valid revalidate a stored index against the current frame's
// listeners (node identity + tag overlap) so no :leave fires against the
// wrong node. These tests pin that predicate.

import "core:testing"
import "../types"

@(test)
test_drag_over_idx_valid_matches :: proc(t: ^testing.T) {
	tags := []string{"row-drag"}
	listeners := []types.Listener{
		types.DragOverListener{node_idx = 4, tags = []string{"row-drag"}},
	}
	// Same index, overlapping tags → still our zone.
	testing.expect(t, drag_over_idx_valid(4, tags, listeners))
}

@(test)
test_drag_over_idx_valid_index_reused_by_other_zone :: proc(t: ^testing.T) {
	// After a re-flatten, index 4 is now a drag-over zone with a
	// non-overlapping tag set — not our zone; must be rejected.
	tags := []string{"row-drag"}
	listeners := []types.Listener{
		types.DragOverListener{node_idx = 4, tags = []string{"palette"}},
	}
	testing.expect(t, !drag_over_idx_valid(4, tags, listeners))
}

@(test)
test_drag_over_idx_valid_index_gone :: proc(t: ^testing.T) {
	// The zone that was at index 4 no longer exists (shrunk / reshuffled
	// tree): no DragOverListener carries that index.
	tags := []string{"row-drag"}
	listeners := []types.Listener{
		types.DragOverListener{node_idx = 2, tags = []string{"row-drag"}},
	}
	testing.expect(t, !drag_over_idx_valid(4, tags, listeners))
}

@(test)
test_dropable_idx_valid :: proc(t: ^testing.T) {
	tags := []string{"row-drag"}
	listeners := []types.Listener{
		types.DropListener{node_idx = 7, tags = []string{"row-drag", "sword"}},
		types.DropListener{node_idx = 8, tags = []string{"other"}},
	}
	testing.expect(t, dropable_idx_valid(7, tags, listeners), "overlapping tags at the index")
	testing.expect(t, !dropable_idx_valid(8, tags, listeners), "non-overlapping tags")
	testing.expect(t, !dropable_idx_valid(9, tags, listeners), "no listener at the index")
}
