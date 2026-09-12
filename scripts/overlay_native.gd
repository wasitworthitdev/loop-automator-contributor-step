extends RefCounted
class_name OverlayNative
## Best-effort native window tweaks that Godot's DisplayServer does not expose.
##
## Window.FLAG_MOUSE_PASSTHROUGH only lets mouse events through to other
## windows of the *same application* (on Windows it answers WM_NCHITTEST with
## HTTRANSPARENT). A desktop overlay must let clicks reach *other* programs,
## which on Windows needs the WS_EX_LAYERED | WS_EX_TRANSPARENT extended window
## styles. Like WindowsBackend, this goes through a tiny generated PowerShell
## helper so the project stays pure GDScript with no build step.

const HELPER_PATH := "user://overlay_helper.ps1"

const HELPER_SCRIPT := """param([Parameter(Mandatory=$true)][long]$Hwnd)
Add-Type @\"
using System;
using System.Runtime.InteropServices;
public class Win32Overlay {
  [DllImport(\"user32.dll\")] public static extern bool IsWindow(IntPtr hWnd);
  [DllImport(\"user32.dll\", SetLastError=true)] public static extern int GetWindowLongW(IntPtr hWnd, int nIndex);
  [DllImport(\"user32.dll\", SetLastError=true)] public static extern int SetWindowLongW(IntPtr hWnd, int nIndex, int dwNewLong);
  [DllImport(\"user32.dll\")] public static extern bool SetLayeredWindowAttributes(IntPtr hWnd, uint crKey, byte bAlpha, uint dwFlags);
  [DllImport(\"user32.dll\")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
}
\"@
$h = [IntPtr]$Hwnd
if (-not [Win32Overlay]::IsWindow($h)) { exit 2 }
$GWL_EXSTYLE = -20
$WS_EX_TRANSPARENT = 0x00000020   # hit-testing skips the window...
$WS_EX_LAYERED = 0x00080000       # ...but only when it is also layered
$WS_EX_TOOLWINDOW = 0x00000080    # keep the overlay out of the taskbar / Alt-Tab
$ex = [Win32Overlay]::GetWindowLongW($h, $GWL_EXSTYLE)
$ex = $ex -bor $WS_EX_LAYERED -bor $WS_EX_TRANSPARENT -bor $WS_EX_TOOLWINDOW
[Win32Overlay]::SetWindowLongW($h, $GWL_EXSTYLE, $ex) | Out-Null
# A layered window is only composited once its attributes are set; alpha 255
# leaves Godot's per-pixel transparency untouched.
[Win32Overlay]::SetLayeredWindowAttributes($h, 0, 255, 0x2) | Out-Null
# SWP_NOSIZE | SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED
[Win32Overlay]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 0, 0, 0x37) | Out-Null
$now = [Win32Overlay]::GetWindowLongW($h, $GWL_EXSTYLE)
if ((($now -band $WS_EX_LAYERED) -ne 0) -and (($now -band $WS_EX_TRANSPARENT) -ne 0)) { exit 0 }
exit 1
"""

static var _helper_real_path: String = ""


## True when this OS needs (and has) the native helper for real click-through.
static func is_supported() -> bool:
	return OS.get_name() == "Windows"


## Starts making the OS window behind `window` click-through for every other
## program. Runs asynchronously; poll OS.is_process_running() with the returned
## pid and read OS.get_process_exit_code() (0 = applied). Returns -1 if the
## helper could not be started.
static func begin_click_through(window: Window) -> int:
	if not is_supported() or window == null:
		return -1
	var window_id := window.get_window_id()
	if window_id == DisplayServer.INVALID_WINDOW_ID:
		return -1
	var hwnd := DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, window_id)
	if hwnd == 0:
		return -1
	var helper := _ensure_helper()
	if helper.is_empty():
		return -1
	var args := PackedStringArray([
		"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
		"-File", helper, "-Hwnd", str(hwnd),
	])
	return OS.create_process("powershell.exe", args, false)


static func _ensure_helper() -> String:
	if not _helper_real_path.is_empty():
		return _helper_real_path
	var f := FileAccess.open(HELPER_PATH, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(HELPER_SCRIPT)
	f.close()
	_helper_real_path = ProjectSettings.globalize_path(HELPER_PATH)
	return _helper_real_path
