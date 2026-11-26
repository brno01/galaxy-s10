<#
  S10 na tela do Windows (scrcpy), pelo adb do atheron (o S10 fica no USB dele).
  Um ssh só (apelido `s10-tela` no ~/.ssh/config: usuário restrito s10tunnel, porta 2222, chave s10-tela_ed25519):
    -L 127.0.0.1:15037 -> socket unix do adb do atheron   (porta 15037 para não brigar com um adb local do Windows)
    -L 127.0.0.1:27183 -> 127.0.0.1:27183                  (vídeo do scrcpy com --force-adb-forward)
  Ao fechar a janela do scrcpy, o túnel é encerrado.

  Uso:  s10-tela [-Rapido] [-Serial <serial>] [-Extra '--turn-screen-off','--show-touches']   (extras do scrcpy, entre aspas)
  Instalado por windows/s10-dev.sh em ~/.local/bin (com s10-tela.cmd ao lado). Variáveis só para testes:
    S10_SSH, S10_SCRCPY, S10_TUNNEL_HOST, S10_TUNNEL_TIMEOUT
#>
param(
    [switch]$Rapido,
    [string]$Serial = '',
    [string[]]$Extra = @()
)
$ErrorActionPreference = 'Stop'

$AdbPort = 15037
$ScrPort = 27183
$Remote = '/run/cerberus-s10/adb.sock'
$Ssh = if ($env:S10_SSH) { $env:S10_SSH } else { 'ssh' }
$Scrcpy = if ($env:S10_SCRCPY) { $env:S10_SCRCPY } else { 'scrcpy' }
$TunnelHost = if ($env:S10_TUNNEL_HOST) { $env:S10_TUNNEL_HOST } else { 's10-tela' }
$Timeout = if ($env:S10_TUNNEL_TIMEOUT) { [int]$env:S10_TUNNEL_TIMEOUT } else { 15 }

function Test-Port([int]$Port) {
    $c = [System.Net.Sockets.TcpClient]::new()
    try {
        $t = $c.ConnectAsync('127.0.0.1', $Port)
        return ($t.Wait(300) -and $c.Connected)
    } catch { return $false } finally { $c.Dispose() }
}

if (-not (Get-Command $Scrcpy -ErrorAction SilentlyContinue)) {
    Write-Host "scrcpy não encontrado. Instale: winget install Genymobile.scrcpy (ou rode de novo o windows/s10-dev.sh)"
    exit 1
}
if (Test-Port $AdbPort) {
    Write-Host "a porta 127.0.0.1:$AdbPort já está em uso (outro s10-tela aberto?). Feche-o e tente de novo."
    exit 1
}

$sshArgs = @('-N', '-o', 'ExitOnForwardFailure=yes', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8',
    '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3',
    '-L', "127.0.0.1:${AdbPort}:${Remote}", '-L', "127.0.0.1:${ScrPort}:127.0.0.1:${ScrPort}", $TunnelHost)
Write-Host "túnel até o adb do atheron ($TunnelHost) ..."
$tunnel = Start-Process -FilePath $Ssh -ArgumentList $sshArgs -NoNewWindow -PassThru

try {
    $deadline = (Get-Date).AddSeconds($Timeout)
    while (-not (Test-Port $AdbPort)) {
        if ($tunnel.HasExited) {
            Write-Host "o túnel não subiu (ssh saiu com código $($tunnel.ExitCode)). Teste: ssh $TunnelHost"
            exit 1
        }
        if ((Get-Date) -gt $deadline) {
            Write-Host "o túnel não respondeu em $Timeout s. Teste: ssh $TunnelHost"
            exit 1
        }
        Start-Sleep -Milliseconds 200
    }

    # o adb do scrcpy fala com o servidor do atheron pela porta do túnel
    $env:ANDROID_ADB_SERVER_PORT = "$AdbPort"
    $base = @('--force-adb-forward', '--no-audio', '--stay-awake', '--window-title=S10')
    if ($Serial) { $base += "--serial=$Serial" }
    if ($Rapido) {
        $base += @('--max-size=1024', '--video-bit-rate=4M')
        $codecs = @('h264')
    } else {
        $base += @('--max-size=1440', '--video-bit-rate=8M', '--max-fps=60')
        $codecs = @('h265', 'h264')
    }
    $rc = 1
    foreach ($codec in $codecs) {
        $start = Get-Date
        & $Scrcpy @base "--video-codec=$codec" @Extra
        $rc = $LASTEXITCODE
        # falha logo no começo com h265 = o aparelho recusou o codec: tenta o próximo
        if ($rc -eq 0 -or ((Get-Date) - $start).TotalSeconds -ge 10) { break }
        Write-Host "$codec recusado, tentando o próximo codec..."
    }
    exit $rc
} finally {
    if (-not $tunnel.HasExited) { Stop-Process -Id $tunnel.Id -Force -ErrorAction SilentlyContinue }
}
