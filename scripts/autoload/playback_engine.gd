extends Node
## Autoload that runs the project as an endless loop, driving the active
## InputBackend. Uses awaited timers so it never blocks the UI thread.

## Preload constants (see project_data.gd) so this autoload resolves its types
## without relying on the global `class_name` registry, which may not be ready
## when autoloads first compile.
const InputBackendT := preload("res://scripts/input/input_backend.gd")
const PreviewBackendT := preload("res://scripts/input/preview_backend.gd")
const WindowsBackendT := preload("res://scripts/input/windows_backend.gd")
const LoopActionT := preload("res://scripts/model/loop_action.gd")
const LoopLayerT := preload("res://scripts/model/loop_layer.gd")

signal playback_started
signal playback_stopped
signal status(message: String)
## Emitted right before each action runs so the UI/overlay can highlight it.
signal action_executing(layer_index: int, action_index: int)
## Emitted whenever the execution tracker head changes.
signal tracker_changed(global_pos: Vector2i, visible: bool, label: String)

enum BackendKind { PREVIEW, WINDOWS }

var is_running: bool = false
var backend: InputBackendT
var current_layer_index: int = -1
var current_action_index: int = -1
var tracker_pos: Vector2i = Vector2i.ZERO
var tracker_visible: bool = false
var tracker_label: String = ""

# Guard so a stop request issued mid-action breaks out cleanly.
var _generation: int = 0

# The one mouse position remembered by Capture (Save / Load) and by the
# "Captures" option on mouse actions. Cleared whenever playback starts.
var _saved_cursor: Vector2i = Vector2i.ZERO
var _has_saved_cursor: bool = false

# Lazily-created real backend used purely for reading screen pixels (so colour
# sampling works even while the active playback backend is Preview).
var _screen_sampler: InputBackendT


func _ready() -> void:
	set_backend(BackendKind.PREVIEW)


## Returns a backend that can actually read screen pixels, or null if none is
## available on this OS. Prefers the active backend when it is real, otherwise
## spins up a dedicated (Windows) reader on demand.
func get_screen_sampler() -> InputBackendT:
	if backend != null and backend.is_real():
		return backend
	if OS.get_name() == "Windows":
		if _screen_sampler == null:
			_screen_sampler = WindowsBackendT.new()
		return _screen_sampler
	return null


func set_backend(kind: int) -> void:
	match kind:
		BackendKind.WINDOWS:
			if OS.get_name() == "Windows":
				backend = WindowsBackendT.new()
			else:
				backend = PreviewBackendT.new()
				emit_signal("status", "Windows backend unavailable on this OS — using Preview.")
		_:
			backend = PreviewBackendT.new()
	emit_signal("status", "Backend: %s" % backend.backend_name())


func toggle() -> void:
	if is_running:
		stop()
	else:
		start()


func start() -> void:
	if is_running:
		return
	if ProjectData.project == null or ProjectData.project.layers.is_empty():
		emit_signal("status", "Nothing to run.")
		return
	is_running = true
	_generation += 1
	_has_saved_cursor = false
	emit_signal("playback_started")
	emit_signal("status", "Running…")
	_run_loop(_generation)


func stop() -> void:
	if not is_running:
		return
	is_running = false
	_generation += 1
	current_layer_index = -1
	current_action_index = -1
	_set_tracker(Vector2i.ZERO, false, "")
	emit_signal("action_executing", -1, -1)
	emit_signal("playback_stopped")
	emit_signal("status", "Stopped.")


func _run_loop(gen: int) -> void:
	var project := ProjectData.project
	while is_running and gen == _generation:
		for li in project.layers.size():
			if not is_running or gen != _generation:
				break
			var layer: LoopLayerT = project.layers[li]
			if not layer.enabled:
				continue
			var skip_layer := false
			for ai in layer.actions.size():
				if not is_running or gen != _generation:
					break
				var action: LoopActionT = layer.actions[ai]
				if not action.enabled:
					continue
				current_layer_index = li
				current_action_index = ai
				emit_signal("action_executing", li, ai)
				var result := await _execute_action(action, li, ai)
				if result == LoopActionT.OnFail.SKIP_LAYER:
					skip_layer = true
					break
				elif result == LoopActionT.OnFail.STOP_LOOP:
					stop()
					return
			if skip_layer:
				continue
		if not is_running or gen != _generation:
			break
		if project.loop_delay_ms > 0:
			emit_signal("status", "Loop delay: %d ms" % project.loop_delay_ms)
			_set_tracker(tracker_pos, tracker_visible, "DELAY %dms" % project.loop_delay_ms)
			await _sleep_ms(project.loop_delay_ms)
			if is_running and gen == _generation:
				emit_signal("status", "Running…")
	# Loop ended naturally (only happens if stopped).


## Runs one action. Returns LoopAction.OnFail.CONTINUE normally, or a
## different OnFail value to influence the loop (used by PIXEL_DETECT).
## `layer_index` / `action_index` locate the action in the project (a Capture
## Load with nothing saved disables itself).
func _execute_action(action: LoopActionT, layer_index: int, action_index: int) -> int:
	# "Captures": remember where the mouse is, run the action, then go back.
	var restore_after := action.captures and LoopActionT.supports_captures(action.type)
	if restore_after:
		restore_after = _save_cursor()
	var result := await _execute_action_body(action, layer_index, action_index)
	if restore_after and is_running:
		_load_cursor("RESTORE")
	return result


