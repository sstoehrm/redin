# Canvas Provider Reference

Independent render regions driven by Odin-side providers. Fennel declares canvas elements in the frame tree; providers handle all rendering using Raylib directly.

---

## Registration

Providers register at runtime in Odin:

```odin
import "canvas"

canvas.register("my-canvas", canvas.Canvas_Provider{
    start   = my_start,
    update  = my_update,
    suspend = my_suspend,
    stop    = my_stop,
})
```

The first argument is the provider name string; it must match the `provider` attribute on the canvas element. All four callbacks are function pointers -- set to `nil` if not needed.

Registering the same name twice stops the previous provider first. Unregister with `canvas.unregister("my-canvas")`.

---

## Canvas element

```fennel
[:canvas {:provider :my-canvas :aspect :my-canvas-chrome :width 400 :height 300}]
```

The `provider` attribute links the element to its registered provider. `width` and `height` set the element size in pixels. `aspect` provides visual chrome (background, border, radius, padding) -- the provider draws inside the padded inner rect.

---

## Lifecycle

| Callback | Signature | When called |
|----------|-----------|-------------|
| `start` | `proc(rect: rl.Rectangle)` | Canvas appears in the frame tree (or re-appears after suspend). Receives the inner rect. |
| `update` | `proc(rect: rl.Rectangle)` | Every frame while the canvas is visible. Receives the current inner rect. Draw here. |
| `suspend` | `proc()` | Canvas disappears from the frame tree but provider remains registered. May return. |
| `stop` | `proc()` | Provider is unregistered. Final cleanup. |

### State transitions

```
Idle --> Running --> Suspended --> Running --> ...
                                 \--> stop() (on unregister)
```

- **Idle**: registered but never appeared in the frame tree.
- **Running**: in the frame tree. `update` called every frame.
- **Suspended**: was running, left the frame tree, may return.

When a canvas reappears after being suspended, `start` is called again before the first `update`.

---

## Drawing

Providers draw directly using Raylib calls during `update`. The provider has full access to Raylib's API -- 2D drawing, Camera2D, Camera3D, scissor mode, shaders, etc.

For sub-region rendering, use `rl.BeginScissorMode` to clip to the rect, then `rl.BeginMode2D` or `rl.BeginMode3D` for camera control. Providers manage their own cameras and state.

### Example: 2D panning viewport

```odin
import rl "vendor:raylib"
import "canvas"

camera: rl.Camera2D

my_start :: proc(rect: rl.Rectangle) {
    camera = rl.Camera2D{
        target = {0, 0},
        offset = {rect.width / 2, rect.height / 2},
        zoom   = 1,
    }
}

my_update :: proc(rect: rl.Rectangle) {
    // Update camera offset to match current rect position
    camera.offset = {rect.x + rect.width / 2, rect.y + rect.height / 2}

    rl.BeginScissorMode(i32(rect.x), i32(rect.y), i32(rect.width), i32(rect.height))
    rl.BeginMode2D(camera)

    // Draw world-space content
    rl.DrawCircleV({0, 0}, 20, rl.RED)
    rl.DrawRectangle(-50, -50, 100, 100, rl.BLUE)

    rl.EndMode2D()
    rl.EndScissorMode()
}

my_suspend :: proc() {}
my_stop :: proc() {}
```

Register it:

```odin
canvas.register("my-viewport", canvas.Canvas_Provider{
    start   = my_start,
    update  = my_update,
    suspend = my_suspend,
    stop    = my_stop,
})
```

Use in a frame:

```fennel
[:canvas {:provider :my-viewport :aspect :viewport-chrome :width 800 :height 600}]
```

---

## Theme properties

Canvas elements consume these aspect properties for chrome (drawn by the renderer before the provider):

| Property | Purpose |
|----------|---------|
| `bg` | Background fill |
| `border` | Border color |
| `border-width` | Border thickness |
| `radius` | Corner rounding |
| `padding` | Inset between chrome and provider drawing area |
| `opacity` | Element opacity |

---

## Notes

- Provider names are global -- two registrations with the same name, the second wins (previous provider is stopped).
- Providers manage their own state, cameras, and resources. The canvas system only handles lifecycle and rect delivery.
- Drawing calls outside `update` are not scoped to any canvas rect -- providers must use `BeginScissorMode` to clip.
- The canvas element is a leaf: child frames inside it are rejected by the validator.
- If no provider is registered for a canvas element, a gray placeholder is drawn.
