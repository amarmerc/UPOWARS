<#
.SYNOPSIS
  Simula en Windows lo que hara el contenedor: arma los argumentos igual que servidor/entrypoint.sh (a partir de variables
  de entorno o parametros), arranca el servidor dedicado headless y conecta un cliente simulado para comprobar que acepta jugadores.
.EXAMPLE
  .\servidor\probar_local.ps1
  .\servidor\probar_local.ps1 -Puerto 7778 -Modo libre -Tam 3 -Segundos 20
  .\servidor\probar_local.ps1 -ConBash        # usa de verdad servidor/entrypoint.sh (hace falta bash, p. ej. Git Bash)
#>
param(
  [int]$Puerto = $(if ($env:PUERTO) { [int]$env:PUERTO } else { 7777 }),
  [int]$Max = $(if ($env:MAX) { [int]$env:MAX } else { 10 }),
  [string]$Modo = $env:MODO,
  [string]$Zona = $env:ZONA,
  [string]$Tam = $env:TAM,
  [string]$Rondas = $env:RONDAS,
  [string]$Compra = $env:T_COMPRA,
  [int]$Clientes = 1,
  [int]$Segundos = 20,
  [string]$Proyecto = "",
  [string]$Godot = "D:\Juegos\godot\Godot_v4.7.2-stable_win64_console.exe",
  [switch]$ConBash
)
$ErrorActionPreference = "Stop"
$raiz = Split-Path -Parent $PSScriptRoot
if (-not $Proyecto) { $Proyecto = Join-Path $raiz "game" }
$logs = Join-Path $raiz "export\red_logs"
New-Item -ItemType Directory -Force $logs | Out-Null
$srvLog = Join-Path $logs "servidor_local.log"
$procs = @()

# Mismos argumentos que entrypoint.sh
$juego = @("--servidor", "puerto=$Puerto", "max=$Max")
foreach ($par in @(@("modo", $Modo), @("zona", $Zona), @("tam", $Tam), @("rondas", $Rondas), @("t_compra", $Compra))) {
  if ($par[1]) { $juego += "$($par[0])=$($par[1])" }
}
try {
  if ($ConBash) {
    $bash = (Get-Command bash -ErrorAction SilentlyContinue).Source
    if (-not $bash) { $bash = @("$env:ProgramFiles\Git\bin\bash.exe", "${env:ProgramFiles(x86)}\Git\bin\bash.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1 }
    if (-not $bash) { throw "No se encuentra bash (instalar Git for Windows)" }
    $env:GODOT_BIN = $Godot.Replace('\', '/'); $env:PROYECTO = $Proyecto.Replace('\', '/')
    $env:PUERTO = "$Puerto"; $env:MAX = "$Max"; $env:MODO = $Modo; $env:ZONA = $Zona; $env:TAM = $Tam; $env:RONDAS = $Rondas; $env:T_COMPRA = $Compra
    $srv = Start-Process -FilePath $bash -ArgumentList @(($PSScriptRoot.Replace('\', '/') + "/entrypoint.sh")) -PassThru -NoNewWindow -RedirectStandardOutput $srvLog -RedirectStandardError "$srvLog.err"
  } else {
    $srvArgs = @("--headless", "--audio-driver", "Dummy", "--path", $Proyecto, "--") + $juego
    $srv = Start-Process -FilePath $Godot -ArgumentList $srvArgs -PassThru -NoNewWindow -RedirectStandardOutput $srvLog -RedirectStandardError "$srvLog.err"
  }
  $procs += $srv
  $t0 = Get-Date
  while (-not (Select-String -Path $srvLog -Pattern "SERVIDOR LISTO" -Quiet -ErrorAction SilentlyContinue)) {
    Start-Sleep -Milliseconds 500
    if (((Get-Date) - $t0).TotalSeconds -gt 90) { throw "El servidor no arranco (ver $srvLog)" }
  }
  Write-Host "Servidor listo: $(Select-String -Path $srvLog -Pattern 'SERVIDOR LISTO' | Select-Object -First 1 -ExpandProperty Line)"
  for ($i = 1; $i -le $Clientes; $i++) {
    $cl = @("--headless", "--audio-driver", "Dummy", "--path", $Proyecto, "--", "--cliente-sim=127.0.0.1:$Puerto", "nombre=Sim$i")
    $cLog = Join-Path $logs "cliente_local$i.log"
    $procs += Start-Process -FilePath $Godot -ArgumentList $cl -PassThru -NoNewWindow -RedirectStandardOutput $cLog -RedirectStandardError "$cLog.err"
  }
  $c1 = Join-Path $logs "cliente_local1.log"
  $t0 = Get-Date; $ok = $false
  while (((Get-Date) - $t0).TotalSeconds -lt 90) {
    Start-Sleep -Seconds 2
    if (Select-String -Path $c1 -Pattern "CLIENTE-SIM estado=3" -Quiet -ErrorAction SilentlyContinue) { $ok = $true; break }
  }
  if ($ok) { Start-Sleep -Seconds $Segundos }
  Write-Host "--- servidor (stdout) ---"
  Get-Content $srvLog | Select-String "SERVIDOR" | Select-Object -Last 8
  Write-Host "--- cliente 1 ---"
  Get-Content $c1 | Select-String "CLIENTE-SIM" | Select-Object -Last 3
  $errs = @(Get-Content $srvLog, "$srvLog.err" -ErrorAction SilentlyContinue | Select-String "SCRIPT ERROR|ERROR:")
  Write-Host "Errores en el log del servidor: $($errs.Count)"
  if ($ok -and $errs.Count -eq 0) { Write-Host "RESULTADO: OK (el servidor acepta jugadores y arranca la partida)" -ForegroundColor Green }
  else { Write-Host "RESULTADO: FALLO" -ForegroundColor Red; $global:LASTEXITCODE = 1 }
} finally {
  foreach ($p in $procs) {
    if ($p -and -not $p.HasExited) {
      Get-CimInstance Win32_Process -Filter "ParentProcessId=$($p.Id)" | ForEach-Object {
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$($_.ProcessId)" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
      Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
  }
}
