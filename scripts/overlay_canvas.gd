extends Control
class_name OverlayCanvas
## Draws the visual representation of the loop on the transparent overlay:
## pixel-detection rects, click/move points, drag arrows, ordered paths, and
## a highlight on the action currently being executed.

## Preload model scripts so this resolves even when loaded early (overlay.tscn
## is preloaded by main.gd), before the global `class_name` registry is ready.
const LoopProjectT := preload("res://scripts/model/loop_project.gd")
const LoopLayerT := preload("res://scripts/model/loop_layer.gd")
const LoopActionT := preload("res://scripts/model/loop_action.gd")
const CaptureHoleShader := preload("res://scripts/capture_hole.gdshader")

## Short status shown in the HUD (e.g. whether click-through is active).
var hud_note: String = ""
var _tracker_trail: Array[Vector2i] = []
const TRACKER_TRAIL_MAX := 24

var _font: Font


func _ready() -> void:
	# Anchor to the top-left and size the canvas explicitly (the overlay sets the
	# size to the screen). Using FULL_RECT here is unreliable for a Control that
	# is a direct child of a native Window, and can collapse to a tiny size.
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2.ZERO
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font
	# Leave every Pixel Detect rect transparent so playback reads the desktop
	# there rather than our guides (see capture_hole.gdshader).
	material = ShaderMaterial.new()
	material.shader = CaptureHoleShader
	ProjectData.layers_changed.connect(_redraw)
	ProjectData.actions_changed.connect(func(_i): _redraw())
	ProjectData.action_modified.connect(func(_a, _b): _redraw())
	ProjectData.selection_changed.connect(_redraw)
	ProjectData.overlay_view_changed.connect(_redraw)
	ProjectData.project_replaced.connect(_redraw)
	Playback.action_executing.connect(func(_l, _a): _redraw())
	Playback.tracker_changed.connect(_on_tracker_changed)


func _redraw() -> void:
	queue_redraw()


func _screen_offset() -> Vector2:
	var w := get_window()
	return Vector2(w.position) if w != null else Vector2.ZERO


func _draw() -> void:
	var project := ProjectData.project
	if project == null:
		return
	var offset := _screen_offset()
	_update_capture_holes(project, offset)

	# Editor-style viewport chrome (grid, axes, rulers) underneath everything.
	# No full-screen tint: the desktop must stay readable through the overlay.
	_draw_editor_grid(offset)

	var indices: Array[int] = []
	if ProjectData.overlay_show_all:
		for i in project.layers.size():
			if project.layers[i].visible:
				indices.append(i)
	else:
		var idx := clampi(ProjectData.overlay_layer_index, 0, project.layers.size() - 1)
		if project.layers[idx].visible:
			indices.append(idx)

	for li in indices:
		_draw_layer(li, project.layers[li], offset)

	_draw_tracker_trail(offset)
	_draw_execution_tracker(offset)

	_draw_hud(project, offset)
	_draw_overlay_corners()


# --------------------------------------------------------- editor viewport
## Draws a 3D/2D-editor-style viewport: a minor/major grid in screen space,
## origin axes (X = red, Y = green) and rulers with coordinate ticks along the
## top and left edges. Spacing is in screen pixels so coordinates read true.
const GRID_MINOR := 50
const GRID_MAJOR := 250
const RULER := 22.0

func _draw_editor_grid(offset: Vector2) -> void:
	var w := size.x
	var h := size.y

	var minor := Color(1, 1, 1, 0.10)
	var major := Color(1, 1, 1, 0.22)

	# Vertical lines (screen x). offset.x is the overlay's screen X origin.
	var start_x := int(floor(offset.x / GRID_MINOR) * GRID_MINOR)
	var gx := start_x
	while float(gx) - offset.x <= w:
		var lx := float(gx) - offset.x
		if lx >= 0.0:
			var is_major := (gx % GRID_MAJOR) == 0
			draw_line(Vector2(lx, RULER), Vector2(lx, h), major if is_major else minor, 1.0)
		gx += GRID_MINOR

	# Horizontal lines (screen y).
	var start_y := int(floor(offset.y / GRID_MINOR) * GRID_MINOR)
	var gy := start_y
	while float(gy) - offset.y <= h:
		var ly := float(gy) - offset.y
		if ly >= 0.0:
			var is_major := (gy % GRID_MAJOR) == 0
			draw_line(Vector2(RULER, ly), Vector2(w, ly), major if is_major else minor, 1.0)
		gy += GRID_MINOR

	# World origin axes (screen 0,0).
	var ox := -offset.x
	var oy := -offset.y
	if oy >= 0.0 and oy <= h:
		draw_line(Vector2(RULER, oy), Vector2(w, oy), Color(0.9, 0.3, 0.3, 0.55), 1.5)  # X axis (red)
	if ox >= 0.0 and ox <= w:
		draw_line(Vector2(ox, RULER), Vector2(ox, h), Color(0.4, 0.85, 0.4, 0.55), 1.5)  # Y axis (green)

	_draw_rulers(offset)

	# Viewport border.
	draw_rect(Rect2(Vector2(RULER, RULER), Vector2(w - RULER, h - RULER)), Color(1, 1, 1, 0.18), false, 1.0)


