extends Control
## Builder window: toolbar, layer panel, action list, and a dynamic action
## editor. Talks to the ProjectData / Playback autoloads and drives the overlay.

const OverlayScene := preload("res://scenes/overlay.tscn")
const OverlayT := preload("res://scripts/overlay.gd")
const PickOverlayT := preload("res://scripts/pick_overlay.gd")

## Preload model scripts so all type/enum references resolve regardless of
## script import order (the global `class_name` registry may lag on first import).
const LoopActionT := preload("res://scripts/model/loop_action.gd")
const LoopLayerT := preload("res://scripts/model/loop_layer.gd")

# --- top-level UI refs ----------------------------------------------------
var status_label: Label
var play_btn: Button
var loop_prev_btn: Button
var loop_next_btn: Button
var loop_picker: OptionButton
var overlay_btn: Button
var overlay_label: Label
var show_all_btn: Button
var backend_option: OptionButton
var loop_delay_spin: SpinBox
var new_btn: Button
var save_btn: Button
var export_btn: Button
var load_btn: Button
var _ui_root: VBoxContainer
var _main_split: HSplitContainer
var _edit_lock_blocker: ColorRect
var _stop_cooldown_active: bool = false
var _stop_cooldown_token: int = 0

const STOP_COOLDOWN_STEP_SEC := 0.18

# --- layer panel ----------------------------------------------------------
var layer_list: ItemList
var layer_visible_check: CheckBox
var layer_enabled_check: CheckBox
var layer_color_btn: ColorPickerButton

# --- action panel ---------------------------------------------------------
var actions_header: Label
var action_list: ItemList
## Which layer's actions the action_list currently shows (-1 = none/stale).
var _shown_layer_index: int = -1

# --- editor ---------------------------------------------------------------
var editor_box: VBoxContainer
var _loading_editor: bool = false

# --- overlay --------------------------------------------------------------
var overlay: OverlayT

# --- on-screen picking ----------------------------------------------------
var picker: PickOverlayT
var _pick_active: bool = false
var _pick_was_overlay_visible: bool = false
var _pick_point_cb: Callable = Callable()
var _pick_rect_cb: Callable = Callable()


func _ready() -> void:
	_configure_window()
	_build_ui()
	_connect_signals()
	_refresh_layers()
	_refresh_actions()
	_refresh_layer_props()
	_rebuild_editor()
	_create_overlay()
	_refresh_edit_lock()


func _configure_window() -> void:
	var win := get_window()
	if win == null:
		return
	# Keep the builder comfortably sized on launch while still scaling on small
	# displays and preserving user resize behavior afterward.
	win.min_size = Vector2i(960, 620)
	var screen := maxi(0, win.current_screen)
	var usable := DisplayServer.screen_get_usable_rect(screen)
	var target := Vector2i(mini(usable.size.x - 40, 1160), mini(usable.size.y - 56, 760))
	target.x = maxi(target.x, win.min_size.x)
	target.y = maxi(target.y, win.min_size.y)
	win.size = target
	win.position = usable.position + (usable.size - target) / 2
	# Keep control sizes stable while resizing (no automatic UI zoom).
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED


# ======================================================================
#  UI construction
# ======================================================================
func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 0)
	add_child(root)
	_ui_root = root

	root.add_child(_build_toolbar())

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.split_offset = 240
	root.add_child(split)
	_main_split = split

	split.add_child(_build_layer_panel())

	var right_split := HSplitContainer.new()
	right_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_split.split_offset = 380
	split.add_child(right_split)

	right_split.add_child(_build_action_panel())
	right_split.add_child(_build_editor_panel())

	_edit_lock_blocker = ColorRect.new()
	_edit_lock_blocker.set_anchors_preset(Control.PRESET_FULL_RECT)
	_edit_lock_blocker.color = Color(0.0, 0.0, 0.0, 0.20)
	_edit_lock_blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	_edit_lock_blocker.visible = false
	split.add_child(_edit_lock_blocker)
	_edit_lock_blocker.move_to_front()

	root.add_child(_build_status_bar())


func _build_status_bar() -> Control:
	var bar := PanelContainer.new()
	var hb := HBoxContainer.new()
	bar.add_child(hb)
	status_label = Label.new()
	status_label.text = "Ready."
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.clip_text = true
	hb.add_child(status_label)
	return bar


