extends Window
## Interactive, full-screen "pick" window shown while the user places a point
## or a rectangle on the real screen (🎯 Pick on screen). Unlike the view
## overlay it is deliberately NOT click-through: it captures the click so the
## program underneath doesn't receive it, then hides itself again.

const OverlayT := preload("res://scripts/overlay.gd")

enum PickKind { NONE, POINT, RECT }

signal point_picked(global_pos: Vector2i)
signal rect_picked(rect: Rect2i)
signal pick_canceled

var canvas: PickCanvas


func _ready() -> void:
	title = "Loop Automator Pick"
	set_flag(Window.FLAG_BORDERLESS, true)
	set_flag(Window.FLAG_ALWAYS_ON_TOP, true)
	set_flag(Window.FLAG_TRANSPARENT, true)
	# Focusable: the builder may be minimised while we pick, so Esc has to reach
	# us directly (PickCanvas._unhandled_key_input) rather than the builder.
	transparent_bg = true
	initial_position = Window.WINDOW_INITIAL_POSITION_ABSOLUTE
	canvas = PickCanvas.new()
	add_child(canvas)
	canvas.point_picked.connect(func(g: Vector2i):
		_finish()
		point_picked.emit(g))
	canvas.rect_picked.connect(func(r: Rect2i):
		_finish()
		rect_picked.emit(r))
	canvas.pick_canceled.connect(func():
		_finish()
		pick_canceled.emit())


## Cover the whole virtual desktop and start capturing a point or a rect.
## `sample_mode` is for colour picks: the screen isn't dimmed, nothing is drawn
## on the pixel under the cursor, and the cursor dot shows `hover_color`.
func begin_pick(kind: int, sample_mode: bool = false) -> void:
	var desktop := OverlayT.virtual_desktop_rect()
	position = desktop.position
	size = desktop.size
	canvas.position = Vector2.ZERO
	canvas.size = Vector2(desktop.size)
	show()
	grab_focus()
	canvas.begin(kind, sample_mode)


## Live colour under the cursor (sample mode); transparent = not yet known.
func set_hover_color(c: Color) -> void:
	canvas.hover_color = c
	canvas.queue_redraw()


func end_pick() -> void:
	_finish()


func cancel_pick() -> void:
	if is_picking():
		canvas.cancel()


func is_picking() -> bool:
	return visible and canvas.pick_mode != PickKind.NONE


func _finish() -> void:
	canvas.end()
	hide()


