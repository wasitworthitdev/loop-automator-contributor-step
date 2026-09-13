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
# 'pixel' / 'rect' / 'cursor' reads (live colour previews, Pixel Detect,
# Capture) as quick as possible.
if ($cmd -ne 'pixel' -and $cmd -ne 'rect' -and $cmd -ne 'cursor') {
Add-Type @\"
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)] public struct Win32Pt { public int X; public int Y; }
[StructLayout(LayoutKind.Sequential)] public struct Win32Sz { public int W; public int H; }
[StructLayout(LayoutKind.Sequential)] public struct Win32CursorInfo { public int cbSize; public int flags; public IntPtr hCursor; public Win32Pt pt; }
[StructLayout(LayoutKind.Sequential, Pack=1)] public struct Win32Blend { public byte op; public byte flags; public byte alpha; public byte fmt; }
public class Win32In {
  [DllImport(\"user32.dll\")] public static extern bool SetCursorPos(int x,int y);
  [DllImport(\"user32.dll\")] public static extern bool GetCursorPos(out Win32Pt p);
  [DllImport(\"user32.dll\")] public static extern void mouse_event(uint f,uint dx,uint dy,uint d,IntPtr e);
  [DllImport(\"user32.dll\")] public static extern bool GetCursorInfo(ref Win32CursorInfo pci);
  [DllImport(\"user32.dll\")] public static extern IntPtr CopyIcon(IntPtr h);
  [DllImport(\"user32.dll\")] public static extern IntPtr CreateCursor(IntPtr inst,int xh,int yh,int w,int h,byte[] and,byte[] xor);
  [DllImport(\"user32.dll\")] public static extern bool SetSystemCursor(IntPtr h,uint id);
  [DllImport(\"user32.dll\")] public static extern bool SystemParametersInfo(uint a,uint b,IntPtr c,uint d);
  [DllImport(\"user32.dll\")] public static extern int GetSystemMetrics(int n);
  [DllImport(\"user32.dll\")] public static extern bool ShowWindow(IntPtr h,int n);
  [DllImport(\"user32.dll\")] public static extern int GetWindowLongW(IntPtr h,int i);
  [DllImport(\"user32.dll\")] public static extern int SetWindowLongW(IntPtr h,int i,int v);
  [DllImport(\"user32.dll\")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int cx,int cy,uint f);
  [DllImport(\"user32.dll\")] static extern IntPtr GetDC(IntPtr h);
  [DllImport(\"user32.dll\")] static extern int ReleaseDC(IntPtr h,IntPtr dc);
  [DllImport(\"user32.dll\")] static extern bool UpdateLayeredWindow(IntPtr h,IntPtr dst,ref Win32Pt pos,ref Win32Sz sz,IntPtr src,ref Win32Pt srcPos,int key,ref Win32Blend blend,int flags);
  [DllImport(\"gdi32.dll\")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
  [DllImport(\"gdi32.dll\")] static extern IntPtr SelectObject(IntPtr dc,IntPtr o);
  [DllImport(\"gdi32.dll\")] public static extern bool DeleteObject(IntPtr o);
  [DllImport(\"gdi32.dll\")] static extern bool DeleteDC(IntPtr dc);
  // Gives a WS_EX_LAYERED window per-pixel alpha content from a 32bpp
  // premultiplied bitmap (what Bitmap.GetHbitmap(Color.FromArgb(0)) yields).
  public static void SetAlphaBitmap(IntPtr hwnd,IntPtr hbmp,int x,int y,int w,int h) {
    IntPtr screen = GetDC(IntPtr.Zero);
    IntPtr mem = CreateCompatibleDC(screen);
    IntPtr old = SelectObject(mem,hbmp);
    Win32Pt pos = new Win32Pt(); pos.X = x; pos.Y = y;
    Win32Sz sz = new Win32Sz(); sz.W = w; sz.H = h;
    Win32Pt src = new Win32Pt();
    Win32Blend b = new Win32Blend(); b.op = 0; b.flags = 0; b.alpha = 255; b.fmt = 1;
    UpdateLayeredWindow(hwnd,screen,ref pos,ref sz,mem,ref src,0,ref b,2);
    SelectObject(mem,old); DeleteDC(mem); ReleaseDC(IntPtr.Zero,screen);
  }
}
\"@
}
function Mouse-Down([string]$btn) {
  switch ($btn) {
    '1' { [Win32In]::mouse_event(0x0008,0,0,0,[IntPtr]::Zero) }
    '2' { [Win32In]::mouse_event(0x0020,0,0,0,[IntPtr]::Zero) }
    default { [Win32In]::mouse_event(0x0002,0,0,0,[IntPtr]::Zero) }
  }
}
function Mouse-Up([string]$btn) {
  switch ($btn) {
    '1' { [Win32In]::mouse_event(0x0010,0,0,0,[IntPtr]::Zero) }
    '2' { [Win32In]::mouse_event(0x0040,0,0,0,[IntPtr]::Zero) }
    default { [Win32In]::mouse_event(0x0004,0,0,0,[IntPtr]::Zero) }
  }
}
function Read-Cursor { $p = New-Object Win32Pt; [Win32In]::GetCursorPos([ref]$p) | Out-Null; return $p }
# Captured actions: ($sx,$sy) is where the cursor started, ($lx,$ly) where we
# last knew it to be, and ($ux,$uy) the user's own movement so far (Lag
# Compensation). Jump moves the cursor, folding any movement since the last
# reading into ($ux,$uy) first.
$script:sx = 0; $script:sy = 0; $script:lx = 0; $script:ly = 0; $script:ux = 0; $script:uy = 0
function Read-Motion {
  $p = Read-Cursor
  $script:ux += $p.X - $script:lx; $script:uy += $p.Y - $script:ly
  $script:lx = $p.X; $script:ly = $p.Y
}
function Jump([int]$nx, [int]$ny) {
  Read-Motion
  [Win32In]::SetCursorPos($nx,$ny) | Out-Null
  $script:lx = $nx; $script:ly = $ny
}
# Ghost cursor (Lag Compensation): the real cursor is made invisible while it
# is off doing the action, and a click-through window showing the same cursor
# image follows the user's hand instead, so nothing appears to jump.
$script:ghost = $null; $script:ghostBmp = [IntPtr]::Zero; $script:hidden = $false
$script:hx = 0; $script:hy = 0; $script:gw = 32; $script:gh = 32
function Ghost-Move {
  if ($script:ghost -eq $null) { return }
  # SWP_NOSIZE | SWP_NOACTIVATE, kept HWND_TOPMOST
  [Win32In]::SetWindowPos($script:ghost.Handle, [IntPtr](-1), ($script:sx + $script:ux - $script:hx), ($script:sy + $script:uy - $script:hy), 0, 0, 0x11) | Out-Null
}
function Ghost-Start {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  # A private copy of the cursor the user sees right now (the shared system
  # handle is about to be blanked).
  $ci = New-Object Win32CursorInfo
  $ci.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($ci)
  $bmp = $null
  if ([Win32In]::GetCursorInfo([ref]$ci) -and $ci.hCursor -ne [IntPtr]::Zero) {
    $copy = [Win32In]::CopyIcon($ci.hCursor)
    if ($copy -ne [IntPtr]::Zero) {
      try {
        $cur = New-Object System.Windows.Forms.Cursor($copy)
        $script:hx = $cur.HotSpot.X; $script:hy = $cur.HotSpot.Y
        $bmp = [System.Drawing.Icon]::FromHandle($copy).ToBitmap()
      } catch { $bmp = $null }
    }
  }
  if ($bmp -eq $null) {
    $cur = [System.Windows.Forms.Cursors]::Arrow
    $script:hx = $cur.HotSpot.X; $script:hy = $cur.HotSpot.Y
    $bmp = New-Object System.Drawing.Bitmap $cur.Size.Width, $cur.Size.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $cur.Draw($g, (New-Object System.Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height))
    $g.Dispose()
  }
  $script:gw = $bmp.Width; $script:gh = $bmp.Height
  $f = New-Object System.Windows.Forms.Form
  $f.FormBorderStyle = 'None'; $f.ShowInTaskbar = $false; $f.TopMost = $true
  $f.StartPosition = 'Manual'
  $f.Size = New-Object System.Drawing.Size $script:gw, $script:gh
  $f.Location = New-Object System.Drawing.Point ($script:sx - $script:hx), ($script:sy - $script:hy)
  # Reading Handle creates the window without Form.Show(), which would steal
  # the focus from whatever the click is aimed at.
  $h = $f.Handle
  # WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE:
  # per-pixel alpha, never takes a click or the focus, not in the taskbar.
  [Win32In]::SetWindowLongW($h, -20, ([Win32In]::GetWindowLongW($h, -20) -bor 0x80000 -bor 0x20 -bor 0x80 -bor 0x08000000)) | Out-Null
  $script:ghostBmp = $bmp.GetHbitmap([System.Drawing.Color]::FromArgb(0))
  [Win32In]::SetAlphaBitmap($h, $script:ghostBmp, ($script:sx - $script:hx), ($script:sy - $script:hy), $script:gw, $script:gh)
  # SW_SHOWNOACTIVATE
  [Win32In]::ShowWindow($h, 4) | Out-Null
  $script:ghost = $f
  [System.Windows.Forms.Application]::DoEvents()
  # Now blank every system cursor so the real one is invisible while it works.
  $cw = [Win32In]::GetSystemMetrics(13); $ch = [Win32In]::GetSystemMetrics(14)
  $bytes = [int][math]::Floor(($cw + 7) / 8) * $ch
  foreach ($id in 32512,32513,32514,32515,32516,32642,32643,32644,32645,32646,32648,32649,32650) {
    $and = New-Object byte[] $bytes
    for ($i = 0; $i -lt $bytes; $i++) { $and[$i] = 255 }
    $xor = New-Object byte[] $bytes
    $blank = [Win32In]::CreateCursor([IntPtr]::Zero, 0, 0, $cw, $ch, $and, $xor)
    if ($blank -ne [IntPtr]::Zero) { [Win32In]::SetSystemCursor($blank, $id) | Out-Null }
  }
  $script:hidden = $true
}
function Ghost-Stop {
  # SPI_SETCURSORS reloads the user's cursor scheme, undoing the blanking.
  if ($script:hidden) { [Win32In]::SystemParametersInfo(0x57, 0, [IntPtr]::Zero, 0) | Out-Null; $script:hidden = $false }
  if ($script:ghost -ne $null) { $script:ghost.Close(); $script:ghost.Dispose(); $script:ghost = $null }
  if ($script:ghostBmp -ne [IntPtr]::Zero) { [Win32In]::DeleteObject($script:ghostBmp) | Out-Null; $script:ghostBmp = [IntPtr]::Zero }
}
# Waits, keeping the ghost on the user's hand meanwhile (~200 Hz).
function Wait-Ms([int]$ms) {
  if ($script:ghost -eq $null) { if ($ms -gt 0) { Start-Sleep -Milliseconds $ms }; return }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  do {
    Read-Motion
    Ghost-Move
    [System.Windows.Forms.Application]::DoEvents()
    [System.Threading.Thread]::Sleep(4)
  } while ($sw.ElapsedMilliseconds -lt $ms)
}
switch ($cmd) {
  'move' { [Win32In]::SetCursorPos([int]$a[1],[int]$a[2]) | Out-Null }
  'down' {
    [Win32In]::SetCursorPos([int]$a[1],[int]$a[2]) | Out-Null
    Mouse-Down $a[3]
  }
  'up' {
    [Win32In]::SetCursorPos([int]$a[1],[int]$a[2]) | Out-Null
    Mouse-Up $a[3]
  }
  'cap' {
    # cap <move|click|drag> <comp 0|1> <button> <x> <y> <x2> <y2> <ms>
    # A whole Captures action in one process: remember the cursor, do the
    # action, put the cursor back - so it is only away for a few milliseconds.
    # With comp=1 (Lag Compensation) the user's own movement meanwhile is
    # added to the restore, and a ghost cursor stands in for the hidden real
    # one so the user sees their cursor carry on as normal.
    # Prints \"savedX,savedY,restoredX,restoredY\".
    $kind = $a[1]; $comp = ($a[2] -eq '1'); $btn = $a[3]
    $x = [int]$a[4]; $y = [int]$a[5]; $x2 = [int]$a[6]; $y2 = [int]$a[7]; $ms = [int]$a[8]
    $s = Read-Cursor
    $script:sx = $s.X; $script:sy = $s.Y; $script:lx = $s.X; $script:ly = $s.Y
    try {
      if ($comp) { Ghost-Start }
      Jump $x $y
      switch ($kind) {
        'move' { Wait-Ms $ms }
        'click' {
          Wait-Ms 15
          Mouse-Down $btn; Wait-Ms 15; Mouse-Up $btn
        }
        'drag' {
          Wait-Ms 15
          Mouse-Down $btn
          Wait-Ms $ms
          Jump $x2 $y2
          Wait-Ms 15
          Mouse-Up $btn
        }
      }
      $tx = $s.X; $ty = $s.Y
      if ($comp) {
        Read-Motion
        $tx += $script:ux; $ty += $script:uy
      }
      [Win32In]::SetCursorPos($tx,$ty) | Out-Null
      $script:lx = $tx; $script:ly = $ty
    } finally {
      Ghost-Stop
    }
    Write-Output (\"{0},{1},{2},{3}\" -f $s.X,$s.Y,$tx,$ty)
  }
  'cursors-restore' {
    # Reload the user's cursor scheme (undoes ghost blanking after a crash).
    [Win32In]::SystemParametersInfo(0x57, 0, [IntPtr]::Zero, 0) | Out-Null
  }
  'key' {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.SendKeys]::SendWait([string]$a[1])
  }
  'cursor' {
    # Where the real cursor is right now, as "x,y" (Capture actions).
    Add-Type -AssemblyName System.Windows.Forms
    $p = [System.Windows.Forms.Cursor]::Position
    Write-Output (\"{0},{1}\" -f $p.X,$p.Y)
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


## Runs the helper and returns its first output line ("" if it failed or
## printed nothing).
func _run_sync(extra: PackedStringArray) -> String:
	if _helper_real_path.is_empty():
		return ""
	var args := _base_args()
	args.append_array(extra)
	var output: Array = []
	var code := OS.execute("powershell.exe", args, output, true)
	if code != 0 or output.is_empty():
		return ""
	return String(output[0]).strip_edges()


## Parses the first point of an "x,y[,...]" line from the helper, or (-1, -1).
static func _parse_point(line: String, offset: int = 0) -> Vector2i:
	var parts := line.split(",")
	if parts.size() >= offset + 2 and parts[offset].is_valid_int() and parts[offset + 1].is_valid_int():
		return Vector2i(int(parts[offset]), int(parts[offset + 1]))
	return Vector2i(-1, -1)


func move_to(pos: Vector2i) -> void:
	_last_pos = pos
	_run_sync(PackedStringArray(["move", str(pos.x), str(pos.y)]))


func mouse_button(button: int, pressed: bool, pos: Vector2i) -> void:
	_last_pos = pos
	var verb := "down" if pressed else "up"
	_run_sync(PackedStringArray([verb, str(pos.x), str(pos.y), str(button)]))


func run_captured(kind: String, button: int, from: Vector2i, to: Vector2i, ms: int, compensate: bool) -> Array:
	var line := _run_sync(PackedStringArray([
		"cap", kind, "1" if compensate else "0", str(button),
		str(from.x), str(from.y), str(to.x), str(to.y), str(ms)]))
	var saved := _parse_point(line, 0)
	var restored := _parse_point(line, 2)
	if saved == Vector2i(-1, -1) or restored == Vector2i(-1, -1):
		push_warning("WindowsBackend: captured %s failed (output %s)." % [kind, JSON.stringify(line)])
		if compensate:
			# The helper may have died with the system cursors blanked.
			_run_sync(PackedStringArray(["cursors-restore"]))
		return []
	_last_pos = restored
	return [saved, restored]


func send_keys(text: String) -> void:
	if text.is_empty():
		return
	_run_sync(PackedStringArray(["key", text]))


func get_cursor_pos() -> Vector2i:
	if _helper_real_path.is_empty():
		return Vector2i(-1, -1)
	var first_error := ""
	for attempt in 2:
		var args := _base_args()
		args.append("cursor")
		var output: Array = []
		var code := OS.execute("powershell.exe", args, output, true)
		var line := String(output[0]).strip_edges() if not output.is_empty() else ""
		var pos := _parse_point(line)
		if code == 0 and pos != Vector2i(-1, -1):
			return pos
		if attempt == 0:
			first_error = "exit %d, output %s" % [code, JSON.stringify(line)]
			OS.delay_msec(50)
	push_warning("WindowsBackend: cursor position read failed twice (first: %s)." % first_error)
	return Vector2i(-1, -1)


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
