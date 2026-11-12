# Runs the versus test suite: zombie senses (1 process), then TDM and FFA matches with a
# real host + client (2 game processes talking over localhost WebSockets).
#
#   powershell -ExecutionPolicy Bypass -File tests\run_versus_tests.ps1
#   powershell -ExecutionPolicy Bypass -File tests\run_versus_tests.ps1 -Godot "C:\path\to\Godot_console.exe"
#
# Tests use their own save files (user://vs_*.save), so your real save is untouched.

param(
    [string]$Godot = "C:\Users\JESSE\Documents\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe",
    [int]$Port = 47960
)

$Root = Split-Path -Parent $PSScriptRoot
$T = Join-Path $PSScriptRoot "versus"
$Logs = Join-Path $env:TEMP "deadroute_tests"
New-Item -ItemType Directory -Force $Logs | Out-Null
Push-Location $Root

function Run-Pair($hostScript, $clientScript, $port) {
    $hlog = Join-Path $Logs "$hostScript.log"
    $h = Start-Process -FilePath $Godot -ArgumentList "--headless", "-s", "`"$T\$hostScript`"", "--",
        "--save=user://vs_host.save", "--port=$port" -RedirectStandardOutput $hlog `
        -RedirectStandardError "$hlog.err" -PassThru -WindowStyle Hidden
    & $Godot --headless -s "$T\$clientScript" -- --save=user://vs_client.save --port=$port 2>&1 |
        Select-String "PASS|FAIL|RESULT|SCRIPT ERROR|TIMEOUT"
    $h.WaitForExit(150000) | Out-Null
    Get-Content $hlog, "$hlog.err" | Select-String "PASS|FAIL|RESULT|SCRIPT ERROR|TIMEOUT"
}

"=== Zombie senses ==="
& $Godot --headless -s "$T\senses_test.gd" -- --save=user://vs_senses.save 2>&1 |
    Select-String "PASS|FAIL|RESULT|SCRIPT ERROR|TIMEOUT"
"=== Team Deathmatch (host + client) ==="
Run-Pair "vs_host.gd" "vs_client.gd" $Port
"=== Free For All + disconnect (host + client) ==="
Run-Pair "ffa_host.gd" "ffa_client.gd" ($Port + 1)
Pop-Location
