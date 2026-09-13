extends RefCounted
class_name InputBackend
## Abstract interface that turns LoopActions into real input.
## Concrete backends implement OS-specific behaviour.

func backend_name() -> String:
	return "Abstract"

## True if this backend can actually drive the OS (vs. preview-only).
func is_real() -> bool:
	return false

func move_to(pos: Vector2i) -> void:
	pass

func mouse_button(_button: int, _pressed: bool, _pos: Vector2i) -> void:
	pass

func click(button: int, pos: Vector2i) -> void:
	mouse_button(button, true, pos)
	mouse_button(button, false, pos)

func send_keys(_text: String) -> void:
	pass

## Returns the colour of a single screen pixel, or a transparent colour
## if the backend cannot read the screen.
func get_pixel(_pos: Vector2i) -> Color:
	return Color(0, 0, 0, 0)

## Returns the screen contents of `rect` as an image (RGB, one texel per screen
## pixel), or null if the backend cannot read the screen.
func read_rect(_rect: Rect2i) -> Image:
	return null

## Returns where the mouse cursor is right now (screen coordinates), or
## (-1, -1) if the backend cannot tell.
func get_cursor_pos() -> Vector2i:
	return Vector2i(-1, -1)


## Runs a whole "Captures" mouse action as one unit: remember where the cursor
## is, do the action, put the cursor back. Backends do this as atomically as
## they can so the cursor is away for as short a time as possible.
##   kind: "move" (dwell `ms` at `from`), "click" (`button` at `from`), or
##         "drag" (`button` from `from` to `to`, holding `ms`).
##   compensate: add any distance the user moved the mouse meanwhile to the
##         restored position, so their own movement is not thrown away.
## Blocks for the whole action (callers run it off the main thread). Returns
## [saved_pos, restored_pos], or [] if the action could not be performed.
func run_captured(_kind: String, _button: int, _from: Vector2i, _to: Vector2i, _ms: int, _compensate: bool) -> Array:
	return []
