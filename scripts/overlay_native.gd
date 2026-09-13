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

const WATCHDOG_PATH := "user://overlay_watchdog.ps1"

## Long-running companion for a shown overlay window: once a second it checks
## that the window is still topmost, layered and hit-test transparent, and
## appends any change (with the foreground window and the window directly above
## us at the time) to the log. With -Repair it also restores the styles; by
## default it only observes, so the underlying cause stays visible. Exits by itself once the window
## is gone (hide() destroys the OS window).
const WATCHDOG_SCRIPT := """param([Parameter(Mandatory=$true)][long]$Hwnd, [Parameter(Mandatory=$true)][string]$LogPath, [switch]$Repair)
Add-Type @\"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class Win32Watch {
  [DllImport(\"user32.dll\")] public static extern bool IsWindow(IntPtr hWnd);
  [DllImport(\"user32.dll\")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport(\"user32.dll\")] public static extern int GetWindowLongW(IntPtr hWnd, int nIndex);
  [DllImport(\"user32.dll\")] public static extern int SetWindowLongW(IntPtr hWnd, int nIndex, int dwNewLong);
  [DllImport(\"user32.dll\")] public static extern bool SetLayeredWindowAttributes(IntPtr hWnd, uint crKey, byte bAlpha, uint dwFlags);
  [DllImport(\"user32.dll\")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
  [DllImport(\"user32.dll\")] public static extern IntPtr GetForegroundWindow();
  [DllImport(\"user32.dll\", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder s, int n);
  [DllImport(\"user32.dll\", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr hWnd, StringBuilder s, int n);
  [DllImport(\"user32.dll\")] public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
}
\"@
$h = [IntPtr]$Hwnd
$GWL_EXSTYLE = -20
$WS_EX_TRANSPARENT = 0x00000020
$WS_EX_TOOLWINDOW = 0x00000080
$WS_EX_TOPMOST = 0x00000008
$WS_EX_LAYERED = 0x00080000
$HWND_TOPMOST = [IntPtr](-1)
# SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
$SWP_RAISE = 0x13
function Describe($w) {
  if ($w -eq [IntPtr]::Zero) { return '<none>' }
  $t = New-Object System.Text.StringBuilder 256; [Win32Watch]::GetWindowTextW($w, $t, 256) | Out-Null
  $c = New-Object System.Text.StringBuilder 256; [Win32Watch]::GetClassNameW($w, $c, 256) | Out-Null
  return ('[{0}] ''{1}''' -f $c.ToString(), $t.ToString())
}
function Log($msg) { Add-Content -Path $LogPath -Value ('{0} {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $msg) }
Log ('watchdog start hwnd=' + $Hwnd)
$lastAbove = [IntPtr]::Zero
$lastLost = ''
while ([Win32Watch]::IsWindow($h)) {
  Start-Sleep -Milliseconds 1000
  if (-not [Win32Watch]::IsWindow($h)) { break }
  # Diagnostics only: note when a different visible window sits directly above
  # us in the z-order (the pick window and other always-on-top windows may
  # legitimately do so, so this is never "fixed").
  $above = [Win32Watch]::GetWindow($h, 3)   # GW_HWNDPREV: next window up in z-order
  if ($above -ne $lastAbove) {
    $lastAbove = $above
    if ($above -ne [IntPtr]::Zero -and [Win32Watch]::IsWindowVisible($above)) {
      Log ('window above overlay: ' + (Describe $above) + '; foreground=' + (Describe ([Win32Watch]::GetForegroundWindow())))
    }
  }
  $ex = [Win32Watch]::GetWindowLongW($h, $GWL_EXSTYLE)
  $fixes = @()
  if (($ex -band $WS_EX_TOPMOST) -eq 0) { $fixes += 'topmost' }
  if (($ex -band $WS_EX_LAYERED) -eq 0 -or ($ex -band $WS_EX_TRANSPARENT) -eq 0) { $fixes += 'click-through' }
  if (-not [Win32Watch]::IsWindowVisible($h)) { $fixes += 'visibility' }
  $state = $fixes -join ','
  if ($state -eq $lastLost) { continue }
  $lastLost = $state
  if ($fixes.Count -eq 0) { Log 'styles back to normal'; continue }
  Log (('lost {0}; exstyle=0x{1:x}; foreground={2}; above={3}') -f ($fixes -join ','), $ex, (Describe ([Win32Watch]::GetForegroundWindow())), (Describe $above))
  if (-not $Repair) { continue }
  if ($fixes -contains 'click-through') {
    [Win32Watch]::SetWindowLongW($h, $GWL_EXSTYLE, ($ex -bor $WS_EX_LAYERED -bor $WS_EX_TRANSPARENT -bor $WS_EX_TOOLWINDOW)) | Out-Null
    [Win32Watch]::SetLayeredWindowAttributes($h, 0, 255, 0x2) | Out-Null
  }
  [Win32Watch]::SetWindowPos($h, $HWND_TOPMOST, 0, 0, 0, 0, $SWP_RAISE) | Out-Null
}
Log 'watchdog end (window gone)'
"""

static var _helper_real_path: String = ""
static var _watchdog_real_path: String = ""


## True when this OS needs (and has) the native helper for real click-through.
static func is_supported() -> bool:
	return OS.get_name() == "Windows"


## Starts making the OS window behind `window` click-through for every other
## program. Runs asynchronously; poll OS.is_process_running() with the returned
## pid and read OS.get_process_exit_code() (0 = applied). Returns -1 if the
## helper could not be started.
static func begin_click_through(window: Window) -> int:
	var hwnd := _hwnd_of(window)
	if hwnd == 0:
		return -1
	_helper_real_path = _ensure_script(HELPER_PATH, HELPER_SCRIPT, _helper_real_path)
	if _helper_real_path.is_empty():
		return -1
	return _run(_helper_real_path, PackedStringArray(["-Hwnd", str(hwnd)]))


## Starts the watchdog that logs changes to the topmost / click-through styles
## of the OS window behind `window` (user://logs/overlay_watchdog.log). Returns
## the pid (stop it with OS.kill when hiding the window early) or -1.
static func begin_watchdog(window: Window) -> int:
	var hwnd := _hwnd_of(window)
	if hwnd == 0:
		return -1
	_watchdog_real_path = _ensure_script(WATCHDOG_PATH, WATCHDOG_SCRIPT, _watchdog_real_path)
	if _watchdog_real_path.is_empty():
		return -1
	var log_path := ProjectSettings.globalize_path("user://logs/overlay_watchdog.log")
	return _run(_watchdog_real_path, PackedStringArray(["-Hwnd", str(hwnd), "-LogPath", log_path]))


static func _hwnd_of(window: Window) -> int:
	if not is_supported() or window == null:
		return 0
	var window_id := window.get_window_id()
	if window_id == DisplayServer.INVALID_WINDOW_ID:
		return 0
	return DisplayServer.window_get_native_handle(DisplayServer.WINDOW_HANDLE, window_id)


static func _run(script_path: String, extra: PackedStringArray) -> int:
	var args := PackedStringArray([
		"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
		"-File", script_path,
	])
	args.append_array(extra)
	return OS.create_process("powershell.exe", args, false)


## Writes `content` to `path` once per run and returns its absolute path
## ("" if it could not be written). `cached` short-circuits later calls.
static func _ensure_script(path: String, content: String, cached: String) -> String:
	if not cached.is_empty():
		return cached
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	f.store_string(content)
	f.close()
	return ProjectSettings.globalize_path(path)