func _build_toolbar() -> Control:
	var bar := PanelContainer.new()
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)

	# --- Playback ---------------------------------------------------------
	play_btn = _tool_button("▶ Run!", _on_play_pressed)
	hb.add_child(play_btn)

	var backend_lbl := Label.new()
	backend_lbl.text = "Mode"
	hb.add_child(backend_lbl)
	backend_option = OptionButton.new()
	backend_option.add_item("Preview (safe)", Playback.BackendKind.PREVIEW)
	backend_option.add_item("Windows (real)", Playback.BackendKind.WINDOWS)
	backend_option.item_selected.connect(_on_backend_selected)
	hb.add_child(backend_option)

	hb.add_child(_vsep())

	# --- Loop management --------------------------------------------------
	var loop_lbl := Label.new()
	loop_lbl.text = "Loop"
	hb.add_child(loop_lbl)
	loop_prev_btn = _tool_button("◀", func(): ProjectData.step_loop(-1))
	hb.add_child(loop_prev_btn)
	loop_picker = OptionButton.new()
	loop_picker.custom_minimum_size = Vector2(210, 0)
	loop_picker.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	loop_picker.item_selected.connect(_on_loop_picker_selected)
	hb.add_child(loop_picker)
	loop_next_btn = _tool_button("▶", func(): ProjectData.step_loop(1))
	hb.add_child(loop_next_btn)

	new_btn = _tool_button("New", _on_new)
	hb.add_child(new_btn)
	save_btn = _tool_button("Commit", _on_save)
	hb.add_child(save_btn)
	export_btn = _tool_button("Export", _on_export)
	export_btn.tooltip_text = "Export the current loop to a .loop file"
	hb.add_child(export_btn)

	hb.add_child(_vsep())

	# --- Timing -----------------------------------------------------------
	var delay_lbl := Label.new()
	delay_lbl.text = "Delay ms"
	hb.add_child(delay_lbl)
	loop_delay_spin = SpinBox.new()
	loop_delay_spin.min_value = 0
	loop_delay_spin.max_value = 60000
	loop_delay_spin.step = 10
	loop_delay_spin.value = ProjectData.project.loop_delay_ms
	loop_delay_spin.value_changed.connect(func(v): ProjectData.project.loop_delay_ms = int(v))
	hb.add_child(loop_delay_spin)

	# Let the toolbar scroll horizontally instead of pushing items off-screen
	# on narrow windows.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 34)
	hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(hb)
	bar.add_child(scroll)

	return bar


func _build_layer_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(220, 0)
	var vb := VBoxContainer.new()
	panel.add_child(vb)

	vb.add_child(_section_label("Layers"))

	layer_list = ItemList.new()
	layer_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layer_list.allow_reselect = true
	layer_list.item_selected.connect(func(i):
		ProjectData.set_active_layer(i)
		# Keep the overlay focused on the layer you're editing (unless showing all).
		if not ProjectData.overlay_show_all:
			ProjectData.set_overlay_layer(i))
	layer_list.item_activated.connect(func(i): _rename_layer_dialog(i))
	vb.add_child(layer_list)

	var btns := HBoxContainer.new()
	btns.add_child(_tool_button("＋", func(): ProjectData.add_layer()))
	btns.add_child(_tool_button("✕", func(): ProjectData.remove_layer(ProjectData.active_layer_index)))
	btns.add_child(_tool_button("▲", func(): ProjectData.move_layer(ProjectData.active_layer_index, -1)))
	btns.add_child(_tool_button("▼", func(): ProjectData.move_layer(ProjectData.active_layer_index, 1)))
	btns.add_child(_tool_button("Rename", func(): _rename_layer_dialog(ProjectData.active_layer_index)))
	vb.add_child(btns)

	vb.add_child(HSeparator.new())
	vb.add_child(_section_label("Overlay view"))

	var ov_row := HBoxContainer.new()
	overlay_btn = Button.new()
	overlay_btn.text = "Overlay"
	overlay_btn.toggle_mode = true
	overlay_btn.focus_mode = Control.FOCUS_NONE
	overlay_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	overlay_btn.toggled.connect(_on_overlay_toggle)
	ov_row.add_child(overlay_btn)
	show_all_btn = Button.new()
	show_all_btn.text = "All"
	show_all_btn.toggle_mode = true
	show_all_btn.focus_mode = Control.FOCUS_NONE
	show_all_btn.tooltip_text = "Draw every visible layer at once (\\)"
	show_all_btn.toggled.connect(func(v): ProjectData.set_overlay_show_all(v))
	ov_row.add_child(show_all_btn)
	vb.add_child(ov_row)

	var nav_row := HBoxContainer.new()
	var prev_layer_btn := _tool_button("◀", func(): _go_overlay_layer(-1))
	prev_layer_btn.tooltip_text = "Previous layer"
	nav_row.add_child(prev_layer_btn)
	overlay_label = Label.new()
	overlay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	overlay_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	overlay_label.clip_text = true
	overlay_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nav_row.add_child(overlay_label)
	var next_layer_btn := _tool_button("▶", func(): _go_overlay_layer(1))
	next_layer_btn.tooltip_text = "Next layer"
	nav_row.add_child(next_layer_btn)
	vb.add_child(nav_row)

	vb.add_child(HSeparator.new())
	vb.add_child(_section_label("Layer properties"))

	layer_visible_check = CheckBox.new()
	layer_visible_check.text = "Visible in overlay"
	layer_visible_check.toggled.connect(func(v):
		var l := ProjectData.active_layer()
		if l: l.visible = v
		ProjectData.emit_signal("layers_changed")
		ProjectData.emit_signal("overlay_view_changed"))
	vb.add_child(layer_visible_check)

	layer_enabled_check = CheckBox.new()
	layer_enabled_check.text = "Enabled (runs in loop)"
	layer_enabled_check.toggled.connect(func(v):
		var l := ProjectData.active_layer()
		if l: l.enabled = v
		ProjectData.emit_signal("layers_changed"))
	vb.add_child(layer_enabled_check)

	var color_row := HBoxContainer.new()
	var cl := Label.new()
	cl.text = "Colour:"
	color_row.add_child(cl)
	layer_color_btn = ColorPickerButton.new()
	layer_color_btn.custom_minimum_size = Vector2(60, 0)
	layer_color_btn.color_changed.connect(func(c):
		var l := ProjectData.active_layer()
		if l: l.color = c
		ProjectData.emit_signal("layers_changed")
		ProjectData.emit_signal("overlay_view_changed"))
	color_row.add_child(layer_color_btn)
	vb.add_child(color_row)

	return panel


