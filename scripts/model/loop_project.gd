extends RefCounted
class_name LoopProject
## The whole automation: an ordered set of layers that loop forever.

## Self-reference via preload. When this script is compiled very early (as part
## of an autoload's dependency chain) the global `class_name` registry may not
## be ready, so referring to "LoopProject" by name inside our own static
## functions would fail. A self-preload const always resolves.
const Self := preload("res://scripts/model/loop_project.gd")
const LoopLayerT := preload("res://scripts/model/loop_layer.gd")

const FILE_VERSION := 1

var name: String = "Untitled Loop"
## Pause inserted between full loop iterations: a random value from
## loop_delay_ms .. loop_delay_ms_max each time (equal ends = fixed).
var loop_delay_ms: int = 250
var loop_delay_ms_max: int = 250
var layers: Array[LoopLayerT] = []


static func make_default() -> Self:
	var p := Self.new()
	p.layers.append(LoopLayerT.make("Layer 1", 0))
	return p


func to_dict() -> Dictionary:
	var arr: Array = []
	for l in layers:
		arr.append(l.to_dict())
	return {
		"version": FILE_VERSION,
		"name": name,
		"loop_delay_ms": loop_delay_ms,
		"loop_delay_ms_max": loop_delay_ms_max,
		"layers": arr,
	}


static func from_dict(d: Dictionary) -> Self:
	var p := Self.new()
	p.name = String(d.get("name", "Untitled Loop"))
	p.loop_delay_ms = int(d.get("loop_delay_ms", 250))
	p.loop_delay_ms_max = int(d.get("loop_delay_ms_max", p.loop_delay_ms))
	p.layers = []
	# Skip (never crash on) entries that are not layer objects.
	var layers: Variant = d.get("layers", [])
	if typeof(layers) == TYPE_ARRAY:
		for ld in layers:
			if typeof(ld) == TYPE_DICTIONARY:
				p.layers.append(LoopLayerT.from_dict(ld))
	if p.layers.is_empty():
		p.layers.append(LoopLayerT.make("Layer 1", 0))
	return p


func to_json() -> String:
	return JSON.stringify(to_dict(), "\t")


static func from_json(text: String) -> Self:
	var data: Variant = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return Self.make_default()
	return Self.from_dict(data)


## The pause to insert after this iteration: random within the range.
func roll_loop_delay_ms() -> int:
	return maxi(0, randi_range(mini(loop_delay_ms, loop_delay_ms_max), maxi(loop_delay_ms, loop_delay_ms_max)))