## Draws the crosshair / rubber-band rect and turns mouse clicks into picks.
class PickCanvas extends Control:
	signal point_picked(global_pos: Vector2i)
	signal rect_picked(rect: Rect2i)
	signal pick_canceled

	var pick_mode: int = 0          # PickKind (0 = none, 1 = point, 2 = rect)
	var sample_mode := false        # colour pick: keep the cursor pixel unobstructed
	var hover_color := Color(0, 0, 0, 0)  # live colour under the cursor (sample mode)
	var _cursor := Vector2.ZERO     # global screen coords
	var _dragging := false
	var _drag_from := Vector2.ZERO  # global screen coords
	var _font: Font

	func _init() -> void:
		set_anchors_preset(Control.PRESET_TOP_LEFT)
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_CROSS
		_font = ThemeDB.fallback_font
		set_process(false)

	func begin(kind: int, sampling: bool = false) -> void:
		pick_mode = kind
		sample_mode = sampling
		hover_color = Color(0, 0, 0, 0)
		_dragging = false
		_cursor = Vector2(DisplayServer.mouse_get_position())
		set_process(true)
		queue_redraw()

	func end() -> void:
		pick_mode = 0
		_dragging = false
		set_process(false)

	func cancel() -> void:
		if pick_mode != 0:
			pick_canceled.emit()

	func _process(_dt: float) -> void:
		# Poll the real cursor so the crosshair follows it smoothly, even when
		# the OS coalesces motion events.
		_cursor = Vector2(DisplayServer.mouse_get_position())
		queue_redraw()

	func _unhandled_key_input(event: InputEvent) -> void:
		if pick_mode == 0 or not (event is InputEventKey):
			return
		var k := event as InputEventKey
		if k.pressed and not k.echo and k.keycode == KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			pick_canceled.emit()

	func _gui_input(event: InputEvent) -> void:
		if pick_mode == 0 or not (event is InputEventMouseButton):
			return
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				accept_event()
				pick_canceled.emit()
			return
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		accept_event()
		var g := Vector2(get_window().position) + mb.position
		if pick_mode == 1:  # POINT
			if mb.pressed:
				point_picked.emit(Vector2i(g))
		elif mb.pressed:  # RECT: press starts the drag...
			_dragging = true
			_drag_from = g
			_cursor = g
		elif _dragging:   # ...release ends it.
			_dragging = false
			var r := Rect2(_drag_from, g - _drag_from).abs()
			if r.size.x < 4.0 and r.size.y < 4.0:
				r.size = Vector2(20, 20)  # plain click → small default rect
			rect_picked.emit(Rect2i(r))

	func _draw() -> void:
		var offset := Vector2(get_window().position)
		var c := _cursor - offset
		var line := Color(1, 1, 1, 0.7)
		if sample_mode:
			# Colour pick: no dim (so colours read true) and a clear hole at the
			# cursor, so the live sampler reads the desktop and not our drawing.
			const GAP := 6.0
			draw_line(Vector2(0, c.y), Vector2(c.x - GAP, c.y), line, 1.0)
			draw_line(Vector2(c.x + GAP, c.y), Vector2(size.x, c.y), line, 1.0)
			draw_line(Vector2(c.x, 0), Vector2(c.x, c.y - GAP), line, 1.0)
			draw_line(Vector2(c.x, c.y + GAP), Vector2(c.x, size.y), line, 1.0)
			# The dot becomes a ring filled with the colour under the cursor.
			var ring := hover_color if hover_color.a > 0.0 else Color(1, 1, 0, 0.95)
			draw_arc(c, 8.0, 0, TAU, 40, Color(0, 0, 0, 0.8), 1.0)
			draw_arc(c, 6.0, 0, TAU, 40, ring, 3.0)
			draw_arc(c, 4.0, 0, TAU, 40, Color(0, 0, 0, 0.8), 1.0)
		else:
			# Dim the screen so it's obvious the overlay is now capturing input.
			draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.18), true)
			# Full-screen crosshair at the cursor.
			draw_line(Vector2(0, c.y), Vector2(size.x, c.y), line, 1.0)
			draw_line(Vector2(c.x, 0), Vector2(c.x, size.y), line, 1.0)
			draw_circle(c, 4, Color(1, 1, 0, 0.95))

		if pick_mode == 2 and _dragging:
			var a := _drag_from - offset
			var r := Rect2(a, c - a).abs()
			draw_rect(r, Color(1, 1, 0, 0.12), true)
			draw_rect(r, Color(1, 1, 0, 0.95), false, 2.0)
			_label(r.position + Vector2(4, -6), "%d × %d" % [int(r.size.x), int(r.size.y)], Color.WHITE, 14)

		# Coordinate (and, when sampling, colour) readout next to the cursor.
		var readout := "(%d, %d)" % [int(_cursor.x), int(_cursor.y)]
		if sample_mode and hover_color.a > 0.0:
			readout += "  #" + hover_color.to_html(false)
		_label(c + Vector2(12, -12), readout, Color.WHITE, 14)

		# Instruction banner.
		var txt := "PICK A POINT — click to set" if pick_mode == 1 else "PICK A RECT — drag to set"
		if sample_mode:
			txt = "SAMPLE A COLOUR — click to read it"
		txt += "   ·   right-click / Esc to cancel"
		var banner_w := 460.0
		if _font != null:
			banner_w = _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x + 20.0
		draw_rect(Rect2(Vector2(10, size.y - 40), Vector2(banner_w, 28)), Color(0, 0, 0, 0.6), true)
		_label(Vector2(20, size.y - 22), txt, Color(1, 1, 0.6, 1), 15)

	func _label(pos: Vector2, text: String, col: Color, font_size: int = 13) -> void:
		if _font == null:
			return
		draw_string(_font, pos + Vector2(1, 1), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0, 0, 0, 0.8))
		draw_string(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)