func _build_action_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(320, 0)
	var vb := VBoxContainer.new()
	panel.add_child(vb)

	actions_header = _section_label("Actions")
	vb.add_child(actions_header)

	action_list = ItemList.new()
	action_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	action_list.allow_reselect = true
	action_list.item_selected.connect(func(i): ProjectData.set_selected_action(i))
	vb.add_child(action_list)

	var add_row := HBoxContainer.new()
	var add_btn := MenuButton.new()
	add_btn.text = "＋ Add Action"
	var pm := add_btn.get_popup()
	for t in [LoopActionT.Type.MOVE, LoopActionT.Type.CLICK, LoopActionT.Type.DRAG,
			LoopActionT.Type.KEY, LoopActionT.Type.WAIT, LoopActionT.Type.PIXEL_DETECT]:
		pm.add_item(LoopActionT.type_name(t), t)
	pm.id_pressed.connect(func(id): ProjectData.add_action(id))
	add_row.add_child(add_btn)
	vb.add_child(add_row)

	var btns := HBoxContainer.new()
	btns.add_child(_tool_button("✕ Delete", func(): ProjectData.remove_action(ProjectData.selected_action_index)))
	btns.add_child(_tool_button("⧉ Duplicate", func(): ProjectData.duplicate_action(ProjectData.selected_action_index)))
	btns.add_child(_tool_button("▲", func(): ProjectData.move_action(ProjectData.selected_action_index, -1)))
	btns.add_child(_tool_button("▼", func(): ProjectData.move_action(ProjectData.selected_action_index, 1)))
	vb.add_child(btns)

	return panel


func _build_editor_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(320, 0)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(scroll)
	editor_box = VBoxContainer.new()
	editor_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(editor_box)
	return panel


# ======================================================================
#  Signals
# ======================================================================
func _connect_signals() -> void:
	ProjectData.layers_changed.connect(_refresh_layers)
	ProjectData.layers_changed.connect(_refresh_actions)
	ProjectData.layers_changed.connect(_refresh_overlay_label)
	ProjectData.actions_changed.connect(func(_i): _refresh_actions())
	ProjectData.selection_changed.connect(_on_selection_changed)
	ProjectData.overlay_view_changed.connect(_refresh_overlay_label)
	ProjectData.project_replaced.connect(_on_project_replaced)
	ProjectData.loop_stack_changed.connect(_refresh_loop_stack_ui)
	ProjectData.active_loop_changed.connect(func(_id): _refresh_loop_stack_ui())
	ProjectData.pending_changed.connect(func(_p): _refresh_loop_stack_ui())

	Playback.status.connect(func(m): status_label.text = m)
	Playback.playback_started.connect(func():
		_stop_cooldown_token += 1
		_stop_cooldown_active = false
		play_btn.text = "■ Stop"
		_refresh_edit_lock())
	Playback.playback_stopped.connect(func():
		var was_real := Playback.backend != null and Playback.backend.is_real()
		if was_real:
			_switch_to_safe_backend_if_needed()
		await _animate_stop_feedback(was_real))
	Playback.action_executing.connect(_on_action_executing)
	_refresh_overlay_label()
	_refresh_loop_stack_ui()


func _on_selection_changed() -> void:
	_refresh_layers_selection()
	# If the active layer changed, repopulate the action list with that layer's
	# actions; otherwise just move the selection highlight.
	if _shown_layer_index != ProjectData.active_layer_index:
		_refresh_actions()
	else:
		_refresh_actions_selection()
	_refresh_layer_props()
	_rebuild_editor()


func _on_project_replaced() -> void:
	loop_delay_spin.value = ProjectData.project.loop_delay_ms
	_refresh_layers()
	_refresh_actions()
	_refresh_layer_props()
	_rebuild_editor()
	_refresh_overlay_label()
	_refresh_loop_stack_ui()


func _on_action_executing(layer_index: int, action_index: int) -> void:
	if layer_index == ProjectData.active_layer_index and action_index >= 0 \
			and action_index < action_list.item_count:
		action_list.select(action_index)


# ======================================================================
#  Refresh helpers
# ======================================================================
func _refresh_layers() -> void:
	layer_list.clear()
	for i in ProjectData.project.layers.size():
		var l: LoopLayerT = ProjectData.project.layers[i]
		var mark := "" if l.enabled else " (off)"
		layer_list.add_item("%s%s" % [l.name, mark])
		layer_list.set_item_custom_fg_color(i, l.color)
	_refresh_layers_selection()


func _refresh_layers_selection() -> void:
	var idx := ProjectData.active_layer_index
	if idx >= 0 and idx < layer_list.item_count:
		layer_list.select(idx)


