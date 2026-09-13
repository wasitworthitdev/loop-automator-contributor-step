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
# 'guard <pid> <command...>': clicks and keys that would land on a window of
# that process are skipped (\"skipped\" is printed instead). Loop Automator
# passes its own pid unless ~Feedback is on, so a loop cannot drive the app
# that is running it.
$guard = 0
if ($a[0] -eq 'guard') { $guard = [int]$a[1]; $a = @($a | Select-Object -Skip 2) }
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
[StructLayout(LayoutKind.Sequential)] public struct Win32MouseInput { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr extra; }
[StructLayout(LayoutKind.Sequential)] public struct Win32Input { public uint type; public Win32MouseInput mi; }
public class Win32In {
  [DllImport(\"user32.dll\")] public static extern bool SetCursorPos(int x,int y);
  [DllImport(\"user32.dll\")] public static extern bool GetCursorPos(out Win32Pt p);
  [DllImport(\"user32.dll\")] public static extern IntPtr WindowFromPoint(Win32Pt p);
  [DllImport(\"user32.dll\")] public static extern IntPtr GetForegroundWindow();
  [DllImport(\"user32.dll\")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
  [DllImport(\"user32.dll\")] public static extern bool GetCursorInfo(ref Win32CursorInfo pci);
  [DllImport(\"user32.dll\")] public static extern IntPtr CopyIcon(IntPtr h);
  [DllImport(\"user32.dll\")] public static extern IntPtr CreateCursor(IntPtr inst,int xh,int yh,int w,int h,byte[] and,byte[] xor);
  [DllImport(\"user32.dll\")] public static extern bool SetSystemCursor(IntPtr h,uint id);
  [DllImport(\"user32.dll\")] public static extern bool SystemParametersInfo(uint a,uint b,IntPtr c,uint d);
  [DllImport(\"user32.dll\")] public static extern int GetSystemMetrics(int n);
  [DllImport(\"user32.dll\")] public static extern IntPtr LoadCursorW(IntPtr inst,IntPtr name);
  [DllImport(\"user32.dll\", CharSet=CharSet.Unicode)] public static extern IntPtr CreateWindowExW(int ex,string cls,string name,int style,int x,int y,int w,int h,IntPtr parent,IntPtr menu,IntPtr inst,IntPtr p);
  [DllImport(\"user32.dll\")] public static extern bool DestroyWindow(IntPtr h);
  [DllImport(\"winmm.dll\")] public static extern uint timeBeginPeriod(uint ms);
  [DllImport(\"winmm.dll\")] public static extern uint timeEndPeriod(uint ms);
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
  [DllImport(\"user32.dll\")] static extern uint SendInput(uint n,Win32Input[] inputs,int size);
  // One input event that moves the cursor to (x,y) AND presses / releases a
  // button there. SetCursorPos followed by mouse_event is two steps, and any
  // real mouse motion queued in between lands the click off its point.
  public static void MouseAt(int x,int y,uint buttonFlag) {
    int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77), vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
    Win32Input[] inp = new Win32Input[1];
    inp[0].type = 0;
    // Absolute coordinates: 0..65535 across the virtual desktop, mapped back
    // to pixels with (abs * size) >> 16, so round up to land on the pixel.
    inp[0].mi.dx = (int)Math.Ceiling((x - vx) * 65536.0 / vw);
    inp[0].mi.dy = (int)Math.Ceiling((y - vy) * 65536.0 / vh);
    inp[0].mi.dwFlags = 0x0001 | 0x8000 | 0x4000 | buttonFlag;  // MOVE | ABSOLUTE | VIRTUALDESK
    SendInput(1,inp,Marshal.SizeOf(typeof(Win32Input)));
  }
}
\"@
}
# Button flags for MouseAt: down / up for left, right ('1'), middle ('2').
function Down-Flag([string]$btn) { switch ($btn) { '1' { 0x0008 } '2' { 0x0020 } default { 0x0002 } } }
function Up-Flag([string]$btn) { switch ($btn) { '1' { 0x0010 } '2' { 0x0040 } default { 0x0004 } } }
function Read-Cursor { $p = New-Object Win32Pt; [Win32In]::GetCursorPos([ref]$p) | Out-Null; return $p }
# Captured actions: ($sx,$sy) is where the cursor started, ($lx,$ly) where we
# last knew it to be, and ($ux,$uy) the user's own movement so far. Jump moves
# the cursor to the action point and pins it there: every reading folds the
# movement since the last one into ($ux,$uy) and snaps the cursor back, so a
# hand that keeps moving cannot drag the click off its point (the movement
# all goes to the ghost / the restore instead). The user's position (start +
# movement) is kept on the virtual screen, where a real cursor would have
# stopped at the edge.
$script:sx = 0; $script:sy = 0; $script:lx = 0; $script:ly = 0; $script:ux = 0; $script:uy = 0
$script:vx = 0; $script:vy = 0; $script:vr = 0; $script:vb = 0
$script:pinned = $false; $script:px = 0; $script:py = 0
function Read-Motion {
  $p = Read-Cursor
  $script:ux += $p.X - $script:lx; $script:uy += $p.Y - $script:ly
  $script:lx = $p.X; $script:ly = $p.Y
  if ($script:vr -gt $script:vx) {
    $script:ux = [math]::Max($script:vx, [math]::Min($script:vr, $script:sx + $script:ux)) - $script:sx
    $script:uy = [math]::Max($script:vy, [math]::Min($script:vb, $script:sy + $script:uy)) - $script:sy
  }
  if ($script:pinned -and ($p.X -ne $script:px -or $p.Y -ne $script:py)) {
    [Win32In]::SetCursorPos($script:px,$script:py) | Out-Null
    $script:lx = $script:px; $script:ly = $script:py
  }
}
function Jump([int]$nx, [int]$ny) {
  Read-Motion; Ghost-Move
  [Win32In]::SetCursorPos($nx,$ny) | Out-Null
  $script:lx = $nx; $script:ly = $ny
  $script:px = $nx; $script:py = $ny; $script:pinned = $true
}
# Ghost cursor: the real cursor is made invisible while it is off doing the
# action, and a click-through window showing the same cursor image follows the
# user's hand instead, so nothing appears to jump.
$script:ghost = [IntPtr]::Zero; $script:ghostBmp = [IntPtr]::Zero; $script:hidden = $false
$script:hx = 0; $script:hy = 0; $script:gw = 32; $script:gh = 32
$script:cursorIds = @(32512,32513,32514,32515,32516,32642,32643,32644,32645,32646,32648,32649,32650)
$script:cursorCopies = @{}
function Ghost-Move {
  if ($script:ghost -eq [IntPtr]::Zero) { return }
  # SWP_NOSIZE | SWP_NOACTIVATE, kept HWND_TOPMOST
  [Win32In]::SetWindowPos($script:ghost, [IntPtr](-1), ($script:sx + $script:ux - $script:hx), ($script:sy + $script:uy - $script:hy), 0, 0, 0x11) | Out-Null
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
  $gx = $script:sx - $script:hx; $gy = $script:sy - $script:hy
  # A bare popup window (no WinForms Form: that only turns TopMost on when it
  # is shown, and a background process is not allowed to raise a window to
  # topmost after the fact - it must be created that way).
  # WS_EX_TOPMOST | WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW |
  # WS_EX_NOACTIVATE: above everything, per-pixel alpha, never takes a click
  # or the focus, not in the taskbar. [int]::MinValue is WS_POPUP.
  $h = [Win32In]::CreateWindowExW((0x8 -bor 0x80000 -bor 0x20 -bor 0x80 -bor 0x08000000), 'Static', '', [int]::MinValue, $gx, $gy, $script:gw, $script:gh, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
  if ($h -eq [IntPtr]::Zero) { return }
  $script:ghostBmp = $bmp.GetHbitmap([System.Drawing.Color]::FromArgb(0))
  [Win32In]::SetAlphaBitmap($h, $script:ghostBmp, $gx, $gy, $script:gw, $script:gh)
  $script:ghost = $h
  # Catch up with the hand before the ghost appears (the snapshot above took a
  # few ms), then SW_SHOWNOACTIVATE.
  Read-Motion; Ghost-Move
  [Win32In]::ShowWindow($h, 4) | Out-Null
  [System.Windows.Forms.Application]::DoEvents()
  # Now blank every system cursor so the real one is invisible while it works,
  # keeping a copy of each so they can be put straight back afterwards.
  $cw = [Win32In]::GetSystemMetrics(13); $ch = [Win32In]::GetSystemMetrics(14)
  $bytes = [int][math]::Floor(($cw + 7) / 8) * $ch
  foreach ($id in $script:cursorIds) {
    $orig = [Win32In]::LoadCursorW([IntPtr]::Zero, [IntPtr]$id)
    if ($orig -ne [IntPtr]::Zero) { $c = [Win32In]::CopyIcon($orig); if ($c -ne [IntPtr]::Zero) { $script:cursorCopies[$id] = $c } }
    $and = New-Object byte[] $bytes
    for ($i = 0; $i -lt $bytes; $i++) { $and[$i] = 255 }
    $xor = New-Object byte[] $bytes
    $blank = [Win32In]::CreateCursor([IntPtr]::Zero, 0, 0, $cw, $ch, $and, $xor)
    if ($blank -ne [IntPtr]::Zero) { [Win32In]::SetSystemCursor($blank, $id) | Out-Null }
  }
  $script:hidden = $true
  Read-Motion; Ghost-Move
}
function Ghost-Stop {
  if ($script:hidden) {
    # Put the saved copies straight back (SetSystemCursor consumes them);
    # SPI_SETCURSORS (a slower full reload of the scheme) covers any we missed.
    $missed = $false
    foreach ($id in $script:cursorIds) {
      if ($script:cursorCopies.ContainsKey($id)) { if (-not [Win32In]::SetSystemCursor($script:cursorCopies[$id], $id)) { $missed = $true } }
      else { $missed = $true }
    }
    $script:cursorCopies = @{}
    if ($missed) { [Win32In]::SystemParametersInfo(0x57, 0, [IntPtr]::Zero, 0) | Out-Null }
    $script:hidden = $false
  }
  if ($script:ghost -ne [IntPtr]::Zero) { [Win32In]::DestroyWindow($script:ghost) | Out-Null; $script:ghost = [IntPtr]::Zero }
  if ($script:ghostBmp -ne [IntPtr]::Zero) { [Win32In]::DeleteObject($script:ghostBmp) | Out-Null; $script:ghostBmp = [IntPtr]::Zero }
}
# Waits, keeping the real cursor pinned and the ghost on the user's hand
# meanwhile (every ~1 ms, so each display frame gets the freshest position).
function Wait-Ms([int]$ms) {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  do {
    Read-Motion
    if ($script:ghost -ne [IntPtr]::Zero) {
      Ghost-Move
      [System.Windows.Forms.Application]::DoEvents()
    }
    [System.Threading.Thread]::Sleep(1)
  } while ($sw.ElapsedMilliseconds -lt $ms)
}
# True when $h belongs to the guarded process (see 'guard' above).
function Guarded([IntPtr]$h) {
  if ($guard -eq 0 -or $h -eq [IntPtr]::Zero) { return $false }
  $owner = [uint32]0
  [Win32In]::GetWindowThreadProcessId($h, [ref]$owner) | Out-Null
  return ($owner -eq [uint32]$guard)
}
# True when a click at (x, y) would land on the guarded process. The overlay
# is hit-test transparent, so WindowFromPoint looks straight through it.
function Guarded-Point([int]$x,[int]$y) {
  $p = New-Object Win32Pt; $p.X = $x; $p.Y = $y
  return (Guarded ([Win32In]::WindowFromPoint($p)))
}
switch ($cmd) {
  'move' { [Win32In]::SetCursorPos([int]$a[1],[int]$a[2]) | Out-Null }
  'down' {
    if (Guarded-Point ([int]$a[1]) ([int]$a[2])) { Write-Output 'skipped'; break }
    [Win32In]::MouseAt([int]$a[1],[int]$a[2],(Down-Flag $a[3]))
  }
  'up' {
    if (Guarded-Point ([int]$a[1]) ([int]$a[2])) { Write-Output 'skipped'; break }
    [Win32In]::MouseAt([int]$a[1],[int]$a[2],(Up-Flag $a[3]))
  }
  'cap' {
    # cap <move|click|drag> <ghost 0|1> <button> <x> <y> <x2> <y2> <ms>
    # A whole Captures action in one process: remember the cursor, do the
    # action, put the cursor back where it was plus whatever the user moved it
    # meanwhile - so it is only away for a few milliseconds and the user's own
    # movement is never lost. With ghost=1 the real cursor is hidden for the
    # duration and a ghost cursor stands in for it, so nothing appears to jump.
    # Prints \"savedX,savedY,restoredX,restoredY\".
    $kind = $a[1]; $useGhost = ($a[2] -eq '1'); $btn = $a[3]
    $x = [int]$a[4]; $y = [int]$a[5]; $x2 = [int]$a[6]; $y2 = [int]$a[7]; $ms = [int]$a[8]
    if ($kind -ne 'move' -and ((Guarded-Point $x $y) -or ($kind -eq 'drag' -and (Guarded-Point $x2 $y2)))) {
      Write-Output 'skipped'; break
    }
    $s = Read-Cursor
    $script:sx = $s.X; $script:sy = $s.Y; $script:lx = $s.X; $script:ly = $s.Y
    # SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN
    $script:vx = [Win32In]::GetSystemMetrics(76); $script:vy = [Win32In]::GetSystemMetrics(77)
    $script:vr = $script:vx + [Win32In]::GetSystemMetrics(78) - 1; $script:vb = $script:vy + [Win32In]::GetSystemMetrics(79) - 1
    # 1 ms timer resolution: Thread.Sleep(1) is otherwise ~16 ms, which would
    # leave the pin / ghost updating at a stuttery ~60 Hz.
    $timerRes = ([Win32In]::timeBeginPeriod(1) -eq 0)
    try {
      if ($useGhost) { Ghost-Start }
      Jump $x $y
      switch ($kind) {
        'move' { Wait-Ms $ms }
        'click' {
          Wait-Ms 15
          [Win32In]::MouseAt($x,$y,(Down-Flag $btn)); Wait-Ms 15; [Win32In]::MouseAt($x,$y,(Up-Flag $btn))
        }
        'drag' {
          Wait-Ms 15
          [Win32In]::MouseAt($x,$y,(Down-Flag $btn))
          Wait-Ms $ms
          Jump $x2 $y2
          Wait-Ms 15
          [Win32In]::MouseAt($x2,$y2,(Up-Flag $btn))
        }
      }
      Read-Motion
      $script:pinned = $false
      $tx = $s.X + $script:ux; $ty = $s.Y + $script:uy
      [Win32In]::SetCursorPos($tx,$ty) | Out-Null
      $script:lx = $tx; $script:ly = $ty
    } finally {
      Ghost-Stop
      if ($timerRes) { [Win32In]::timeEndPeriod(1) | Out-Null }
    }
    Write-Output (\"{0},{1},{2},{3}\" -f $s.X,$s.Y,$tx,$ty)
  }
  'cursors-restore' {
    # Reload the user's cursor scheme (undoes ghost blanking after a crash).
    [Win32In]::SystemParametersInfo(0x57, 0, [IntPtr]::Zero, 0) | Out-Null
  }
  'key' {
    # Keys go to the foreground window.
    if (Guarded ([Win32In]::GetForegroundWindow())) { Write-Output 'skipped'; break }
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
## printed nothing). Input commands carry the guard pid (see the helper's
## 'guard'); a command the guard refused sets `last_skipped`.
func _run_sync(extra: PackedStringArray) -> String:
	if _helper_real_path.is_empty():
		return ""
	var args := _base_args()
	if avoid_pid > 0:
		args.append_array(PackedStringArray(["guard", str(avoid_pid)]))
	args.append_array(extra)
	var output: Array = []
	var code := OS.execute("powershell.exe", args, output, true)
	if code != 0 or output.is_empty():
		return ""
	var line := String(output[0]).strip_edges()
	last_skipped = (line == "skipped")
	return line


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


func run_captured(kind: String, button: int, from: Vector2i, to: Vector2i, ms: int, ghost: bool) -> Array:
	var line := _run_sync(PackedStringArray([
		"cap", kind, "1" if ghost else "0", str(button),
		str(from.x), str(from.y), str(to.x), str(to.y), str(ms)]))
	if last_skipped:
		return []
	var saved := _parse_point(line, 0)
	var restored := _parse_point(line, 2)
	if saved == Vector2i(-1, -1) or restored == Vector2i(-1, -1):
		push_warning("WindowsBackend: captured %s failed (output %s)." % [kind, JSON.stringify(line)])
		if ghost:
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
