extends Node
## Autoload singleton holding the current project and shared UI selection
## state. Both the builder window and the overlay read from here.

## Autoloads compile before Godot's global `class_name` registry is guaranteed
## ready (notably on a project's first import, when there is no `.godot` cache
## yet). Referencing the model scripts through preload constants makes this
## autoload resolve its types directly, independent of that registry.
const LoopProjectT := preload("res://scripts/model/loop_project.gd")
const LoopLayerT := preload("res://scripts/model/loop_layer.gd")
const LoopActionT := preload("res://scripts/model/loop_action.gd")

const STORE_VERSION := 1
const STORE_INDEX_PATH := "user://loop_store.json"
const STORE_LOOPS_DIR := "user://loops"

signal project_replaced                  ## A whole new project was loaded/created
signal layers_changed                    ## Layers added/removed/reordered/renamed
signal actions_changed(layer_index: int) ## Action list of a layer changed
signal action_modified(layer_index: int, action_index: int)
signal selection_changed                 ## Active layer / action selection changed
signal overlay_view_changed              ## Overlay layer / show-all toggled
signal loop_stack_changed
signal active_loop_changed(loop_id: int)
signal pending_changed(is_pending: bool)

var project: LoopProjectT
var loop_stack: Array[Dictionary] = []
var active_loop_id: int = -1

# Builder selection
var active_layer_index: int = 0
var selected_action_index: int = -1

# Overlay view state
var overlay_layer_index: int = 0
var overlay_show_all: bool = false

var current_path: String = ""
var _next_loop_id: int = 1
var _session_projects_by_id: Dictionary = {}
var _pending_by_id: Dictionary = {}


func _ready() -> void:
	_ensure_store_dirs()
	_load_or_init_store()
	if loop_stack.is_empty():
		create_loop(true)
	elif not open_loop(active_loop_id):
		open_loop(loop_stack[0].get("id", -1))


# ---------------------------------------------------------------- selection
func set_active_layer(index: int) -> void:
	index = clampi(index, 0, maxi(0, project.layers.size() - 1))
	if index == active_layer_index:
		return
	active_layer_index = index
	selected_action_index = -1
	emit_signal("selection_changed")


func set_selected_action(index: int) -> void:
	if index == selected_action_index:
		return
	selected_action_index = index
	emit_signal("selection_changed")


func active_layer() -> LoopLayerT:
	if project.layers.is_empty():
		return null
	return project.layers[clampi(active_layer_index, 0, project.layers.size() - 1)]


func selected_action() -> LoopActionT:
	var layer := active_layer()
	if layer == null:
		return null
	if selected_action_index < 0 or selected_action_index >= layer.actions.size():
		return null
	return layer.actions[selected_action_index]


# ------------------------------------------------------------------- layers
func add_layer() -> void:
	var l := LoopLayerT.make("Layer %d" % (project.layers.size() + 1), project.layers.size())
	project.layers.append(l)
	active_layer_index = project.layers.size() - 1
	selected_action_index = -1
	_mark_pending()
	emit_signal("layers_changed")
	emit_signal("selection_changed")


func remove_layer(index: int) -> void:
	if project.layers.size() <= 1:
		return
	project.layers.remove_at(index)
	active_layer_index = clampi(active_layer_index, 0, project.layers.size() - 1)
	selected_action_index = -1
	_mark_pending()
	emit_signal("layers_changed")
	emit_signal("selection_changed")


func move_layer(index: int, delta: int) -> void:
	var target := index + delta
	if target < 0 or target >= project.layers.size():
		return
	var l := project.layers[index]
	project.layers.remove_at(index)
	project.layers.insert(target, l)
	active_layer_index = target
	_mark_pending()
	emit_signal("layers_changed")
	emit_signal("selection_changed")


func rename_layer(index: int, new_name: String) -> void:
	if index < 0 or index >= project.layers.size():
		return
	project.layers[index].name = new_name
	_mark_pending()
	emit_signal("layers_changed")


# ------------------------------------------------------------------ actions
func add_action(type: int) -> void:
	var layer := active_layer()
	if layer == null:
		return
	layer.actions.append(LoopActionT.new_of_type(type))
	selected_action_index = layer.actions.size() - 1
	_mark_pending()
	emit_signal("actions_changed", active_layer_index)
	emit_signal("selection_changed")


func remove_action(index: int) -> void:
	var layer := active_layer()
	if layer == null or index < 0 or index >= layer.actions.size():
		return
	layer.actions.remove_at(index)
	selected_action_index = mini(index, layer.actions.size() - 1)
	_mark_pending()
	emit_signal("actions_changed", active_layer_index)
	emit_signal("selection_changed")


func duplicate_action(index: int) -> void:
	var layer := active_layer()
	if layer == null or index < 0 or index >= layer.actions.size():
		return
	layer.actions.insert(index + 1, layer.actions[index].duplicate_action())
	selected_action_index = index + 1
	_mark_pending()
	emit_signal("actions_changed", active_layer_index)
	emit_signal("selection_changed")


