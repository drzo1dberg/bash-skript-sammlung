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
    public static extern bool SetCursorPos(int X, int Y);
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }
}
"@

Write-Host "Mouse Jiggle gestartet. Intervall: $IntervalSeconds s, Versatz: $Pixels px."
Write-Host "Zum Beenden: Strg+C"

$direction = 1
while ($true) {
    $pos = New-Object MouseJiggle+POINT
    [void][MouseJiggle]::GetCursorPos([ref]$pos)

    $newX = $pos.X + ($Pixels * $direction)
    $newY = $pos.Y + ($Pixels * $direction)

    [void][MouseJiggle]::SetCursorPos($newX, $newY)
    Start-Sleep -Milliseconds 200
    [void][MouseJiggle]::SetCursorPos($pos.X, $pos.Y)

    $direction = -$direction
    Start-Sleep -Seconds $IntervalSeconds
}
