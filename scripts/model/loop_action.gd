extends RefCounted
class_name LoopAction
## A single automated step inside a layer.
## Stored in a flexible way so it serialises cleanly to/from JSON.

## Self-reference via preload so our own static factories resolve even when this
## script is compiled very early (e.g. as part of an autoload dependency chain),
## before the global `class_name` registry is ready.
const Self := preload("res://scripts/model/loop_action.gd")

enum Type {
	MOVE,          ## Move the cursor to (x, y)
	CLICK,         ## Move to (x, y) then click a mouse button
	DRAG,          ## Press at (x, y), move to (x2, y2), release
	KEY,           ## Send keys (SendKeys format on Windows backend)
	WAIT,          ## Pause for wait_ms milliseconds
	PIXEL_DETECT,  ## Look for an expected colour anywhere in a screen rect
}

## Mouse button identifiers used across backends.
const BUTTON_LEFT := 0
const BUTTON_RIGHT := 1
const BUTTON_MIDDLE := 2

## How PIXEL_DETECT influences the rest of the layer when the colour is NOT found.
enum OnFail {
	CONTINUE,     ## Do nothing special, keep running
	SKIP_LAYER,   ## Skip the remaining actions in this layer this iteration
	STOP_LOOP,    ## Stop playback entirely
}

var type: int = Type.MOVE
var enabled: bool = true
var comment: String = ""

# Geometry / parameters (only the relevant ones are used per type).
var x: int = 0
var y: int = 0
var x2: int = 0
var y2: int = 0
var w: int = 100
var h: int = 60
var button: int = BUTTON_LEFT
var keys: String = ""
var wait_ms: int = 100
var duration_ms: int = 0
var color: Color = Color(1, 1, 1, 1)
var tolerance: int = 16
var on_fail: int = OnFail.CONTINUE


static func type_name(t: int) -> String:
	match t:
		Type.MOVE: return "Move"
		Type.CLICK: return "Click"
		Type.DRAG: return "Drag"
		Type.KEY: return "Key"
		Type.WAIT: return "Wait"
		Type.PIXEL_DETECT: return "Pixel Detect"
	return "Action"


static func button_name(b: int) -> String:
	match b:
		BUTTON_RIGHT: return "Right"
		BUTTON_MIDDLE: return "Middle"
		_: return "Left"


static func new_of_type(t: int) -> Self:
	var a := Self.new()
	a.type = t
	match t:
		Type.MOVE:
			a.duration_ms = 0
		Type.CLICK:
			a.button = BUTTON_LEFT
		Type.DRAG:
			a.x2 = 200
			a.y2 = 200
			a.duration_ms = 200
		Type.KEY:
			a.keys = ""
		Type.WAIT:
			a.wait_ms = 250
		Type.PIXEL_DETECT:
			a.color = Color(1, 0, 0, 1)
			a.tolerance = 16
			a.on_fail = OnFail.SKIP_LAYER
	return a


## Short, human readable line for the action list.
func describe() -> String:
	match type:
		Type.MOVE:
			return "Move → (%d, %d)" % [x, y]
		Type.CLICK:
			return "%s click @ (%d, %d)" % [button_name(button), x, y]
		Type.DRAG:
			return "%s drag (%d, %d) → (%d, %d)" % [button_name(button), x, y, x2, y2]
		Type.KEY:
			return "Key: \"%s\"" % keys
		Type.WAIT:
			return "Wait %d ms" % wait_ms
		Type.PIXEL_DETECT:
			return "Detect %s in [%d, %d, %d×%d]" % [color.to_html(false), x, y, w, h]
	return "Action"


## Primary anchor point used for overlay path drawing (or -1,-1 if none).
func overlay_point() -> Vector2:
	match type:
		Type.MOVE, Type.CLICK, Type.DRAG:
			return Vector2(x, y)
		Type.PIXEL_DETECT:
			# The top-left corner: the inside of the rect is kept clear on the
			# overlay (the screen read scans it), so anchor paths and badges
			# outside it.
			return Vector2(x, y)
	return Vector2(-1, -1)


func to_dict() -> Dictionary:
	return {
		"type": type,
		"enabled": enabled,
		"comment": comment,
		"x": x, "y": y, "x2": x2, "y2": y2, "w": w, "h": h,
		"button": button,
		"keys": keys,
		"wait_ms": wait_ms,
		"duration_ms": duration_ms,
		"color": color.to_html(true),
		"tolerance": tolerance,
		"on_fail": on_fail,
	}


static func from_dict(d: Dictionary) -> Self:
	var a := Self.new()
	a.type = int(d.get("type", Type.MOVE))
	a.enabled = bool(d.get("enabled", true))
	a.comment = String(d.get("comment", ""))
	a.x = int(d.get("x", 0))
	a.y = int(d.get("y", 0))
	a.x2 = int(d.get("x2", 0))
	a.y2 = int(d.get("y2", 0))
	a.w = int(d.get("w", 100))
	a.h = int(d.get("h", 60))
	a.button = int(d.get("button", BUTTON_LEFT))
	a.keys = String(d.get("keys", ""))
	a.wait_ms = int(d.get("wait_ms", 100))
	a.duration_ms = int(d.get("duration_ms", 0))
	a.color = Color.html(String(d.get("color", "ffffffff")))
	a.tolerance = int(d.get("tolerance", 16))
	a.on_fail = int(d.get("on_fail", OnFail.CONTINUE))
	return a


func duplicate_action() -> Self:
	return Self.from_dict(to_dict())