func _refresh_layer_props() -> void:
	var l := ProjectData.active_layer()
	if l == null:
		return
	layer_visible_check.set_pressed_no_signal(l.visible)
	layer_enabled_check.set_pressed_no_signal(l.enabled)
	layer_color_btn.color = l.color


func _refresh_actions() -> void:
	action_list.clear()
	var l := ProjectData.active_layer()
	if l != null:
		actions_header.text = "Actions — %s" % l.name
		for i in l.actions.size():
			var a: LoopActionT = l.actions[i]
			var prefix := "✔ " if a.enabled else "✖ "
			action_list.add_item("%s%d. %s" % [prefix, i + 1, a.describe()])
			if not a.comment.is_empty():
				action_list.set_item_tooltip(i, a.comment)
	else:
		actions_header.text = "Actions"
	# Remember which layer is shown so selection_changed knows when to repopulate.
	_shown_layer_index = ProjectData.active_layer_index
	_refresh_actions_selection()


func _refresh_actions_selection() -> void:
	var idx := ProjectData.selected_action_index
	if idx >= 0 and idx < action_list.item_count:
		action_list.select(idx)


func _update_selected_list_item() -> void:
	var idx := ProjectData.selected_action_index
	var a := ProjectData.selected_action()
	if a == null or idx < 0 or idx >= action_list.item_count:
		return
	var prefix := "✔ " if a.enabled else "✖ "
	action_list.set_item_text(idx, "%s%d. %s" % [prefix, idx + 1, a.describe()])


# ======================================================================
#  Dynamic action editor
# ======================================================================
func _rebuild_editor() -> void:
	_loading_editor = true
	for c in editor_box.get_children():
		c.queue_free()

	var a := ProjectData.selected_action()
	if a == null:
		var hint := Label.new()
		hint.text = "Select or add an action to edit it."
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		editor_box.add_child(hint)
		_loading_editor = false
		return

	editor_box.add_child(_section_label("Edit: %s" % LoopActionT.type_name(a.type)))

	var en := CheckBox.new()
	en.text = "Enabled"
	en.button_pressed = a.enabled
	en.toggled.connect(func(v):
		a.enabled = v
		_after_edit())
	editor_box.add_child(en)

	match a.type:
		LoopActionT.Type.MOVE:
			_add_point_fields(a, false)
			_add_int_field("Duration (ms)", a.duration_ms, 0, 60000, func(v): a.duration_ms = v)
		LoopActionT.Type.CLICK:
			_add_point_fields(a, false)
			_add_button_field(a)
		LoopActionT.Type.DRAG:
			_add_point_fields(a, true)
			_add_button_field(a)
			_add_int_field("Duration (ms)", a.duration_ms, 0, 60000, func(v): a.duration_ms = v)
		LoopActionT.Type.KEY:
			_add_keys_field(a)
		LoopActionT.Type.WAIT:
			_add_int_field("Wait (ms)", a.wait_ms, 0, 600000, func(v): a.wait_ms = v)
		LoopActionT.Type.PIXEL_DETECT:
			_add_rect_fields(a)
			_add_color_field(a)
			_add_int_field("Tolerance (0-255)", a.tolerance, 0, 255, func(v): a.tolerance = v)
			_add_on_fail_field(a)

	_add_comment_field(a)
	_loading_editor = false


func _after_edit() -> void:
	if _loading_editor:
		return
	ProjectData.notify_action_modified()
	_update_selected_list_item()


func _add_point_fields(a: LoopActionT, second: bool) -> void:
	editor_box.add_child(_section_label("Point" + (" A" if second else "")))
	_add_int_field("X", a.x, -20000, 20000, func(v): a.x = v)
	_add_int_field("Y", a.y, -20000, 20000, func(v): a.y = v)
	editor_box.add_child(_grab_button("🎯 Pick on screen", func():
		_begin_point_pick(func(g: Vector2i):
			a.x = g.x
			a.y = g.y)))
	if second:
		editor_box.add_child(_section_label("Point B"))
		_add_int_field("X2", a.x2, -20000, 20000, func(v): a.x2 = v)
		_add_int_field("Y2", a.y2, -20000, 20000, func(v): a.y2 = v)
		editor_box.add_child(_grab_button("🎯 Pick B on screen", func():
			_begin_point_pick(func(g: Vector2i):
				a.x2 = g.x
				a.y2 = g.y)))


func _add_rect_fields(a: LoopActionT) -> void:
	editor_box.add_child(_section_label("Detection rect"))
	_add_int_field("X", a.x, -20000, 20000, func(v): a.x = v)
	_add_int_field("Y", a.y, -20000, 20000, func(v): a.y = v)
	_add_int_field("Width", a.w, 1, 20000, func(v): a.w = v)
	_add_int_field("Height", a.h, 1, 20000, func(v): a.h = v)
	editor_box.add_child(_grab_button("🎯 Pick rect on screen", func():
		_begin_rect_pick(func(r: Rect2i):
			a.x = r.position.x
			a.y = r.position.y
			a.w = maxi(1, r.size.x)
			a.h = maxi(1, r.size.y))))