func _draw_rulers(offset: Vector2) -> void:
	var w := size.x
	var h := size.y
	var bg := Color(0, 0, 0, 0.45)
	draw_rect(Rect2(Vector2.ZERO, Vector2(w, RULER)), bg, true)        # top
	draw_rect(Rect2(Vector2.ZERO, Vector2(RULER, h)), bg, true)        # left
	draw_rect(Rect2(Vector2.ZERO, Vector2(RULER, RULER)), Color(0, 0, 0, 0.6), true)  # corner

	var tick := Color(1, 1, 1, 0.5)

	# Top ruler: labelled at majors, ticks at minors.
	var sx := int(floor(offset.x / GRID_MINOR) * GRID_MINOR)
	var gx := sx
	while float(gx) - offset.x <= w:
		var lx := float(gx) - offset.x
		if lx >= RULER:
			var is_major := (gx % GRID_MAJOR) == 0
			var tlen := 8.0 if is_major else 4.0
			draw_line(Vector2(lx, RULER - tlen), Vector2(lx, RULER), tick, 1.0)
			if is_major:
				_label(Vector2(lx + 2, 14), str(gx), Color(1, 1, 1, 0.8), 11)
		gx += GRID_MINOR

	# Left ruler.
	var sy := int(floor(offset.y / GRID_MINOR) * GRID_MINOR)
	var gy := sy
	while float(gy) - offset.y <= h:
		var ly := float(gy) - offset.y
		if ly >= RULER:
			var is_major := (gy % GRID_MAJOR) == 0
			var tlen := 8.0 if is_major else 4.0
			draw_line(Vector2(RULER - tlen, ly), Vector2(RULER, ly), tick, 1.0)
			if is_major:
				_label(Vector2(2, ly - 2), str(gy), Color(1, 1, 1, 0.8), 11)
		gy += GRID_MINOR


func _draw_layer(li: int, layer: LoopLayerT, offset: Vector2) -> void:
	var col: Color = layer.color
	var prev_point := Vector2(-1, -1)
	var last_anchor := Vector2(-1, -1)  # anchor for position-less actions (key/wait)
	var step := 0
	var tag_stack := 0  # stacked offset for consecutive position-less actions

	for ai in layer.actions.size():
		var action: LoopActionT = layer.actions[ai]
		if not action.enabled:
			continue
		var is_current := (Playback.current_layer_index == li and Playback.current_action_index == ai)
		var is_selected := (li == ProjectData.active_layer_index and ai == ProjectData.selected_action_index)
		var p := action.overlay_point()
		var local := p - offset

		# Dashed path connecting ordered positioned points (execution order).
		if p.x >= 0 and prev_point.x >= 0:
			var d := col
			d.a = 0.5
			draw_dashed_line(prev_point, local, d, 1.5, 6.0)

		# Per-type visual guide.
		match action.type:
			LoopActionT.Type.PIXEL_DETECT:
				_draw_detect_guide(action, offset, col, is_selected)
			LoopActionT.Type.MOVE:
				_draw_move_guide(local, col, is_selected)
			LoopActionT.Type.CLICK:
				_draw_click_guide(local, col, action.button, is_selected)
			LoopActionT.Type.DRAG:
				_draw_drag_guide(Vector2(action.x, action.y) - offset, Vector2(action.x2, action.y2) - offset, col, action.button, is_selected)

		if p.x >= 0:
			# Positioned action: ordered step badge + execution highlight.
			step += 1
			_draw_badge(local + Vector2(13, -13), str(step), col)
			if is_current:
				draw_arc(local, 20, 0, TAU, 40, Color.WHITE, 2.5)
			prev_point = local
			last_anchor = local
			tag_stack = 0
		else:
			# Position-less action (key/wait): a labelled chip anchored to the
			# last positioned action so it still reads in execution order.
			var anchor := last_anchor if last_anchor.x >= 0 else Vector2(40, 70)
			var tag_pos := anchor + Vector2(26, 18 + tag_stack * 24)
			tag_stack += 1
			var link := col
			link.a = 0.35
			draw_line(anchor, tag_pos + Vector2(0, 10), link, 1.0)
			if action.type == LoopActionT.Type.KEY:
				var ktxt: String = action.keys if action.keys.length() <= 14 else action.keys.substr(0, 13) + "…"
				_draw_tag(tag_pos, col, "KEY  " + ktxt, is_selected)
			elif action.type == LoopActionT.Type.WAIT:
				_draw_tag(tag_pos, col, "WAIT  %d ms" % action.wait_ms, is_selected)
			if is_current:
				draw_arc(tag_pos + Vector2(8, 10), 16, 0, TAU, 28, Color.WHITE, 2.5)


