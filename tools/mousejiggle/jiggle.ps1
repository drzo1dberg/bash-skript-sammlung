<#
.SYNOPSIS
  Bewegt den Mauszeiger alle paar Sekunden minimal hin und her,
  damit das System "aktiv" bleibt (kein Sperrbildschirm, kein "abwesend").

.PARAMETER IntervalSeconds
  Pause zwischen den Wackelbewegungen (Standard: 30 Sekunden).

.PARAMETER Pixels
  Wie viele Pixel der Zeiger versetzt wird (Standard: 3).

.EXAMPLE
  .\jiggle.ps1
  .\jiggle.ps1 -IntervalSeconds 15 -Pixels 5
#>

param(
    [int]$IntervalSeconds = 30,
    [int]$Pixels = 3
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class MouseJiggle {
    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT lpPoint);
    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, int dx, int dy, uint dwData, UIntPtr dwExtraInfo);
    public const uint MOUSEEVENTF_MOVE = 0x0001;
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }
}
"@

$direction = 1
$lastPos = New-Object MouseJiggle+POINT
[void][MouseJiggle]::GetCursorPos([ref]$lastPos)

while ($true) {
    Start-Sleep -Seconds $IntervalSeconds

    $currentPos = New-Object MouseJiggle+POINT
    [void][MouseJiggle]::GetCursorPos([ref]$currentPos)

    if ($currentPos.X -ne $lastPos.X -or $currentPos.Y -ne $lastPos.Y) {
        # User hat die Maus selbst bewegt -> kein Jiggle noetig
        $lastPos = $currentPos
        continue
    }

    $delta = $Pixels * $direction
    [MouseJiggle]::mouse_event([MouseJiggle]::MOUSEEVENTF_MOVE, $delta, $delta, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 200
    [MouseJiggle]::mouse_event([MouseJiggle]::MOUSEEVENTF_MOVE, -$delta, -$delta, 0, [UIntPtr]::Zero)

    [void][MouseJiggle]::GetCursorPos([ref]$lastPos)
    $direction = -$direction
}
