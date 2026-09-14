extends Window
class_name KeyCapture
## An on-screen keyboard that captures keystrokes for a Key action and turns
## them into Windows SendKeys text: type on the real keyboard while this
## window has the focus, or click the keys. Letters, digits and punctuation
## become themselves (SendKeys' own special characters escaped in braces),
## named keys become their {CODE}, and Ctrl / Alt / Shift become the ^ % +
## prefixes. The on-screen modifiers are sticky: press one, then the key it
## applies to. The Windows key cannot be sent by SendKeys and is ignored.
##
## Opened for one LineEdit at a time (see open); every change is reported
## through `text_changed` with the complete new text.

signal text_changed(text: String)

## SendKeys reserves these; each is sent literally as {c}.
const ESCAPED := "+^%~(){}[]"

## Godot keycode -> SendKeys code for keys that are not printable characters.
const NAMED := {
	KEY_ENTER: "{ENTER}", KEY_KP_ENTER: "{ENTER}", KEY_TAB: "{TAB}", KEY_ESCAPE: "{ESC}",
	KEY_BACKSPACE: "{BACKSPACE}", KEY_DELETE: "{DELETE}", KEY_INSERT: "{INSERT}",
	KEY_HOME: "{HOME}", KEY_END: "{END}", KEY_PAGEUP: "{PGUP}", KEY_PAGEDOWN: "{PGDN}",
	KEY_UP: "{UP}", KEY_DOWN: "{DOWN}", KEY_LEFT: "{LEFT}", KEY_RIGHT: "{RIGHT}",
	KEY_F1: "{F1}", KEY_F2: "{F2}", KEY_F3: "{F3}", KEY_F4: "{F4}", KEY_F5: "{F5}", KEY_F6: "{F6}",
	KEY_F7: "{F7}", KEY_F8: "{F8}", KEY_F9: "{F9}", KEY_F10: "{F10}", KEY_F11: "{F11}", KEY_F12: "{F12}",
	KEY_F13: "{F13}", KEY_F14: "{F14}", KEY_F15: "{F15}", KEY_F16: "{F16}",
	KEY_CAPSLOCK: "{CAPSLOCK}", KEY_NUMLOCK: "{NUMLOCK}", KEY_SCROLLLOCK: "{SCROLLLOCK}",
	KEY_PRINT: "{PRTSC}", KEY_PAUSE: "{BREAK}", KEY_HELP: "{HELP}",
	KEY_KP_ADD: "{ADD}", KEY_KP_SUBTRACT: "{SUBTRACT}", KEY_KP_MULTIPLY: "{MULTIPLY}", KEY_KP_DIVIDE: "{DIVIDE}",
	KEY_SPACE: " ",
}

## The on-screen layout: rows of [label, keycode] (the keycode gives the
## SendKeys text via token_for and lets a typed key light its button up).
## "" is a spacer. The modifier keys are handled by name.
const MAIN_ROWS := [
	[["Esc", KEY_ESCAPE], [""], ["F1", KEY_F1], ["F2", KEY_F2], ["F3", KEY_F3], ["F4", KEY_F4], ["F5", KEY_F5], ["F6", KEY_F6], ["F7", KEY_F7], ["F8", KEY_F8], ["F9", KEY_F9], ["F10", KEY_F10], ["F11", KEY_F11], ["F12", KEY_F12]],
	[["`", KEY_QUOTELEFT], ["1", KEY_1], ["2", KEY_2], ["3", KEY_3], ["4", KEY_4], ["5", KEY_5], ["6", KEY_6], ["7", KEY_7], ["8", KEY_8], ["9", KEY_9], ["0", KEY_0], ["-", KEY_MINUS], ["=", KEY_EQUAL], ["⌫", KEY_BACKSPACE]],
	[["Tab", KEY_TAB], ["q", KEY_Q], ["w", KEY_W], ["e", KEY_E], ["r", KEY_R], ["t", KEY_T], ["y", KEY_Y], ["u", KEY_U], ["i", KEY_I], ["o", KEY_O], ["p", KEY_P], ["[", KEY_BRACKETLEFT], ["]", KEY_BRACKETRIGHT], ["\\", KEY_BACKSLASH]],
	[["Caps", KEY_CAPSLOCK], ["a", KEY_A], ["s", KEY_S], ["d", KEY_D], ["f", KEY_F], ["g", KEY_G], ["h", KEY_H], ["j", KEY_J], ["k", KEY_K], ["l", KEY_L], [";", KEY_SEMICOLON], ["'", KEY_APOSTROPHE], ["Enter", KEY_ENTER]],
	[["Shift", KEY_SHIFT], ["z", KEY_Z], ["x", KEY_X], ["c", KEY_C], ["v", KEY_V], ["b", KEY_B], ["n", KEY_N], ["m", KEY_M], [",", KEY_COMMA], [".", KEY_PERIOD], ["/", KEY_SLASH], ["Shift", KEY_SHIFT]],
	[["Ctrl", KEY_CTRL], ["Alt", KEY_ALT], ["Space", KEY_SPACE], ["Alt", KEY_ALT], ["Ctrl", KEY_CTRL]],
]
const NAV_ROWS := [
	[["Ins", KEY_INSERT], ["Home", KEY_HOME], ["PgUp", KEY_PAGEUP]],
	[["Del", KEY_DELETE], ["End", KEY_END], ["PgDn", KEY_PAGEDOWN]],
	[[""], ["↑", KEY_UP], [""]],
	[["←", KEY_LEFT], ["↓", KEY_DOWN], ["→", KEY_RIGHT]],
]
## Widths in key units for the wide keys (default 1).
const WIDE := {"⌫": 2.0, "Tab": 1.5, "\\": 1.5, "Caps": 1.75, "Enter": 2.25, "Shift": 2.5, "Ctrl": 1.5, "Alt": 1.5, "Space": 6.0, "Esc": 1.0}
const UNIT := 38.0

