extends "res://scripts/input/input_backend.gd"
class_name WindowsBackend
## Best-effort real input on Windows via a small PowerShell helper script.
##
## NOTE: Each call still spawns PowerShell, but we run it synchronously so
## action ordering and wait timings stay deterministic.

const HELPER_PATH := "user://input_helper.ps1"

var _helper_real_path: String = ""
var _last_pos: Vector2i = Vector2i.ZERO

const HELPER_SCRIPT := """param([Parameter(ValueFromRemainingArguments=$true)][string[]]$a)
$cmd = $a[0]
# Only the mouse commands need the P/Invoke shim; skipping the compile keeps
# 'pixel' / 'rect' reads (live colour previews, Pixel Detect) as quick as possible.
if ($cmd -ne 'pixel' -and $cmd -ne 'rect') {
Add-Type @\"
using System;
using System.Runtime.InteropServices;
public class Win32In {
  [DllImport(\"user32.dll\")] public static extern bool SetCursorPos(int x,int y);
  [DllImport(\"user32.dll\")] public static extern void mouse_event(uint f,uint dx,uint dy,uint d,IntPtr e);
}
\"@
}
switch ($cmd) {
  'move' { [Win32In]::SetCursorPos([int]$a[1],[int]$a[2]) | Out-Null }
  'down' {
    [Win32In]::SetCursorPos([int]$a[1],[int]$a[2]) | Out-Null
    switch ($a[3]) {
      '1' { [Win32In]::mouse_event(0x0008,0,0,0,[IntPtr]::Zero) }
      '2' { [Win32In]::mouse_event(0x0020,0,0,0,[IntPtr]::Zero) }
      default { [Win32In]::mouse_event(0x0002,0,0,0,[IntPtr]::Zero) }
    }
  }
  'up' {
    [Win32In]::SetCursorPos([int]$a[1],[int]$a[2]) | Out-Null
    switch ($a[3]) {
      '1' { [Win32In]::mouse_event(0x0010,0,0,0,[IntPtr]::Zero) }
      '2' { [Win32In]::mouse_event(0x0040,0,0,0,[IntPtr]::Zero) }
      default { [Win32In]::mouse_event(0x0004,0,0,0,[IntPtr]::Zero) }
    }
  }
  'key' {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.SendKeys]::SendWait([string]$a[1])
  }
  'pixel' {
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap 1,1
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen([int]$a[1],[int]$a[2],0,0,(New-Object System.Drawing.Size 1,1))
    $c = $bmp.GetPixel(0,0)
    Write-Output (\"{0},{1},{2}\" -f $c.R,$c.G,$c.B)
    $g.Dispose(); $bmp.Dispose()
  }
  'rect' {
    # Whole screen rect as a base64 PNG on one line (Pixel Detect scans it).
    Add-Type -AssemblyName System.Drawing
    $w = [Math]::Max(1, [int]$a[3]); $h = [Math]::Max(1, [int]$a[4])
    $bmp = New-Object System.Drawing.Bitmap $w,$h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen([int]$a[1],[int]$a[2],0,0,(New-Object System.Drawing.Size $w,$h))
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Output ([Convert]::ToBase64String($ms.ToArray()))
    $ms.Dispose(); $g.Dispose(); $bmp.Dispose()
  }
}
"""


func _init() -> void:
	_ensure_helper()


func backend_name() -> String:
	return "Windows (PowerShell, experimental)"


func is_real() -> bool:
	return true


func _ensure_helper() -> void:
	var f := FileAccess.open(HELPER_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(HELPER_SCRIPT)
		f.close()
		_helper_real_path = ProjectSettings.globalize_path(HELPER_PATH)


func _base_args() -> PackedStringArray:
	return PackedStringArray([
		"-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
		"-File", _helper_real_path,
	])


func _run_sync(extra: PackedStringArray) -> bool:
	if _helper_real_path.is_empty():
		return false
	var args := _base_args()
	args.append_array(extra)
	var output: Array = []
	var code := OS.execute("powershell.exe", args, output, true)
	return code == 0


func move_to(pos: Vector2i) -> void:
	_last_pos = pos
	_run_sync(PackedStringArray(["move", str(pos.x), str(pos.y)]))


func mouse_button(button: int, pressed: bool, pos: Vector2i) -> void:
	_last_pos = pos
	var verb := "down" if pressed else "up"
	_run_sync(PackedStringArray([verb, str(pos.x), str(pos.y), str(button)]))


func send_keys(text: String) -> void:
	if text.is_empty():
		return
	_run_sync(PackedStringArray(["key", text]))


func get_pixel(pos: Vector2i) -> Color:
	if _helper_real_path.is_empty():
		return Color(0, 0, 0, 0)
	# A read occasionally comes back empty (PowerShell start-up hiccup, or the
	# desktop momentarily unavailable to CopyFromScreen); one retry covers it,
	# and a failure that survives the retry is logged so it can be diagnosed.
	var first_error := ""
	for attempt in 2:
		var args := _base_args()
		args.append_array(PackedStringArray(["pixel", str(pos.x), str(pos.y)]))
		var output: Array = []
		var code := OS.execute("powershell.exe", args, output, true)
		var line := String(output[0]).strip_edges() if not output.is_empty() else ""
		var parts := line.split(",")
		if code == 0 and parts.size() >= 3:
			return Color8(int(parts[0]), int(parts[1]), int(parts[2]), 255)
		if attempt == 0:
			first_error = "exit %d, output %s" % [code, JSON.stringify(line)]
			OS.delay_msec(50)
	push_warning("WindowsBackend: pixel read at (%d, %d) failed twice (first: %s)." % [pos.x, pos.y, first_error])
	return Color(0, 0, 0, 0)


func read_rect(rect: Rect2i) -> Image:
	if _helper_real_path.is_empty():
		return null
	var first_error := ""
	for attempt in 2:
		var args := _base_args()
		args.append_array(PackedStringArray(["rect", str(rect.position.x), str(rect.position.y), str(rect.size.x), str(rect.size.y)]))
		var output: Array = []
		var code := OS.execute("powershell.exe", args, output, true)
		var line := String(output[0]).strip_edges() if not output.is_empty() else ""
		if code == 0 and not line.is_empty():
			var img := Image.new()
			if img.load_png_from_buffer(Marshalls.base64_to_raw(line)) == OK and not img.is_empty():
				return img
		if attempt == 0:
			first_error = "exit %d, %d chars of output" % [code, line.length()]
			OS.delay_msec(50)
	push_warning("WindowsBackend: screen read of [%d, %d, %d×%d] failed twice (first: %s)." % [rect.position.x, rect.position.y, rect.size.x, rect.size.y, first_error])
	return null