func move_action(index: int, delta: int) -> void:
	var layer := active_layer()
	if layer == null:
		return
	var target := index + delta
	if target < 0 or target >= layer.actions.size():
		return
	var a := layer.actions[index]
	layer.actions.remove_at(index)
	layer.actions.insert(target, a)
	selected_action_index = target
	_mark_pending()
	emit_signal("actions_changed", active_layer_index)
	emit_signal("selection_changed")


## Switches off one action anywhere in the project (used by playback when a
## Capture Load has nothing to load) and refreshes the UI for it.
func disable_action(layer_index: int, action_index: int) -> void:
	if project == null or layer_index < 0 or layer_index >= project.layers.size():
		return
	var layer: LoopLayerT = project.layers[layer_index]
	if action_index < 0 or action_index >= layer.actions.size():
		return
	var a: LoopActionT = layer.actions[action_index]
	if not a.enabled:
		return
	a.enabled = false
	_mark_pending()
	emit_signal("actions_changed", layer_index)
	emit_signal("action_modified", layer_index, action_index)
	if layer_index == active_layer_index and action_index == selected_action_index:
		emit_signal("selection_changed")


func notify_action_modified() -> void:
	_mark_pending()
	emit_signal("action_modified", active_layer_index, selected_action_index)


# ----------------------------------------------------------- overlay view
func set_overlay_layer(index: int) -> void:
	overlay_layer_index = clampi(index, 0, maxi(0, project.layers.size() - 1))
	emit_signal("overlay_view_changed")


func step_overlay_layer(delta: int) -> void:
	if project.layers.is_empty():
		return
	overlay_show_all = false
	overlay_layer_index = wrapi(overlay_layer_index + delta, 0, project.layers.size())
	emit_signal("overlay_view_changed")


func set_overlay_show_all(value: bool) -> void:
	overlay_show_all = value
	emit_signal("overlay_view_changed")


# ----------------------------------------------------------------- file io
func new_project() -> void:
	create_loop(true)


func create_loop(open_now: bool = true) -> int:
	var id := _next_loop_id
	_next_loop_id += 1
	var entry := {
		"id": id,
		"name": str(id),
		"file": _loop_file_path(id),
	}
	loop_stack.append(entry)
	var key := str(id)
	var p := LoopProjectT.make_default()
	p.name = entry.name
	_session_projects_by_id[key] = p
	_pending_by_id[key] = true
	active_loop_id = id if open_now else active_loop_id
	_save_store_index()
	emit_signal("loop_stack_changed")
	if open_now:
		_open_project_for_id(id)
	return id


func open_loop(loop_id: int) -> bool:
	var idx := _loop_index_from_id(loop_id)
	if idx < 0:
		return false
	_open_project_for_id(loop_id)
	return true


func step_loop(delta: int) -> bool:
	if loop_stack.is_empty():
		return false
	var current_idx := _loop_index_from_id(active_loop_id)
	if current_idx < 0:
		current_idx = 0
	var target := wrapi(current_idx + delta, 0, loop_stack.size())
	return open_loop(int(loop_stack[target].get("id", -1)))


func save_active_loop() -> Error:
	var idx := _loop_index_from_id(active_loop_id)
	if idx < 0:
		return ERR_DOES_NOT_EXIST
	var entry := loop_stack[idx]
	if project == null:
		return ERR_INVALID_DATA
	if project.name.strip_edges().is_empty():
		project.name = str(active_loop_id)
	entry["name"] = project.name
	loop_stack[idx] = entry
	var err := _write_project_file(String(entry.get("file", "")), project)
	if err != OK:
		return err
	current_path = String(entry.get("file", ""))
	_pending_by_id[str(active_loop_id)] = false
	_save_store_index()
	emit_signal("loop_stack_changed")
	emit_signal("pending_changed", false)
	return OK


func active_loop_is_pending() -> bool:
	if active_loop_id < 0:
		return false
	return bool(_pending_by_id.get(str(active_loop_id), false))


func loop_is_pending(loop_id: int) -> bool:
	if loop_id < 0:
		return false
	return bool(_pending_by_id.get(str(loop_id), false))


func active_loop_display_name() -> String:
	var idx := _loop_index_from_id(active_loop_id)
	if idx < 0:
		return "-"
	var entry := loop_stack[idx]
	var raw := String(entry.get("name", str(active_loop_id))).strip_edges()
	return raw if not raw.is_empty() else str(active_loop_id)


func active_loop_stack_index() -> int:
	return _loop_index_from_id(active_loop_id)


func save_to(path: String) -> Error:
	# Legacy export path retained for compatibility.
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	project.name = path.get_file().get_basename()
	f.store_string(project.to_json())
	f.close()
	current_path = path
	_mark_pending()
	return OK