func _execute_action_body(action: LoopActionT, layer_index: int, action_index: int) -> int:
	match action.type:
		LoopActionT.Type.MOVE:
			_set_tracker(Vector2i(action.x, action.y), true, "MOVE")
			backend.move_to(Vector2i(action.x, action.y))
			if action.duration_ms > 0:
				await _sleep_ms(action.duration_ms)
		LoopActionT.Type.CLICK:
			_set_tracker(Vector2i(action.x, action.y), true, "CLICK")
			backend.click(action.button, Vector2i(action.x, action.y))
		LoopActionT.Type.DRAG:
			_set_tracker(Vector2i(action.x, action.y), true, "DRAG START")
			backend.mouse_button(action.button, true, Vector2i(action.x, action.y))
			if action.duration_ms > 0:
				await _sleep_ms(action.duration_ms)
			_set_tracker(Vector2i(action.x2, action.y2), true, "DRAG END")
			backend.mouse_button(action.button, false, Vector2i(action.x2, action.y2))
		LoopActionT.Type.KEY:
			_set_tracker(tracker_pos, tracker_visible, "KEY")
			backend.send_keys(action.keys)
		LoopActionT.Type.WAIT:
			emit_signal("status", "Wait: %d ms" % action.wait_ms)
			_set_tracker(tracker_pos, tracker_visible, "WAIT")
			await _sleep_ms(action.wait_ms)
		LoopActionT.Type.PIXEL_DETECT:
			_set_tracker(Vector2i(action.x + action.w / 2, action.y + action.h / 2), true, "DETECT")
			var hit := _find_color(action)
			var found := hit.x >= 0
			if found:
				_set_tracker(hit, true, "DETECT")
			emit_signal("status", "Pixel detect: %s" % (("FOUND at (%d, %d)" % [hit.x, hit.y]) if found else "not found"))
			if not found:
				return action.on_fail
		LoopActionT.Type.CAPTURE:
			if action.capture_mode == LoopActionT.CaptureMode.SAVE:
				if _save_cursor():
					emit_signal("status", "Capture: saved mouse position (%d, %d)" % [_saved_cursor.x, _saved_cursor.y])
				else:
					emit_signal("status", "Capture: could not read the mouse position")
			elif _has_saved_cursor:
				_load_cursor("CAPTURE LOAD")
				emit_signal("status", "Capture: moved to saved position (%d, %d)" % [_saved_cursor.x, _saved_cursor.y])
			else:
				# Nothing to go back to: do nothing and switch the action off so
				# it stops being attempted every iteration.
				emit_signal("status", "Capture: nothing saved yet — action disabled.")
				ProjectData.disable_action(layer_index, action_index)
	return LoopActionT.OnFail.CONTINUE


## Remembers the current mouse position. Returns false (leaving any earlier
## saved position alone) if the backend cannot read it.
func _save_cursor() -> bool:
	var pos := backend.get_cursor_pos()
	if pos == Vector2i(-1, -1):
		return false
	_saved_cursor = pos
	_has_saved_cursor = true
	_set_tracker(pos, true, "CAPTURE SAVE")
	return true


## Moves the mouse back to the saved position (callers check _has_saved_cursor).
func _load_cursor(label: String) -> void:
	_set_tracker(_saved_cursor, true, label)
	backend.move_to(_saved_cursor)


## Most pixels a Pixel Detect scans per check. Bigger rects are sampled on a
## grid instead (every 2nd, 3rd… pixel), which still catches anything larger
## than the step but keeps a whole-screen check well under a second.
const DETECT_MAX_SAMPLES := 250000


## Looks for `action.color` (± tolerance per channel) anywhere in the action's
## rect. Returns the screen position of the first match, or (-1, -1).
func _find_color(action: LoopActionT) -> Vector2i:
	var rect := Rect2i(action.x, action.y, maxi(1, action.w), maxi(1, action.h))
	if not backend.is_real():
		# Preview cannot read the real screen; treat as found so the loop flows.
		return rect.get_center()
	var img := backend.read_rect(rect)
	if img == null:
		print("Pixel detect in [%d, %d, %d×%d]: screen read failed (see warning above) -> not found" % [rect.position.x, rect.position.y, rect.size.x, rect.size.y])
		return Vector2i(-1, -1)
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()
	var tol := action.tolerance
	var er := action.color.r8
	var eg := action.color.g8
	var eb := action.color.b8
	# The centre first: it is where "Pick & sample" read the colour from, so
	# the common case costs one comparison and reports the expected spot.
	var centre := Vector2i(w / 2, h / 2)
	if _matches(data, (centre.y * w + centre.x) * 4, er, eg, eb, tol):
		return rect.position + centre
	var step := maxi(1, int(ceil(sqrt(float(w * h) / float(DETECT_MAX_SAMPLES)))))
	var y := 0
	while y < h:
		var row := y * w * 4
		var x := 0
		while x < w:
			if _matches(data, row + x * 4, er, eg, eb, tol):
				return rect.position + Vector2i(x, y)
			x += step
		y += step
	# Logged (user://logs) so a flaky detect can be diagnosed after the fact.
	print("Pixel detect in [%d, %d, %d×%d]: centre read #%s, expected #%s +-%d, no match in rect (step %d) -> not found" % [
		rect.position.x, rect.position.y, rect.size.x, rect.size.y,
		img.get_pixelv(centre).to_html(false), action.color.to_html(false), tol, step])
	return Vector2i(-1, -1)


static func _matches(data: PackedByteArray, i: int, er: int, eg: int, eb: int, tol: int) -> bool:
	return absi(data[i] - er) <= tol and absi(data[i + 1] - eg) <= tol and absi(data[i + 2] - eb) <= tol


func _sleep_ms(ms: int) -> void:
	await get_tree().create_timer(maxf(0.001, ms / 1000.0)).timeout


func _set_tracker(pos: Vector2i, visible: bool, label: String) -> void:
	tracker_pos = pos
	tracker_visible = visible
	tracker_label = label
	emit_signal("tracker_changed", tracker_pos, tracker_visible, tracker_label)