func _add_button_field(a: LoopActionT) -> void:
	var row := _row("Button")
	var opt := OptionButton.new()
	opt.add_item("Left", LoopActionT.BUTTON_LEFT)
	opt.add_item("Right", LoopActionT.BUTTON_RIGHT)
	opt.add_item("Middle", LoopActionT.BUTTON_MIDDLE)
	opt.select(a.button)
	opt.item_selected.connect(func(i):
		a.button = opt.get_item_id(i)
		_after_edit())
	row.add_child(opt)
	editor_box.add_child(row)


func _add_keys_field(a: LoopActionT) -> void:
	var row := _row("Keys")
	var le := LineEdit.new()
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.text = a.keys
	le.placeholder_text = "e.g. abc, {ENTER}, ^c"
	le.text_changed.connect(func(t):
		a.keys = t
		_after_edit())
	row.add_child(le)
	editor_box.add_child(row)
	var hint := Label.new()
	hint.text = "Windows SendKeys format: {ENTER} {TAB} {ESC} ^c (Ctrl+C) %{F4} (Alt+F4)"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(1, 1, 1, 0.7)
	editor_box.add_child(hint)


func _add_color_field(a: LoopActionT) -> void:
	var row := _row("Expected colour")
	var cp := ColorPickerButton.new()
	cp.custom_minimum_size = Vector2(60, 0)
	cp.color = a.color
	cp.color_changed.connect(func(c):
		a.color = c
		_after_edit())
	row.add_child(cp)
	var just := _grab_button("🎨 Just sample", func():
		# Pick a point and read its colour only; the rect stays where it is.
		_begin_point_pick(func(g: Vector2i):
			_sample_color_into(a, g)))
	just.tooltip_text = "Click a point on screen to sample its colour. The rect is left untouched."
	row.add_child(just)
	var pick := _grab_button("🎯 Pick & sample", func():
		_begin_point_pick(func(g: Vector2i):
			# Centre the rect on the picked point, so the pixel sampled here is
			# the same one playback checks (it reads the rect's centre).
			a.x = g.x - a.w / 2
			a.y = g.y - a.h / 2
			# Read the *true* screen colour (overlay hidden) into a.color.
			_sample_color_into(a, g)))
	pick.tooltip_text = "Click a point on screen; the rect is centred on it and its colour sampled."
	row.add_child(pick)
	editor_box.add_child(row)


func _add_on_fail_field(a: LoopActionT) -> void:
	var row := _row("If not found")
	var opt := OptionButton.new()
	opt.add_item("Continue", LoopActionT.OnFail.CONTINUE)
	opt.add_item("Skip rest of layer", LoopActionT.OnFail.SKIP_LAYER)
	opt.add_item("Stop loop", LoopActionT.OnFail.STOP_LOOP)
	opt.select(a.on_fail)
	opt.item_selected.connect(func(i):
		a.on_fail = opt.get_item_id(i)
		_after_edit())
	row.add_child(opt)
	editor_box.add_child(row)


func _add_comment_field(a: LoopActionT) -> void:
	editor_box.add_child(HSeparator.new())
	var row := _row("Comment")
	var le := LineEdit.new()
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.text = a.comment
	le.text_changed.connect(func(t):
		a.comment = t
		_after_edit())
	row.add_child(le)
	editor_box.add_child(row)


func _add_int_field(label: String, value: int, min_v: int, max_v: int, setter: Callable) -> void:
	var row := _row(label)
	var sp := SpinBox.new()
	sp.min_value = min_v
	sp.max_value = max_v
	sp.step = 1
	sp.value = value
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.value_changed.connect(func(v):
		setter.call(int(v))
		_after_edit())
	row.add_child(sp)
	editor_box.add_child(row)


# ======================================================================
#  Overlay handling
# ======================================================================
func _create_overlay() -> void:
	overlay = OverlayScene.instantiate()
	add_child(overlay)
	overlay.hide()
	overlay.click_through_changed.connect(_on_overlay_click_through_changed)
	# Separate interactive window for on-screen picking, so the view overlay can
	# stay click-through while a pick captures the click instead.
	picker = PickOverlayT.new()
	picker.visible = false
	add_child(picker)
	picker.point_picked.connect(_on_point_picked)
	picker.rect_picked.connect(_on_rect_picked)
	picker.pick_canceled.connect(_on_pick_canceled)


func _on_overlay_toggle(pressed: bool) -> void:
	if pressed:
		overlay.show_overlay()
		if not overlay.transparency_available():
			status_label.text = "Overlay on, but window transparency is unavailable with the %s renderer — it will be opaque. Use the Compatibility renderer." % RenderingServer.get_current_rendering_method()
	else:
		overlay.hide_overlay()
		status_label.text = "Overlay off."


func _on_overlay_click_through_changed(state: int) -> void:
	if _pick_active or not overlay.transparency_available():
		return
	match state:
		OverlayT.ClickThrough.PENDING:
			status_label.text = "Overlay on — enabling click-through…"
		OverlayT.ClickThrough.NATIVE:
			status_label.text = "Overlay on — click-through active, the desktop stays usable underneath."
		OverlayT.ClickThrough.FLAG_ONLY:
			status_label.text = "Overlay on."
		OverlayT.ClickThrough.FAILED:
			status_label.text = "Overlay on — click-through helper (PowerShell) failed; the overlay blocks mouse input under it. Toggle it off to interact."


