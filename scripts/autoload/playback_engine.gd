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
				var result := await _execute_action(action)
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
func _execute_action(action: LoopActionT) -> int:
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
			var found := _check_pixel(action)
			emit_signal("status", "Pixel detect: %s" % ("FOUND" if found else "not found"))
			if not found:
				return action.on_fail
	return LoopActionT.OnFail.CONTINUE


func _check_pixel(action: LoopActionT) -> bool:
	if not backend.is_real():
		# Preview cannot read the real screen; treat as found so the loop flows.
		return true
	# Sample the centre of the rect.
	var px := Vector2i(action.x + action.w / 2, action.y + action.h / 2)
	var c := backend.get_pixel(px)
	if c.a <= 0.0:
		return false
	var tol := float(action.tolerance) / 255.0
	return absf(c.r - action.color.r) <= tol \
		and absf(c.g - action.color.g) <= tol \
		and absf(c.b - action.color.b) <= tol


func _sleep_ms(ms: int) -> void:
	await get_tree().create_timer(maxf(0.001, ms / 1000.0)).timeout


func _set_tracker(pos: Vector2i, visible: bool, label: String) -> void:
	tracker_pos = pos
	tracker_visible = visible
	tracker_label = label
	emit_signal("tracker_changed", tracker_pos, tracker_visible, tracker_label)