# ------------------------------------------------------------- guide helpers
## A white halo placed around a marker to show it is the selected action.
func _selection_ring(center: Vector2, radius: float) -> void:
	draw_arc(center, radius, 0, TAU, 40, Color(1, 1, 1, 0.95), 1.5)
	draw_arc(center, radius + 3.0, 0, TAU, 40, Color(1, 1, 1, 0.3), 1.0)


## PIXEL_DETECT: frame the rect with an outline and corner ticks, with the
## expected colour swatch and a size/tolerance label above it. Everything sits
## *outside* the rect: playback scans the whole rect on screen, so the inside
## is kept transparent (see _update_capture_holes) and must stay undrawn.
func _draw_detect_guide(action: LoopActionT, offset: Vector2, col: Color, selected: bool) -> void:
	var rect := Rect2(Vector2(action.x, action.y) - offset, Vector2(action.w, action.h))
	var frame := rect.grow(1.5)
	draw_rect(frame, col, false, 2.0)
	_draw_corner_ticks(rect.grow(3.0), col)
	# Expected colour swatch + label on a strip above the rect, to the right of
	# the step badge that sits at the top-left corner.
	var top := rect.position + Vector2(28, -22)
	draw_rect(Rect2(top, Vector2(16, 16)), action.color, true)
	draw_rect(Rect2(top, Vector2(16, 16)), Color.BLACK, false, 1.0)
	_label(top + Vector2(20, 12), "detect  %d×%d  ±%d" % [int(rect.size.x), int(rect.size.y), action.tolerance], col)
	if selected:
		draw_rect(rect.grow(6.0), Color(1, 1, 1, 0.95), false, 1.5)


## Draw L-shaped ticks at each corner so the rect extents are unmistakable.
func _draw_corner_ticks(rect: Rect2, col: Color, length: float = 12.0) -> void:
	var p := rect.position
	var s := rect.size
	var tl := p
	var tr := p + Vector2(s.x, 0)
	var bl := p + Vector2(0, s.y)
	var br := p + s
	draw_line(tl, tl + Vector2(length, 0), col, 2.5)
	draw_line(tl, tl + Vector2(0, length), col, 2.5)
	draw_line(tr, tr - Vector2(length, 0), col, 2.5)
	draw_line(tr, tr + Vector2(0, length), col, 2.5)
	draw_line(bl, bl + Vector2(length, 0), col, 2.5)
	draw_line(bl, bl - Vector2(0, length), col, 2.5)
	draw_line(br, br - Vector2(length, 0), col, 2.5)
	draw_line(br, br - Vector2(0, length), col, 2.5)


## MOVE: a crosshair with a hollow diamond (a target with no click).
func _draw_move_guide(p: Vector2, col: Color, selected: bool) -> void:
	draw_line(p - Vector2(11, 0), p + Vector2(11, 0), col, 2.0)
	draw_line(p - Vector2(0, 11), p + Vector2(0, 11), col, 2.0)
	var diamond := PackedVector2Array([
		p + Vector2(0, -7), p + Vector2(7, 0), p + Vector2(0, 7), p + Vector2(-7, 0), p + Vector2(0, -7)
	])
	draw_polyline(diamond, col, 2.0)
	if selected:
		_selection_ring(p, 16.0)


## CLICK: concentric ripple rings + a solid centre dot + a button-letter chip.
func _draw_click_guide(p: Vector2, col: Color, button: int, selected: bool) -> void:
	draw_arc(p, 6.0, 0, TAU, 24, col, 2.0)
	var r2 := col
	r2.a = 0.5
	draw_arc(p, 11.0, 0, TAU, 28, r2, 1.5)
	var r3 := col
	r3.a = 0.25
	draw_arc(p, 16.0, 0, TAU, 32, r3, 1.0)
	draw_circle(p, 3.5, col)
	# Button chip (first letter of Left/Right/Middle), below-right of the point.
	_draw_badge(p + Vector2(13, 13), LoopActionT.button_name(button).substr(0, 1), col)
	if selected:
		_selection_ring(p, 20.0)


