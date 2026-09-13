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


# ------------------------------------------------- user-motion tracking
## Lag compensation for "Captures": a real backend takes time between cursor
## sets, and any distance the user moves the mouse in those gaps would be
## thrown away by the restore. While tracking, backends call
## `_note_cursor_set()` with where the cursor was just before each set, and
## the gaps add up in `user_motion`.
var _tracking_motion: bool = false
var _expected_cursor: Vector2i = Vector2i.ZERO
var user_motion: Vector2i = Vector2i.ZERO

## Starts tracking; `from` is where the cursor is known to be right now.
func begin_motion_tracking(from: Vector2i) -> void:
	_tracking_motion = true
	_expected_cursor = from
	user_motion = Vector2i.ZERO

## Adds the motion since the last set, stops tracking, and returns the total
## distance the user moved the mouse while tracking was on.
func end_motion_tracking() -> Vector2i:
	if _tracking_motion:
		_note_cursor_set(get_cursor_pos(), _expected_cursor)
		_tracking_motion = false
	return user_motion

## Backends call this on every cursor set: `prior` is where the cursor was
## right before the set ((-1, -1) if unknown), `set_to` where it went.
func _note_cursor_set(prior: Vector2i, set_to: Vector2i) -> void:
	if not _tracking_motion:
		return
	if prior != Vector2i(-1, -1):
		user_motion += prior - _expected_cursor
	_expected_cursor = set_to