## A small keyboard glyph for the button that opens this window (rendered
## from SVG at runtime, so the project needs no imported image).
const ICON_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="20" height="14" viewBox="0 0 20 14">
<rect x="0.75" y="0.75" width="18.5" height="12.5" rx="2" fill="none" stroke="#e6e6e6" stroke-width="1.5"/>
<g fill="#e6e6e6"><rect x="3" y="3" width="2" height="2"/><rect x="6.5" y="3" width="2" height="2"/><rect x="10" y="3" width="2" height="2"/><rect x="13.5" y="3" width="2" height="2"/>
<rect x="3" y="6" width="2" height="2"/><rect x="6.5" y="6" width="2" height="2"/><rect x="10" y="6" width="2" height="2"/><rect x="13.5" y="6" width="2" height="2"/>
<rect x="5" y="9" width="10" height="2" rx="0.5"/></g></svg>"""

static var _icon: Texture2D


## The keyboard icon for the button that opens the capture window.
static func icon() -> Texture2D:
	if _icon == null:
		var img := Image.new()
		if img.load_svg_from_string(ICON_SVG, 1.0) == OK:
			_icon = ImageTexture.create_from_image(img)
	return _icon


## The SendKeys text for one key press. `shift` / `ctrl` / `alt` add the
## + ^ % prefixes; `unicode` (the typed character, if any) wins over the
## keycode for printable keys so the keyboard layout is respected.
static func token_for(keycode: int, unicode: int, shift: bool, ctrl: bool, alt: bool) -> String:
	var base := ""
	var prefix := ""
	if keycode in NAMED:
		base = NAMED[keycode]
		if shift:
			prefix += "+"
	elif not ctrl and not alt and unicode >= 32 and unicode != 127:
		# A typed character: shift is already folded into it.
		base = _escape(char(unicode))
	elif keycode >= 32 and keycode < 127:
		# A key held with Ctrl / Alt (or clicked with a sticky modifier): the
		# unshifted character of that key, lower case.
		base = _escape(char(keycode).to_lower())
		if shift:
			prefix += "+"
	elif keycode >= KEY_KP_0 and keycode <= KEY_KP_9:
		base = str(keycode - KEY_KP_0)
		if shift:
			prefix += "+"
	elif keycode == KEY_KP_PERIOD:
		base = "."
	else:
		return ""  # a modifier on its own, the Windows key, or unknown
	if ctrl:
		prefix += "^"
	if alt:
		prefix += "%"
	return prefix + base


static func _escape(c: String) -> String:
	return "{" + c + "}" if c in ESCAPED else c


var _base := ""              # the field's text when opened
var _tokens: Array[String] = []  # what was captured since, in order
var _sticky_shift := false
var _sticky_ctrl := false
var _sticky_alt := false
var _preview: LineEdit
var _shift_buttons: Array[Button] = []
var _ctrl_buttons: Array[Button] = []
var _alt_buttons: Array[Button] = []
var _key_buttons: Dictionary = {}  # keycode -> Array[Button]


func _init() -> void:
	title = "Capture keys"
	transient = true
	exclusive = false
	unresizable = true
	wrap_controls = false
	min_size = Vector2i(820, 384)
	size = min_size
	visible = false
	close_requested.connect(hide)
	_build()


## Shows the keyboard for a field whose current text is `current`; every
## change is reported through text_changed with the complete text.
func open(current: String) -> void:
	_base = current
	_tokens.clear()
	_set_sticky(false, false, false)
	_refresh_preview()
	popup_centered()
	grab_focus()


func _input(event: InputEvent) -> void:
	# Physical keys while this window has the focus.
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	get_viewport().set_input_as_handled()
	if key.keycode in [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]:
		return
	var token := token_for(key.keycode, key.unicode, key.shift_pressed or _sticky_shift, key.ctrl_pressed or _sticky_ctrl, key.alt_pressed or _sticky_alt)
	if token.is_empty():
		return
	_flash(key.keycode)
	_append(token)


func _append(token: String) -> void:
	_tokens.append(token)
	_set_sticky(false, false, false)
	_refresh_preview()
	text_changed.emit(_text())


func _text() -> String:
	return _base + "".join(_tokens)


func _refresh_preview() -> void:
	_preview.text = _text()
	_preview.caret_column = _preview.text.length()


# ------------------------------------------------------------------ layout
func _build() -> void:
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 6)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 10)
	add_child(margin)
	margin.add_child(root)

	var hint := Label.new()
	hint.text = "Type on your keyboard or click the keys below; the SendKeys text goes straight into the Keys field. On-screen Shift / Ctrl / Alt stay pressed for the next key. The Windows key cannot be sent."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(1, 1, 1, 0.75)
	root.add_child(hint)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	_preview = LineEdit.new()
	_preview.editable = false
	_preview.focus_mode = Control.FOCUS_NONE
	_preview.placeholder_text = "(nothing captured yet)"
	_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_preview)
	top.add_child(_action_button("⌫ Undo", "Remove the last captured key", func():
		if _tokens.is_empty():
			return
		_tokens.pop_back()
		_refresh_preview()
		text_changed.emit(_text())))
	top.add_child(_action_button("Clear", "Empty the Keys field", func():
		_base = ""
		_tokens.clear()
		_refresh_preview()
		text_changed.emit(_text())))
	top.add_child(_action_button("Done", "Close this window (the field is already up to date)", hide))
	root.add_child(top)

	var keys := HBoxContainer.new()
	keys.add_theme_constant_override("separation", 14)
	keys.add_child(_block(MAIN_ROWS))
	keys.add_child(_block(NAV_ROWS))
	root.add_child(keys)


func _action_button(text: String, tip: String, on_pressed: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(on_pressed)
	return b


func _block(rows: Array) -> Control:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 4)
	for row in rows:
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", 4)
		for key in row:
			var label: String = key[0]
			if label.is_empty():
				var gap := Control.new()
				gap.custom_minimum_size = Vector2(UNIT, UNIT)
				hb.add_child(gap)
				continue
			hb.add_child(_key_button(label, key[1]))
		vb.add_child(hb)
	return vb


func _key_button(label: String, keycode: int) -> Button:
	var b := Button.new()
	b.text = label
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(UNIT * float(WIDE.get(label, 1.0)), UNIT)
	match keycode:
		KEY_SHIFT:
			b.toggle_mode = true
			b.tooltip_text = "Shift (+) for the next key"
			b.toggled.connect(func(on: bool): _set_sticky(on, _sticky_ctrl, _sticky_alt))
			_shift_buttons.append(b)
		KEY_CTRL:
			b.toggle_mode = true
			b.tooltip_text = "Ctrl (^) for the next key"
			b.toggled.connect(func(on: bool): _set_sticky(_sticky_shift, on, _sticky_alt))
			_ctrl_buttons.append(b)
		KEY_ALT:
			b.toggle_mode = true
			b.tooltip_text = "Alt (%) for the next key"
			b.toggled.connect(func(on: bool): _set_sticky(_sticky_shift, _sticky_ctrl, on))
			_alt_buttons.append(b)
		_:
			var plain := token_for(keycode, 0, false, false, false)
			b.tooltip_text = "(space)" if plain == " " else plain
			b.pressed.connect(func():
				var token := token_for(keycode, 0, _sticky_shift, _sticky_ctrl, _sticky_alt)
				if not token.is_empty():
					_append(token))
			if not _key_buttons.has(keycode):
				_key_buttons[keycode] = []
			_key_buttons[keycode].append(b)
	return b


## Sets the sticky modifiers and shows the state on their buttons (both
## Shift keys, both Ctrl keys, both Alt keys move together).
func _set_sticky(shift: bool, ctrl: bool, alt: bool) -> void:
	_sticky_shift = shift
	_sticky_ctrl = ctrl
	_sticky_alt = alt
	for b in _shift_buttons:
		b.set_pressed_no_signal(shift)
	for b in _ctrl_buttons:
		b.set_pressed_no_signal(ctrl)
	for b in _alt_buttons:
		b.set_pressed_no_signal(alt)


## Lights the on-screen key(s) for a typed keycode up for a moment.
func _flash(keycode: int) -> void:
	for b in _key_buttons.get(keycode, []):
		var tween := create_tween()
		b.modulate = Color(0.55, 0.9, 1.0)
		tween.tween_property(b, "modulate", Color.WHITE, 0.25)