func load_from(path: String) -> Error:
	# Legacy import path retained for compatibility.
	if not FileAccess.file_exists(path):
		return ERR_FILE_NOT_FOUND
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return FileAccess.get_open_error()
	var text := f.get_as_text()
	f.close()
	project = LoopProjectT.from_json(text)
	active_layer_index = 0
	selected_action_index = -1
	overlay_layer_index = 0
	overlay_show_all = false
	current_path = path
	_mark_pending()
	emit_signal("project_replaced")
	return OK


func _mark_pending() -> void:
	if active_loop_id < 0:
		return
	var key := str(active_loop_id)
	_session_projects_by_id[key] = project
	if bool(_pending_by_id.get(key, false)):
		return
	_pending_by_id[key] = true
	emit_signal("pending_changed", true)
	emit_signal("loop_stack_changed")


func _open_project_for_id(loop_id: int) -> void:
	var idx := _loop_index_from_id(loop_id)
	if idx < 0:
		return
	active_loop_id = loop_id
	var key := str(loop_id)
	if not _session_projects_by_id.has(key):
		var entry := loop_stack[idx]
		var loaded := _read_project_file(String(entry.get("file", "")), String(entry.get("name", str(loop_id))))
		_session_projects_by_id[key] = loaded
		_pending_by_id[key] = bool(_pending_by_id.get(key, false))
	project = _session_projects_by_id[key]
	if project.name.strip_edges().is_empty():
		project.name = String(loop_stack[idx].get("name", str(loop_id)))
	active_layer_index = 0
	selected_action_index = -1
	overlay_layer_index = 0
	overlay_show_all = false
	current_path = String(loop_stack[idx].get("file", ""))
	_save_store_index()
	emit_signal("project_replaced")
	emit_signal("active_loop_changed", active_loop_id)
	emit_signal("pending_changed", active_loop_is_pending())


func _ensure_store_dirs() -> void:
	var abs_dir := ProjectSettings.globalize_path(STORE_LOOPS_DIR)
	DirAccess.make_dir_recursive_absolute(abs_dir)


func _load_or_init_store() -> void:
	if not FileAccess.file_exists(STORE_INDEX_PATH):
		loop_stack = []
		active_loop_id = -1
		_next_loop_id = 1
		_save_store_index()
		return
	var f := FileAccess.open(STORE_INDEX_PATH, FileAccess.READ)
	if f == null:
		loop_stack = []
		active_loop_id = -1
		_next_loop_id = 1
		return
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		loop_stack = []
		active_loop_id = -1
		_next_loop_id = 1
		return
	var data: Dictionary = parsed
	loop_stack = []
	for raw in data.get("loops", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = raw
		var id := int(e.get("id", -1))
		if id < 0:
			continue
		loop_stack.append({
			"id": id,
			"name": String(e.get("name", str(id))),
			"file": _store_loop_file(id, String(e.get("file", ""))),
		})
	_next_loop_id = maxi(1, int(data.get("next_loop_id", 1)))
	for e in loop_stack:
		_next_loop_id = maxi(_next_loop_id, int(e.get("id", 0)) + 1)
	active_loop_id = int(data.get("active_loop_id", -1))
	if _loop_index_from_id(active_loop_id) < 0 and not loop_stack.is_empty():
		active_loop_id = int(loop_stack[0].get("id", -1))


func _save_store_index() -> void:
	var payload := {
		"version": STORE_VERSION,
		"next_loop_id": _next_loop_id,
		"active_loop_id": active_loop_id,
		"loops": loop_stack,
	}
	var f := FileAccess.open(STORE_INDEX_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(payload, "\t"))
	f.close()


func _loop_index_from_id(loop_id: int) -> int:
	for i in loop_stack.size():
		if int(loop_stack[i].get("id", -1)) == loop_id:
			return i
	return -1


func _loop_file_path(loop_id: int) -> String:
	return "%s/%d.loop" % [STORE_LOOPS_DIR, loop_id]


## The file a store entry may point at: a `.loop` directly inside
## user://loops, nothing else. The index is read back from disk and its paths
## are used for both reads and writes, so an entry that names any other
## location (a different folder, a parent directory, another file type) is
## given the default path for its id instead.
static func _store_loop_file(loop_id: int, raw: String) -> String:
	var file := raw.get_file()
	if raw == "%s/%s" % [STORE_LOOPS_DIR, file] and file.is_valid_filename() \
			and file.get_extension() == "loop" and file.get_basename().length() > 0:
		return raw
	return "%s/%d.loop" % [STORE_LOOPS_DIR, loop_id]


func _read_project_file(path: String, fallback_name: String) -> LoopProjectT:
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var text := f.get_as_text()
			f.close()
			var loaded := LoopProjectT.from_json(text)
			if loaded.name.strip_edges().is_empty():
				loaded.name = fallback_name
			return loaded
	var p := LoopProjectT.make_default()
	p.name = fallback_name
	return p


func _write_project_file(path: String, value: LoopProjectT) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(value.to_json())
	f.close()
	return OK