# ----------------------------------------------------------- on-screen pick
## Start picking a single screen point; `cb` receives a Vector2i (global coords).
func _begin_point_pick(cb: Callable) -> void:
	if _pick_active:
		return
	_pick_point_cb = cb
	_pick_rect_cb = Callable()
	_start_pick(PickOverlayT.PickKind.POINT)


## Start picking a screen rectangle; `cb` receives a Rect2i (global coords).
func _begin_rect_pick(cb: Callable) -> void:
	if _pick_active:
		return
	_pick_rect_cb = cb
	_pick_point_cb = Callable()
	_start_pick(PickOverlayT.PickKind.RECT)


func _start_pick(kind: int) -> void:
	_pick_active = true
	_pick_was_overlay_visible = overlay.visible
	# Show the guides underneath while placing, so existing points are visible.
	if not overlay.visible:
		overlay.show_overlay()
	status_label.text = "Pick on screen — left-click to set, right-click / Esc to cancel."
	picker.begin_pick(kind)


func _finish_pick() -> void:
	_pick_active = false
	_pick_point_cb = Callable()
	_pick_rect_cb = Callable()
	picker.end_pick()
	# If the overlay was only shown for picking, hide it again.
	if not _pick_was_overlay_visible and not overlay_btn.button_pressed:
		overlay.hide_overlay()
	# Return keyboard focus to the builder window.
	get_window().grab_focus()


func _on_point_picked(g: Vector2i) -> void:
	if _pick_point_cb.is_valid():
		_pick_point_cb.call(g)
	status_label.text = "Set point (%d, %d)." % [g.x, g.y]
	_finish_pick()
	_after_edit()
	_rebuild_editor()


func _on_rect_picked(r: Rect2i) -> void:
	if _pick_rect_cb.is_valid():
		_pick_rect_cb.call(r)
	status_label.text = "Set rect [%d, %d, %d×%d]." % [r.position.x, r.position.y, r.size.x, r.size.y]
	_finish_pick()
	_after_edit()
	_rebuild_editor()


func _on_pick_canceled() -> void:
	status_label.text = "Pick canceled."
	_finish_pick()


## Sample the true screen colour under `g` into `a.color`. The overlay is hidden
## first so its dim tint / crosshair isn't captured by the screen read, and the
## builder window is minimised for the read if it covers `g` — pressing a button
## in the builder raises it over the target, so it would otherwise sample itself.
func _sample_color_into(a: LoopActionT, g: Vector2i) -> void:
	var sampler := Playback.get_screen_sampler()
	if sampler == null:
		status_label.text = "Colour sampling needs the Windows backend (no real screen reader on this OS)."
		return
	var restore_overlay := overlay_btn.button_pressed
	# Hide the overlay window and give the OS compositor a moment to repaint the
	# desktop without it, so we read the real pixel and not our own overlay.
	overlay.hide_overlay()
	# Yield first: when called from a pick, _finish_pick() runs right after this
	# and re-raises the builder with grab_focus(), so decide about it afterwards.
	await get_tree().process_frame
	var win := get_window()
	var builder_rect := Rect2i(win.get_position_with_decorations(), win.get_size_with_decorations())
	var move_builder := builder_rect.has_point(g)
	var prev_mode := win.mode
	if move_builder:
		status_label.text = "Sampling (%d, %d)…" % [g.x, g.y]
		win.mode = Window.MODE_MINIMIZED
		await get_tree().process_frame
	# The minimise animation needs longer to clear the pixel than the overlay does.
	await get_tree().create_timer(0.35 if move_builder else 0.06).timeout
	var c := sampler.get_pixel(g)
	if move_builder:
		win.mode = prev_mode
		win.grab_focus()
	if restore_overlay:
		overlay.show_overlay()
	if c.a > 0.0:
		a.color = c
		status_label.text = "Sampled #%s at (%d, %d)." % [c.to_html(false), g.x, g.y]
		_after_edit()
		_rebuild_editor()
	else:
		status_label.text = "Couldn't read a pixel at (%d, %d)." % [g.x, g.y]


## Flip the overlay to the previous/next layer AND make it the active (edited)
## layer, so navigating "screens" also moves the editor to that screen.
func _go_overlay_layer(delta: int) -> void:
	ProjectData.step_overlay_layer(delta)
	ProjectData.set_active_layer(ProjectData.overlay_layer_index)


## Jump straight to a specific layer index in both the overlay and the editor.
func _go_to_layer(index: int) -> void:
	if index < 0 or index >= ProjectData.project.layers.size():
		return
	ProjectData.set_overlay_layer(index)
	ProjectData.set_overlay_show_all(false)
	ProjectData.set_active_layer(index)


