extends Window
## Transparent, always-on-top, click-through overlay window. It mirrors the
## screen and draws the loop's visuals (handled by OverlayCanvas). It can also
## enter an interactive "pick" mode where it captures mouse input so the user
## can place action points / rects directly on the screen, like a game engine.

## Preload the canvas script directly so this resolves even when overlay.tscn is
## preloaded early (by main.gd), before the global `class_name` registry exists.
const OverlayCanvasT := preload("res://scripts/overlay_canvas.gd")

enum PickKind { NONE, POINT, RECT }

var canvas: OverlayCanvasT


func _ready() -> void:
	# Native-window flags for a true screen overlay.
	set_flag(Window.FLAG_BORDERLESS, true)
	set_flag(Window.FLAG_ALWAYS_ON_TOP, true)
	set_flag(Window.FLAG_TRANSPARENT, true)
	set_flag(Window.FLAG_NO_FOCUS, true)
	set_flag(Window.FLAG_MOUSE_PASSTHROUGH, true)
	transparent_bg = true

	canvas = OverlayCanvasT.new()
	add_child(canvas)
	# When the canvas finishes/cancels a pick, restore the click-through flags.
	canvas.point_picked.connect(func(_g): end_pick())
	canvas.rect_picked.connect(func(_r): end_pick())
	canvas.pick_canceled.connect(func(): end_pick())
	_fit_to_screen()


func _fit_to_screen() -> void:
	# Cover the entire virtual desktop (all displays), so picks and guides use
	# true global screen-space regardless of which monitor the target app is on.
	var desktop := _virtual_desktop_rect()
	position = desktop.position
	size = desktop.size
	# The canvas is anchored top-left; size it explicitly to cover the screen.
	if canvas != null:
		canvas.position = Vector2.ZERO
		canvas.size = Vector2(desktop.size)
		canvas.queue_redraw()


func _virtual_desktop_rect() -> Rect2i:
	var count := DisplayServer.get_screen_count()
	if count <= 0:
		return Rect2i(Vector2i.ZERO, Vector2i(1280, 720))

	var min_x := 2147483647
	var min_y := 2147483647
	var max_x := -2147483648
	var max_y := -2147483648

	for screen in count:
		var pos := DisplayServer.screen_get_position(screen)
		var sz := DisplayServer.screen_get_size(screen)
		min_x = mini(min_x, pos.x)
		min_y = mini(min_y, pos.y)
		max_x = maxi(max_x, pos.x + sz.x)
		max_y = maxi(max_y, pos.y + sz.y)

	return Rect2i(Vector2i(min_x, min_y), Vector2i(maxi(1, max_x - min_x), maxi(1, max_y - min_y)))


func show_overlay() -> void:
	_fit_to_screen()
	show()
	# Re-assert flags some platforms reset on show.
	set_flag(Window.FLAG_ALWAYS_ON_TOP, true)
	set_flag(Window.FLAG_MOUSE_PASSTHROUGH, true)
	if canvas != null:
		canvas.queue_redraw()
	# Some drivers leave the first frame of a freshly-shown transparent window
	# blank; nudge a redraw a couple of frames later so content composites.
	_nudge_redraw()


func _nudge_redraw() -> void:
	for i in 3:
		await get_tree().process_frame
		if canvas != null:
			canvas.queue_redraw()


# ----------------------------------------------------------------- picking
## Make the overlay interactive so the user can click/drag to place a point or
## rectangle on the screen. The canvas emits point_picked / rect_picked.
func begin_pick(kind: int) -> void:
	_fit_to_screen()
	show()
	# Stay click-through and non-focus so the user can click the real target
	# window beneath the overlay while we still observe global mouse state.
	set_flag(Window.FLAG_MOUSE_PASSTHROUGH, true)
	set_flag(Window.FLAG_NO_FOCUS, true)
	set_flag(Window.FLAG_ALWAYS_ON_TOP, true)
	if canvas != null:
		canvas.begin_pick(kind)


func end_pick() -> void:
	# Return to a transparent, click-through overlay.
	set_flag(Window.FLAG_MOUSE_PASSTHROUGH, true)
	set_flag(Window.FLAG_NO_FOCUS, true)
	if canvas != null:
		canvas.end_pick()


func is_picking() -> bool:
	return canvas != null and canvas.pick_mode != PickKind.NONE


func _input(event: InputEvent) -> void:
	# Allow Esc to cancel an in-progress pick (key events go to the focused
	# window, which is this overlay while picking).
	if not is_picking():
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		canvas.cancel_pick()
		get_viewport().set_input_as_handled()



func hide_overlay() -> void:
	hide()
