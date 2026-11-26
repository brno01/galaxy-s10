# Tests for windows/s10-tela.ps1 with a fake ssh (listens on the tunnel port) and a fake scrcpy.
# Runs in pwsh 7 (Linux or Windows): pwsh -NoProfile -File windows/tests/test_s10_tela.ps1
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$script = Join-Path $here '..' 's10-tela.ps1'
$T = Join-Path ([IO.Path]::GetTempPath()) ("s10tela-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $T | Out-Null
$calls = Join-Path $T 'calls'
$script:fail = 0; $script:n = 0
function ok($name, [scriptblock]$cond) {
    $script:n++
    if (& $cond) { Write-Host "ok   $name" } else { Write-Host "FAIL $name"; $script:fail++ }
}
$isWin = $IsWindows -or ($PSVersionTable.PSEdition -eq 'Desktop')
$ext = if ($isWin) { '.cmd' } else { '' }

# fake ssh: records its argv, listens on 127.0.0.1:15037 until killed (FAKE_SSH_FAIL=1: exits 255 at once)
$fakeSsh = Join-Path $T "fakessh.ps1"
@'
Add-Content -Path $env:CALLS -Value ("ssh " + ($args -join ' '))
if ($env:FAKE_SSH_FAIL -eq '1') { exit 255 }
$l = [System.Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 15037)
$l.Start()
while ($true) { if ($l.Pending()) { $l.AcceptTcpClient().Dispose() }; Start-Sleep -Milliseconds 50 }
'@ | Set-Content -Path $fakeSsh
# fake scrcpy: records argv + the adb port it was given; FAKE_RC_<codec> sets the exit code
$fakeScrcpy = Join-Path $T "fakescrcpy.ps1"
@'
Add-Content -Path $env:CALLS -Value ("scrcpy port=" + $env:ANDROID_ADB_SERVER_PORT + " " + ($args -join ' '))
$codec = ($args | Where-Object { $_ -like '--video-codec=*' }) -replace '--video-codec=', ''
$rc = [Environment]::GetEnvironmentVariable("FAKE_RC_$codec")
if ($rc) { exit [int]$rc } else { exit 0 }
'@ | Set-Content -Path $fakeScrcpy
# launchers the script can Start-Process / & by name
$pw = (Get-Process -Id $PID).Path
if ($isWin) {
    Set-Content "$T\fssh.cmd" "@`"$pw`" -NoProfile -File `"$fakeSsh`" %*"
    Set-Content "$T\fscrcpy.cmd" "@`"$pw`" -NoProfile -File `"$fakeScrcpy`" %*`r`n@exit /b %ERRORLEVEL%"
} else {
    Set-Content "$T/fssh" "#!/bin/sh`nexec '$pw' -NoProfile -File '$fakeSsh' `"`$@`""
    Set-Content "$T/fscrcpy" "#!/bin/sh`nexec '$pw' -NoProfile -File '$fakeScrcpy' `"`$@`""
    chmod +x "$T/fssh" "$T/fscrcpy"
}
$env:CALLS = $calls
$env:S10_SSH = Join-Path $T "fssh$ext"
$env:S10_SCRCPY = Join-Path $T "fscrcpy$ext"
$env:S10_TUNNEL_HOST = 's10-tela-test'
$env:S10_TUNNEL_TIMEOUT = '20'

function Run([string[]]$a) {
    Set-Content -Path $calls -Value $null
    & $pw -NoProfile -File $script @a *> (Join-Path $T 'out')
    return $LASTEXITCODE
}
function Calls { Get-Content $calls | Where-Object { $_ } }
function PortOpen { $c = [Net.Sockets.TcpClient]::new(); try { $t = $c.ConnectAsync('127.0.0.1', 15037); $t.Wait(300) -and $c.Connected } catch { $false } finally { $c.Dispose() } }

$rc = Run @()
ok 'normal run exits 0' { $rc -eq 0 }
$ssh = (Calls | Where-Object { $_ -like 'ssh *' }) | Select-Object -First 1
ok 'ssh: -N, batch, both forwards, tunnel host last' { $ssh -eq 'ssh -N -o ExitOnForwardFailure=yes -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -L 127.0.0.1:15037:/run/cerberus-s10/adb.sock -L 127.0.0.1:27183:127.0.0.1:27183 s10-tela-test' }
$sc = @(Calls | Where-Object { $_ -like 'scrcpy *' })
ok 'scrcpy once, via the tunnel port, forced forward, no audio, h265 first' { $sc.Count -eq 1 -and $sc[0] -like 'scrcpy port=15037 --force-adb-forward --no-audio --stay-awake --window-title=S10 --max-size=1440 --video-bit-rate=8M --max-fps=60 --video-codec=h265' }
Start-Sleep -Milliseconds 500
ok 'tunnel closed after scrcpy exits' { -not (PortOpen) }

$env:FAKE_RC_h265 = '1'
$rc = Run @()
$sc = @(Calls | Where-Object { $_ -like 'scrcpy *' })
ok 'h265 refused quickly -> retries with h264' { $rc -eq 0 -and $sc.Count -eq 2 -and $sc[1] -like '*--video-codec=h264' }
Remove-Item Env:FAKE_RC_h265

$rc = Run @('-Rapido', '-Serial', 'ABC123', '-Extra', '--turn-screen-off')
$sc = @(Calls | Where-Object { $_ -like 'scrcpy *' })
ok '-Rapido: h264 only, smaller; -Serial and extra args passed' { $sc.Count -eq 1 -and $sc[0] -like '*--serial=ABC123 --max-size=1024 --video-bit-rate=4M --video-codec=h264 --turn-screen-off' }

$env:FAKE_SSH_FAIL = '1'
$rc = Run @()
ok 'ssh fails -> clear message, no scrcpy' { $rc -ne 0 -and -not (Calls | Where-Object { $_ -like 'scrcpy *' }) -and ((Get-Content (Join-Path $T 'out')) -match 'túnel não subiu') }
Remove-Item Env:FAKE_SSH_FAIL

$env:S10_SCRCPY = Join-Path $T 'nao-existe'
$rc = Run @()
ok 'no scrcpy -> tells how to install, no ssh' { $rc -ne 0 -and -not (Calls) -and ((Get-Content (Join-Path $T 'out')) -match 'winget install Genymobile.scrcpy') }

Remove-Item -Recurse -Force $T
Write-Host "--- $($script:n) checks, $($script:fail) failed"
if ($script:fail -ne 0) { exit 1 }