## Keep the toolbar indicator + Show All toggle in sync with the overlay view.
func _refresh_overlay_label() -> void:
	if overlay_label == null:
		return
	var layers := ProjectData.project.layers
	var text_full := ""
	var text_short := ""
	if ProjectData.overlay_show_all:
		text_full = "View: All (%d)" % layers.size()
		text_short = text_full
	else:
		var idx := clampi(ProjectData.overlay_layer_index, 0, maxi(0, layers.size() - 1))
		if idx < layers.size():
			text_full = "View: %d/%d - %s" % [idx + 1, layers.size(), layers[idx].name]
			text_short = "View: %d/%d - %s" % [idx + 1, layers.size(), _shorten_text(layers[idx].name, 26)]
		else:
			text_full = "View: -"
			text_short = text_full
	overlay_label.text = text_short
	overlay_label.tooltip_text = text_full
	if show_all_btn != null:
		show_all_btn.set_pressed_no_signal(ProjectData.overlay_show_all)


func _refresh_loop_stack_ui() -> void:
	if loop_picker == null:
		return
	var previous_id := ProjectData.active_loop_id
	var active_idx := -1
	loop_picker.clear()
	for i in ProjectData.loop_stack.size():
		var entry: Dictionary = ProjectData.loop_stack[i]
		var id := int(entry.get("id", -1))
		if id < 0:
			continue
		var name := String(entry.get("name", str(id))).strip_edges()
		if name.is_empty():
			name = str(id)
		var dirty_mark := " *" if ProjectData.loop_is_pending(id) else ""
		loop_picker.add_item("%d. %s%s" % [id, _shorten_text(name, 28), dirty_mark], id)
		if id == previous_id:
			active_idx = loop_picker.item_count - 1
	if active_idx >= 0:
		loop_picker.select(active_idx)
	var total := ProjectData.loop_stack.size()
	if loop_prev_btn != null:
		loop_prev_btn.disabled = total <= 1
	if loop_next_btn != null:
		loop_next_btn.disabled = total <= 1
	if save_btn != null:
		var pending_mark := " *" if ProjectData.active_loop_is_pending() else ""
		save_btn.text = "Commit%s" % pending_mark
	var loop_name := _shorten_text(ProjectData.active_loop_display_name(), 32)
	var pending_text := " (pending)" if ProjectData.active_loop_is_pending() else ""
	var idx := maxi(0, ProjectData.active_loop_stack_index()) + 1
	status_label.text = "Loop %d/%d · %s%s" % [idx, maxi(1, total), loop_name, pending_text]


func _on_play_pressed() -> void:
	if _stop_cooldown_active:
		return
	Playback.toggle()


func _on_loop_picker_selected(i: int) -> void:
	if loop_picker == null:
		return
	var id := loop_picker.get_item_id(i)
	ProjectData.open_loop(id)


func _on_backend_selected(i: int) -> void:
	Playback.set_backend(backend_option.get_item_id(i))
	_refresh_edit_lock()


func _refresh_edit_lock() -> void:
	var locked := _is_interaction_locked()
	if _ui_root != null:
		_set_controls_locked(_ui_root, locked)
		_ui_root.modulate = Color(1, 1, 1, 0.65) if locked else Color(1, 1, 1, 1)
	if play_btn != null:
		# Keep this as the only clickable control in lock mode.
		play_btn.disabled = _stop_cooldown_active
		if locked:
			play_btn.disabled = false
	if _main_split != null:
		_main_split.modulate = Color(1, 1, 1, 0.65) if locked else Color(1, 1, 1, 1)
	if _edit_lock_blocker != null:
		_edit_lock_blocker.visible = locked
		_edit_lock_blocker.move_to_front()
	if backend_option != null:
		backend_option.disabled = locked
	if locked:
		status_label.text = "Real backend running: editor input is locked."


func _is_interaction_locked() -> bool:
	return Playback.is_running and Playback.backend != null and Playback.backend.is_real()


func _set_controls_locked(node: Node, locked: bool) -> void:
	if node == _edit_lock_blocker:
		return
	if node is LineEdit:
		(node as LineEdit).editable = not locked
	elif node is TextEdit:
		(node as TextEdit).editable = not locked
	elif node is SpinBox:
		(node as SpinBox).editable = not locked
	elif node.has_method("set_disabled"):
		node.call("set_disabled", locked)

	for child in node.get_children():
		_set_controls_locked(child, locked)


func _switch_to_safe_backend_if_needed() -> void:
	if Playback.backend == null or not Playback.backend.is_real():
		return
	Playback.set_backend(Playback.BackendKind.PREVIEW)
	if backend_option != null:
		for i in backend_option.item_count:
			if backend_option.get_item_id(i) == Playback.BackendKind.PREVIEW:
				backend_option.select(i)
				break


func _animate_safety_cooldown() -> void:
	await _animate_stop_feedback(true)