## DRAG: solid arrow from start→end, hollow start node, filled end node.
func _draw_drag_guide(a: Vector2, b: Vector2, col: Color, button: int, selected: bool) -> void:
	draw_line(a, b, col, 2.5)
	_draw_arrow_head(a, b, col)
	draw_circle(a, 5.0, Color(col.r, col.g, col.b, 0.45))
	draw_arc(a, 6.0, 0, TAU, 20, col, 2.0)
	draw_circle(b, 4.0, col)
	_label((a + b) * 0.5 + Vector2(6, -6), "%s drag" % LoopActionT.button_name(button), col)
	if selected:
		_selection_ring(a, 16.0)
		_selection_ring(b, 14.0)


## A small dark chip with a coloured outline, used for KEY / WAIT actions.
func _draw_tag(pos: Vector2, col: Color, text: String, selected: bool) -> void:
	var tw := 16.0
	if _font != null:
		tw = _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x + 20.0
	var rect := Rect2(pos, Vector2(tw, 20.0))
	draw_rect(rect, Color(0, 0, 0, 0.72), true)
	draw_rect(rect, col, false, 1.5)
	draw_circle(pos + Vector2(9, 10), 3.0, col)
	_label(pos + Vector2(16, 14), text, Color.WHITE, 13)
	if selected:
		draw_rect(rect.grow(2.0), Color(1, 1, 1, 0.95), false, 1.0)


func _draw_arrow_head(from: Vector2, to: Vector2, col: Color) -> void:
	var dir := (to - from)
	if dir.length() < 0.01:
		return
	dir = dir.normalized()
	var left := dir.rotated(deg_to_rad(150)) * 12.0
	var right := dir.rotated(deg_to_rad(-150)) * 12.0
	draw_line(to, to + left, col, 2.0)
	draw_line(to, to + right, col, 2.0)


func _draw_badge(pos: Vector2, text: String, col: Color) -> void:
	draw_circle(pos, 9, Color(0, 0, 0, 0.65))
	draw_arc(pos, 9, 0, TAU, 20, col, 1.5)
	_label(pos - Vector2(text.length() * 3.0, -4), text, Color.WHITE, 12)


