<#
.SYNOPSIS
  Prueba de red local: lanza un servidor dedicado headless y N clientes automaticos (2 por defecto) en este PC, deja jugar unos segundos
  y mide CPU y memoria del servidor.
.EXAMPLE
  .\scripts\probar_red.ps1 -Segundos 40 -Lag 80 -Perdida 2
  .\scripts\probar_red.ps1 -Tam 5 -Modo cachimba_wars     # 2 humanos simulados + 8 bots
#>
param(
  [int]$Clientes = 2,
  [int]$Segundos = 40,
  [int]$Puerto = 7777,
  [int]$Lag = 0,
  [double]$Perdida = 0,
  [int]$Tam = 5,
  [string]$Modo = "cachimba_wars",
  [string]$Zona = "plaza_america",
  [string]$Godot = "D:\Juegos\godot\Godot_v4.7.2-stable_win64_console.exe",
  [switch]$ConVentana
)
$ErrorActionPreference = "Stop"
$raiz = Split-Path -Parent $PSScriptRoot
$proyecto = Join-Path $raiz "game"
$logs = Join-Path $raiz "export\red_logs"
New-Item -ItemType Directory -Force $logs | Out-Null
$extra = @("--lag=$Lag", "--perdida=$Perdida")
$procs = @()
try {
  $srvLog = Join-Path $logs "servidor.log"
  $srvArgs = @("--headless", "--path", $proyecto, "--", "--servidor", "puerto=$Puerto", "max=10", "modo=$Modo", "zona=$Zona", "tam=$Tam", "t_compra=5", "rondas=7") + $extra
  $srv = Start-Process -FilePath $Godot -ArgumentList $srvArgs -PassThru -NoNewWindow -RedirectStandardOutput $srvLog -RedirectStandardError (Join-Path $logs "servidor.err")
  $procs += $srv
  # esperar a que escuche
  $t0 = Get-Date
  while (-not (Select-String -Path $srvLog -Pattern "SERVIDOR LISTO" -Quiet -ErrorAction SilentlyContinue)) {
    Start-Sleep -Milliseconds 500
    if (((Get-Date) - $t0).TotalSeconds -gt 60) { throw "El servidor no arranco (ver $srvLog)" }
  }
  Write-Host "Servidor listo."
  # Godot_console.exe lanza el Godot real como proceso hijo: es el que hay que medir
  $hijo = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($srv.Id)" | Select-Object -First 1
  $medido = if ($hijo) { Get-Process -Id $hijo.ProcessId } else { $srv }
  for ($i = 1; $i -le $Clientes; $i++) {
    $cl = @("--headless", "--path", $proyecto, "--", "--cliente-sim=127.0.0.1:$Puerto", "nombre=Sim$i") + $extra
    if ($ConVentana) { $cl = $cl | Where-Object { $_ -ne "--headless" } }
    $p = Start-Process -FilePath $Godot -ArgumentList $cl -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $logs "cliente$i.log") -RedirectStandardError (Join-Path $logs "cliente$i.err")
    $procs += $p
  }
  Write-Host "Esperando a que arranque la partida..."
  $t0 = Get-Date
  while (-not (Select-String -Path (Join-Path $logs "cliente1.log") -Pattern "CLIENTE-SIM estado=3" -Quiet -ErrorAction SilentlyContinue)) {
    Start-Sleep -Seconds 2
    if (((Get-Date) - $t0).TotalSeconds -gt 90) { Write-Warning "La partida no arranco en 90 s"; break }
  }
  Write-Host "Midiendo $Segundos s (CPU y memoria del servidor)..."
  $cpu0 = $medido.TotalProcessorTime.TotalSeconds
  $t0 = Get-Date
  $maxMem = 0
  while (((Get-Date) - $t0).TotalSeconds -lt $Segundos) {
    Start-Sleep -Seconds 1
    $medido.Refresh()
    $maxMem = [Math]::Max($maxMem, $medido.WorkingSet64 / 1MB)
  }
  $dt = ((Get-Date) - $t0).TotalSeconds
  $cpu = ($medido.TotalProcessorTime.TotalSeconds - $cpu0) / $dt * 100
  Write-Host ("Servidor: CPU media {0:N1} % de un nucleo, memoria maxima {1:N0} MB (lag={2} ms, perdida={3} %)" -f $cpu, $maxMem, $Lag, $Perdida)
  Get-Content (Join-Path $logs "cliente1.log") | Select-String "CLIENTE-SIM" | Select-Object -Last 3
} finally {
  foreach ($p in $procs) {
    if ($p -and -not $p.HasExited) {
      Get-CimInstance Win32_Process -Filter "ParentProcessId=$($p.Id)" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
      Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
  }
}