func _animate_stop_feedback(include_safety: bool) -> void:
	_stop_cooldown_token += 1
	var token := _stop_cooldown_token
	_stop_cooldown_active = true
	_refresh_edit_lock()
	if play_btn != null:
		play_btn.text = "Stopping."
	await get_tree().create_timer(STOP_COOLDOWN_STEP_SEC).timeout
	if token != _stop_cooldown_token:
		return
	if play_btn != null:
		play_btn.text = "Stopping.."
	await get_tree().create_timer(STOP_COOLDOWN_STEP_SEC).timeout
	if token != _stop_cooldown_token:
		return
	if play_btn != null:
		play_btn.text = "Stopping..."
	await get_tree().create_timer(STOP_COOLDOWN_STEP_SEC).timeout
	if token != _stop_cooldown_token:
		return
	if include_safety:
		if play_btn != null:
			play_btn.text = "Safety."
		if status_label != null:
			status_label.text = "Switched to Preview (safe)."
		await get_tree().create_timer(STOP_COOLDOWN_STEP_SEC).timeout
		if token != _stop_cooldown_token:
			return
		if play_btn != null:
			play_btn.text = "Safety.."
		await get_tree().create_timer(STOP_COOLDOWN_STEP_SEC).timeout
		if token != _stop_cooldown_token:
			return
		if play_btn != null:
			play_btn.text = "Safety..."
		await get_tree().create_timer(STOP_COOLDOWN_STEP_SEC).timeout
		if token != _stop_cooldown_token:
			return
	_stop_cooldown_active = false
	if play_btn != null:
		play_btn.text = "▶ Run!"
	_refresh_edit_lock()


# ======================================================================
#  File menu actions
# ======================================================================
func _on_new() -> void:
	var id := ProjectData.create_loop(true)
	status_label.text = "Opened new loop %d." % id


func _on_save() -> void:
	var err := ProjectData.save_active_loop()
	status_label.text = "Committed." if err == OK else "Commit failed (%d)." % err
	_refresh_loop_stack_ui()


func _on_export() -> void:
	var dlg := FileDialog.new()
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	dlg.title = "Export loop"
	dlg.add_filter("*.loop", "Loop files")
	var suggested := ProjectData.active_loop_display_name().strip_edges()
	if suggested.is_empty() or suggested == "-":
		suggested = "loop"
	dlg.current_file = "%s.loop" % suggested
	dlg.size = Vector2i(720, 520)
	dlg.file_selected.connect(func(path: String):
		if not path.to_lower().ends_with(".loop"):
			path += ".loop"
		var err := ProjectData.save_to(path)
		status_label.text = "Exported to %s" % path if err == OK else "Export failed (%d)." % err
		_refresh_loop_stack_ui()
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered()


func _on_load() -> void:
	ProjectData.step_loop(1)


func _rename_layer_dialog(index: int) -> void:
	if index < 0 or index >= ProjectData.project.layers.size():
		return
	var dlg := AcceptDialog.new()
	dlg.title = "Rename layer"
	var le := LineEdit.new()
	le.text = ProjectData.project.layers[index].name
	le.custom_minimum_size = Vector2(260, 0)
	dlg.add_child(le)
	dlg.register_text_enter(le)
	dlg.confirmed.connect(func():
		ProjectData.rename_layer(index, le.text)
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered()
	le.grab_focus()
	le.select_all()


# ======================================================================
#  Hotkeys
# ======================================================================
## Returns true when the user is typing, so navigation keys don't hijack input.
func _is_editing_text() -> bool:
	var f := get_viewport().gui_get_focus_owner()
	return f is LineEdit or f is TextEdit or f is SpinBox


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return

	# While picking on screen the pick window is unfocusable, so its Esc arrives
	# here. No other hotkey should fire mid-pick.
	if _pick_active:
		if event.keycode == KEY_ESCAPE:
			picker.cancel_pick()
			get_viewport().set_input_as_handled()
		return

	if _stop_cooldown_active and not Playback.is_running:
		return

	# Global controls that should always work.
	match event.keycode:
		KEY_F5:
			Playback.toggle()
			get_viewport().set_input_as_handled()
			return
		KEY_F8:
			Playback.stop()
			get_viewport().set_input_as_handled()
			return
		KEY_ESCAPE:
			if Playback.is_running:
				Playback.stop()
				get_viewport().set_input_as_handled()
			return

	# In locked mode, only allow the global controls above.
	if _is_interaction_locked():
		return

	# Layer-flipping shortcuts are suppressed while typing in a field.
	if _is_editing_text():
		return

	match event.keycode:
		KEY_LEFT, KEY_PAGEUP, KEY_BRACKETLEFT:
			_go_overlay_layer(-1)
			get_viewport().set_input_as_handled()
		KEY_RIGHT, KEY_PAGEDOWN, KEY_BRACKETRIGHT:
			_go_overlay_layer(1)
			get_viewport().set_input_as_handled()
		KEY_BACKSLASH:
			ProjectData.set_overlay_show_all(not ProjectData.overlay_show_all)
			get_viewport().set_input_as_handled()
		_:
			if event.keycode >= KEY_1 and event.keycode <= KEY_9:
				_go_to_layer(event.keycode - KEY_1)
				get_viewport().set_input_as_handled()


# ======================================================================
#  Small UI factory helpers
# ======================================================================
func _tool_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b


func _grab_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b


func _row(label: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(120, 0)
	row.add_child(l)
	return row


func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 16)
	l.modulate = Color(0.7, 0.85, 1.0)
	return l


func _vsep() -> Control:
	var s := VSeparator.new()
	return s


func _shorten_text(text: String, max_chars: int) -> String:
	if max_chars <= 3 or text.length() <= max_chars:
		return text
	return text.substr(0, max_chars - 3) + "..."
