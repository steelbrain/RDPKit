# Reads what Windows types for each character key with each keyboard layout in a request
# from generate-windows-keyboard-layout-tables.py, and writes it as layouts.json next to the
# request (or to -Output).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File capture-windows-keyboard-layouts.ps1 -RequestFile capture-request.json
#
# Needs Windows 10 1607 or later, where ToUnicodeEx can leave the keyboard state unchanged,
# so a dead key does not affect the next key read. Each layout is loaded into this process
# only, and unloaded again unless the user already had it. A layout Windows does not have is
# recorded as "missing".

param(
    [Parameter(Mandatory = $true)][string]$RequestFile,
    [string]$Output
)

$ErrorActionPreference = "Stop"
$RequestFile = (Resolve-Path $RequestFile).ProviderPath
if (-not $Output) {
    $Output = Join-Path (Split-Path -Parent $RequestFile) "layouts.json"
}
$request = Get-Content -Raw $RequestFile | ConvertFrom-Json

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class RDPKitKeyboardLayoutCapture {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr LoadKeyboardLayout(string klid, uint flags);
    [DllImport("user32.dll")] public static extern bool UnloadKeyboardLayout(IntPtr hkl);
    [DllImport("user32.dll")] public static extern int GetKeyboardLayoutList(int count, IntPtr[] list);
    [DllImport("user32.dll")] public static extern uint MapVirtualKeyEx(uint code, uint mapType, IntPtr hkl);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int ToUnicodeEx(uint vk, uint scancode, byte[] state, StringBuilder buffer, int size, uint flags, IntPtr hkl);
}
"@

$KLF_NOTELLSHELL = 0x80
$MAPVK_VSC_TO_VK = 1
$TOUNICODE_KEEP_KEYBOARD_STATE = 4
$VK_SHIFT = 0x10
$VK_CAPITAL = 0x14
$VK_LSHIFT = 0xA0

$loaded = New-Object IntPtr[] 256
$loadedCount = [RDPKitKeyboardLayoutCapture]::GetKeyboardLayoutList(256, $loaded)
$userLayouts = @($loaded | Select-Object -First $loadedCount)

$result = [ordered]@{}
foreach ($klid in $request.klids) {
    if (-not (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Control\Keyboard Layouts\$klid")) {
        $result[$klid] = "missing"
        continue
    }
    $hkl = [RDPKitKeyboardLayoutCapture]::LoadKeyboardLayout($klid, $KLF_NOTELLSHELL)
    if ($hkl -eq [IntPtr]::Zero) {
        $result[$klid] = "unloadable"
        continue
    }
    $keys = [ordered]@{}
    foreach ($scancode in $request.scancodes) {
        $vk = [RDPKitKeyboardLayoutCapture]::MapVirtualKeyEx($scancode, $MAPVK_VSC_TO_VK, $hkl)
        # Cells: no modifier, Shift, Caps Lock, Caps Lock and Shift; each [kind, text].
        $cells = @()
        foreach ($mode in 0..3) {
            $state = New-Object byte[] 256
            if ($mode -band 1) {
                $state[$VK_SHIFT] = 0x80
                $state[$VK_LSHIFT] = 0x80
            }
            if ($mode -band 2) {
                $state[$VK_CAPITAL] = 0x01
            }
            $buffer = New-Object System.Text.StringBuilder 16
            $count = [RDPKitKeyboardLayoutCapture]::ToUnicodeEx($vk, $scancode, $state, $buffer, 16, $TOUNICODE_KEEP_KEYBOARD_STATE, $hkl)
            if ($count -lt 0) {
                $cells += , @("dead", $buffer.ToString())
            } elseif ($count -eq 0) {
                $cells += , @("none", "")
            } else {
                $cells += , @("text", $buffer.ToString().Substring(0, $count))
            }
        }
        $keys[[string]$scancode] = [ordered]@{ vk = $vk; cells = $cells }
    }
    $result[$klid] = [ordered]@{ hkl = ("{0:X}" -f $hkl.ToInt64()); keys = $keys }
    if ($userLayouts -notcontains $hkl) {
        [void][RDPKitKeyboardLayoutCapture]::UnloadKeyboardLayout($hkl)
    }
}

# Written whole and then renamed, so a reader never sees half a file.
$json = $result | ConvertTo-Json -Depth 8 -Compress
[IO.File]::WriteAllText($Output + ".tmp", $json, (New-Object System.Text.UTF8Encoding $false))
Move-Item -Force ($Output + ".tmp") $Output