func _label(pos: Vector2, text: String, col: Color, size: int = 13) -> void:
	if _font == null:
		return
	# Cheap shadow for legibility over any background.
	draw_string(_font, pos + Vector2(1, 1), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.8))
	draw_string(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _draw_hud(project: LoopProjectT, _offset: Vector2) -> void:
	var lines: Array[String] = []
	var view := "all visible layers"
	if not ProjectData.overlay_show_all:
		var idx := clampi(ProjectData.overlay_layer_index, 0, project.layers.size() - 1)
		view = "layer %d/%d: %s" % [idx + 1, project.layers.size(), project.layers[idx].name]
	if hud_note.is_empty():
		lines.append("OVERLAY · %s" % view)
	else:
		lines.append("OVERLAY · %s · %s" % [view, hud_note])
	if Playback.is_running:
		lines.append("● RUNNING")
		if Playback.tracker_visible:
			lines.append("tracker  (%d, %d)  %s" % [Playback.tracker_pos.x, Playback.tracker_pos.y, Playback.tracker_label])
	var y := 14.0
	for l in lines:
		_label(Vector2(14, y), l, Color.WHITE, 16)
		y += 22.0


func _on_tracker_changed(pos: Vector2i, visible: bool, _label_text: String) -> void:
	if not visible:
		_tracker_trail.clear()
		queue_redraw()
		return
	if _tracker_trail.is_empty() or _tracker_trail[_tracker_trail.size() - 1] != pos:
		_tracker_trail.append(pos)
		if _tracker_trail.size() > TRACKER_TRAIL_MAX:
			_tracker_trail.pop_front()
	queue_redraw()


func _draw_tracker_trail(offset: Vector2) -> void:
	if _tracker_trail.size() < 2:
		return
	var points := PackedVector2Array()
	for p in _tracker_trail:
		points.append(Vector2(p) - offset)
	draw_polyline(points, Color(0.1, 0.95, 1.0, 0.45), 2.0)
	for i in _tracker_trail.size():
		var lp := Vector2(_tracker_trail[i]) - offset
		var alpha := 0.12 + 0.6 * (float(i + 1) / float(_tracker_trail.size()))
		draw_circle(lp, 2.0, Color(0.1, 0.95, 1.0, alpha))


func _draw_execution_tracker(offset: Vector2) -> void:
	if not Playback.is_running or not Playback.tracker_visible:
		return
	var p := Vector2(Playback.tracker_pos) - offset
	if p.x < -20.0 or p.y < -20.0 or p.x > size.x + 20.0 or p.y > size.y + 20.0:
		return
	var col := Color(0.1, 0.95, 1.0, 1.0)
	# Tracker head: bright point + rings so it's readable over any scene.
	draw_circle(p, 5.0, col)
	draw_arc(p, 11.0, 0, TAU, 32, Color(col.r, col.g, col.b, 0.8), 2.0)
	draw_arc(p, 17.0, 0, TAU, 32, Color(col.r, col.g, col.b, 0.35), 1.0)
	# Crosshair lines reinforce exact position while running in preview mode.
	draw_line(Vector2(p.x - 16.0, p.y), Vector2(p.x + 16.0, p.y), Color(col.r, col.g, col.b, 0.65), 1.5)
	draw_line(Vector2(p.x, p.y - 16.0), Vector2(p.x, p.y + 16.0), Color(col.r, col.g, col.b, 0.65), 1.5)
	_label(p + Vector2(12, -10), "tracker (%d, %d)" % [Playback.tracker_pos.x, Playback.tracker_pos.y], Color(0.85, 1.0, 1.0, 1.0), 14)


func _draw_overlay_corners() -> void:
	var offset := _screen_offset()
	var count := DisplayServer.get_screen_count()
	for i in count:
		var screen_pos := Vector2(DisplayServer.screen_get_position(i)) - offset
		var screen_size := Vector2(DisplayServer.screen_get_size(i))
		_draw_rect_corners(Rect2(screen_pos, screen_size))


func _draw_rect_corners(rect: Rect2) -> void:
	var len := 28.0
	var pad := 8.0
	var col := Color(0.15, 1.0, 0.95, 1.0)
	var shadow := Color(0.0, 0.0, 0.0, 0.85)
	var tl := rect.position + Vector2(pad, pad)
	var tr := rect.position + Vector2(rect.size.x - pad, pad)
	var bl := rect.position + Vector2(pad, rect.size.y - pad)
	var br := rect.position + rect.size - Vector2(pad, pad)

	# top-left
	draw_line(tl + Vector2(1, 1), tl + Vector2(len, 1), shadow, 4.0)
	draw_line(tl + Vector2(1, 1), tl + Vector2(1, len), shadow, 4.0)
	draw_line(tl, tl + Vector2(len, 0), col, 3.0)
	draw_line(tl, tl + Vector2(0, len), col, 3.0)
	# top-right
	draw_line(tr + Vector2(1, 1), tr + Vector2(-len, 1), shadow, 4.0)
	draw_line(tr + Vector2(1, 1), tr + Vector2(1, len), shadow, 4.0)
	draw_line(tr, tr + Vector2(-len, 0), col, 3.0)
	draw_line(tr, tr + Vector2(0, len), col, 3.0)
	# bottom-left
	draw_line(bl + Vector2(1, 1), bl + Vector2(len, 1), shadow, 4.0)
	draw_line(bl + Vector2(1, 1), bl + Vector2(1, -len), shadow, 4.0)
	draw_line(bl, bl + Vector2(len, 0), col, 3.0)
	draw_line(bl, bl + Vector2(0, -len), col, 3.0)
	# bottom-right
	draw_line(br + Vector2(1, 1), br + Vector2(-len, 1), shadow, 4.0)
	draw_line(br + Vector2(1, 1), br + Vector2(1, -len), shadow, 4.0)
	draw_line(br, br + Vector2(-len, 0), col, 3.0)
	draw_line(br, br + Vector2(0, -len), col, 3.0)


# ------------------------------------------------------------ capture holes
## A PIXEL_DETECT action is checked anywhere inside its rect (see
## PlaybackEngine._find_color). Every such rect — in every layer, since all
## enabled layers run — is passed to the shader so nothing drawn here (other
## guides, the grid, the tracker) can tint the screen read.
func _update_capture_holes(project: LoopProjectT, offset: Vector2) -> void:
	var rects := PackedVector4Array()
	for layer in project.layers:
		for a in layer.actions:
			if a.type == LoopActionT.Type.PIXEL_DETECT and rects.size() < 128:
				# Same integer rect playback reads from the screen.
				rects.append(Vector4(a.x - offset.x, a.y - offset.y, maxi(1, a.w), maxi(1, a.h)))
	material.set_shader_parameter("rect_count", rects.size())
	material.set_shader_parameter("rects", rects)
