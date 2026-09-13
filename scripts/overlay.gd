extends Window
## Transparent, always-on-top, click-through overlay window. It covers the whole
## virtual desktop and draws the loop's visuals (handled by OverlayCanvas) over
## every other program while leaving them fully usable underneath.
##
## Requirements that are easy to get wrong:
##  * Per-pixel transparency needs a renderer that supports it; on Windows the
##    Forward+/Mobile (Vulkan) renderers usually don't, so the project uses the
##    Compatibility renderer (see project.godot). Without it this window is an
##    opaque black rectangle.
##  * Window.FLAG_MOUSE_PASSTHROUGH only passes clicks to windows of the same
##    application, so on Windows real click-through is applied natively after
##    the window is shown (see OverlayNative).

## Preload the canvas script directly so this resolves even when overlay.tscn is
## preloaded early (by main.gd), before the global `class_name` registry exists.
const OverlayCanvasT := preload("res://scripts/overlay_canvas.gd")
const OverlayNativeT := preload("res://scripts/overlay_native.gd")

## How mouse input under the overlay is currently handled.
enum ClickThrough {
	OFF,        ## Overlay is hidden.
	PENDING,    ## Native helper is still applying the click-through styles.
	NATIVE,     ## Clicks reach other programs (native styles applied).
	FLAG_ONLY,  ## Only Godot's flag is available (non-Windows OS).
	FAILED,     ## Native helper failed: the overlay blocks mouse input under it.
}

signal click_through_changed(state: int)

var canvas: OverlayCanvasT
var click_through: int = ClickThrough.OFF

var _helper_pid: int = -1
## Long-running native watchdog logging changes to the shown window's topmost /
## click-through styles (see OverlayNative.WATCHDOG_SCRIPT); -1 when none runs.
var _watchdog_pid: int = -1


func _ready() -> void:
	# Native-window flags for a true screen overlay. They are applied when the
	# OS window is created (on show), so set them all up front and never again
	# while shown: re-applying a flag rewrites the OS window styles and would
	# undo the native click-through.
	set_flag(Window.FLAG_BORDERLESS, true)
	set_flag(Window.FLAG_ALWAYS_ON_TOP, true)
	set_flag(Window.FLAG_TRANSPARENT, true)
	set_flag(Window.FLAG_NO_FOCUS, true)
	set_flag(Window.FLAG_MOUSE_PASSTHROUGH, true)
	transparent_bg = true
	# Honour `position` when the OS window is created (multi-monitor desktops
	# don't start at the primary screen's centre).
	initial_position = Window.WINDOW_INITIAL_POSITION_ABSOLUTE

	canvas = OverlayCanvasT.new()
	add_child(canvas)
	_fit_to_screen()
	set_process(false)


func _fit_to_screen() -> void:
	# Cover the entire virtual desktop (all displays), so guides use true global
	# screen-space regardless of which monitor the target app is on.
	var desktop := virtual_desktop_rect()
	position = desktop.position
	size = desktop.size
	# The canvas is anchored top-left; size it explicitly to cover the screen.
	if canvas != null:
		canvas.position = Vector2.ZERO
		canvas.size = Vector2(desktop.size)
		canvas.queue_redraw()


## Bounding rect of every connected display, in Godot screen coordinates.
static func virtual_desktop_rect() -> Rect2i:
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


## True when the OS/renderer can actually composite this window with per-pixel
## alpha. When false the overlay shows up as an opaque black rectangle.
func transparency_available() -> bool:
	return DisplayServer.is_window_transparency_available()


func show_overlay() -> void:
	_fit_to_screen()
	show()
	if not transparency_available():
		push_warning("Overlay: per-pixel window transparency is unavailable with the '%s' renderer; the overlay will be opaque. Use the Compatibility renderer." % RenderingServer.get_current_rendering_method())
	_begin_native_click_through()
	if canvas != null:
		canvas.queue_redraw()
	# Some drivers leave the first frame of a freshly-shown transparent window
	# blank; nudge a redraw a couple of frames later so content composites.
	_nudge_redraw()


func hide_overlay() -> void:
	hide()
	# hide() destroys the OS window, so any in-flight helper is now moot.
	_helper_pid = -1
	_stop_watchdog()
	set_process(false)
	_set_click_through(ClickThrough.OFF)


func _begin_native_click_through() -> void:
	if not OverlayNativeT.is_supported():
		_set_click_through(ClickThrough.FLAG_ONLY)
		return
	_helper_pid = OverlayNativeT.begin_click_through(self)
	if _helper_pid < 0:
		_set_click_through(ClickThrough.FAILED)
		return
	_set_click_through(ClickThrough.PENDING)
	set_process(true)


func _process(_dt: float) -> void:
	# Wait for the native helper to finish and report its outcome.
	if _helper_pid < 0:
		set_process(false)
		return
	if OS.is_process_running(_helper_pid):
		return
	var code := OS.get_process_exit_code(_helper_pid)
	_helper_pid = -1
	set_process(false)
	_set_click_through(ClickThrough.NATIVE if code == 0 else ClickThrough.FAILED)
	if code == 0 and visible:
		# Styles applied; from here on watch them and log any change.
		_watchdog_pid = OverlayNativeT.begin_watchdog(self)


func _set_click_through(state: int) -> void:
	click_through = state
	if canvas != null:
		match state:
			ClickThrough.PENDING:
				canvas.hud_note = "enabling click-through…"
			ClickThrough.NATIVE:
				canvas.hud_note = "click-through"
			ClickThrough.FAILED:
				canvas.hud_note = "NOT click-through (helper failed)"
			_:
				canvas.hud_note = ""
		canvas.queue_redraw()
	click_through_changed.emit(state)


func _nudge_redraw() -> void:
	for i in 3:
		await get_tree().process_frame
		if canvas != null:
			canvas.queue_redraw()


func _stop_watchdog() -> void:
	if _watchdog_pid >= 0:
		if OS.is_process_running(_watchdog_pid):
			OS.kill(_watchdog_pid)
		_watchdog_pid = -1


func _exit_tree() -> void:
	# The watchdog exits on its own once the window is gone, but don't leave it
	# polling behind a crashed or closing app.
	_stop_watchdog()
