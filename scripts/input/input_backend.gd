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
