# Porneste agentul local: Docker Desktop -> Open WebUI -> browser.
# Ollama ruleaza ca serviciu Windows, deci porneste singur la boot.

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

function Write-Step($msg) { Write-Host "  $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  OK  $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  !   $msg" -ForegroundColor Yellow }

Write-Host "`n=== Agent local — pornire ===`n" -ForegroundColor White

# --- 1. Ollama (numai serverul, NU aplicatia GUI) ---
#
# Aplicatia desktop "ollama app.exe" NU se foloseste deliberat: are integrare
# cloud activata implicit (OLLAMA_NO_CLOUD=false, remotes=ollama.com), verifica
# update-uri din oră în oră, descarca "recomandari de modele" si — observat direct
# la instalare — porneste singura descarcarea unui model recomandat de ~7 GB pe
# care nimeni nu l-a cerut. Interfata noastra e Open WebUI, deci GUI-ul Ollama e
# inutil. Rulam doar `ollama serve`.

Write-Step "Verific Ollama pe 127.0.0.1:11434 ..."
$ollamaOk = $false
try {
    $tags = Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 5
    $ollamaOk = $true
    Write-Ok "Ollama raspunde. Modele: $(($tags.models | ForEach-Object { $_.name }) -join ', ')"
} catch {
    Write-Warn "Ollama nu raspunde. Pornesc serverul ..."

    # Variabilele se seteaza explicit in procesul curent: o sesiune PowerShell
    # deschisa inainte de instalare nu are variabilele de nivel User.
    $env:OLLAMA_HOST               = '0.0.0.0:11434'  # necesar pentru accesul din container
    $env:OLLAMA_KEEP_ALIVE         = '30m'            # nu reincarca modelul la fiecare intrebare
    $env:OLLAMA_MAX_LOADED_MODELS  = '1'              # 6 GB VRAM: un singur model
    $env:OLLAMA_CONTEXT_LENGTH     = '8192'           # implicit ar fi 4096 — prea putin pentru loguri
    $env:OLLAMA_NO_CLOUD           = '1'              # taie orice ruta spre ollama.com
    $env:OLLAMA_NOHISTORY          = '1'              # fara istoric de prompturi pe disc

    $exe = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
    if (-not (Test-Path $exe)) { throw "Nu gasesc ollama.exe la $exe" }

    $logDir = Join-Path $PSScriptRoot 'logs'
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

    # Redirectionam stdout/stderr: `ollama serve` pornit manual nu scrie in
    # %LOCALAPPDATA%\Ollama\server.log, iar fara log nu putem verifica nimic.
    Start-Process -FilePath $exe -ArgumentList 'serve' -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $logDir 'ollama-server.log') `
        -RedirectStandardError  (Join-Path $logDir 'ollama-server.err.log')

    foreach ($i in 1..20) {
        Start-Sleep -Seconds 2
        try {
            Invoke-RestMethod -Uri 'http://127.0.0.1:11434/api/tags' -TimeoutSec 3 | Out-Null
            $ollamaOk = $true
            Write-Ok "Ollama a pornit (server-only, fara GUI)."
            break
        } catch { }
    }
}

if ($ollamaOk) {
    # Confirmare din log ca ruta spre cloud e inchisa.
    # Ollama scrie logurile INFO pe stderr, deci in .err.log — nu in .log.
    $srvLog = Join-Path $PSScriptRoot 'logs\ollama-server.err.log'
    if (Test-Path $srvLog) {
        $cloud = Select-String -Path $srvLog -Pattern 'cloud disabled' | Select-Object -Last 1
        if ($cloud) {
            if ($cloud.Line -match 'disabled: true') { Write-Ok "Cloud Ollama dezactivat." }
            else { Write-Warn "ATENTIE: cloud-ul Ollama e ACTIV. Verifica OLLAMA_NO_CLOUD." }
        }
    }
    if (Get-Process -Name 'ollama app' -ErrorAction SilentlyContinue) {
        Write-Warn "Aplicatia GUI Ollama ruleaza — poate descarca modele nesolicitate."
        Write-Host "     Opreste-o din tray, sau: Stop-Process -Name 'ollama app' -Force" -ForegroundColor DarkGray
    }
} else {
    Write-Warn "Ollama tot nu raspunde. Interfata va porni, dar fara modele."
}

# --- 2. Docker Desktop ---
Write-Step "Verific daemonul Docker ..."
$dockerOk = $false
try { docker info --format '{{.ServerVersion}}' 2>$null | Out-Null; if ($LASTEXITCODE -eq 0) { $dockerOk = $true } } catch { }

if (-not $dockerOk) {
    Write-Warn "Docker nu ruleaza. Pornesc Docker Desktop (poate lua 1-2 minute) ..."
    $dd = "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
    if (-not (Test-Path $dd)) { throw "Nu gasesc Docker Desktop la $dd" }
    Start-Process $dd
    foreach ($i in 1..60) {
        Start-Sleep -Seconds 3
        docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $dockerOk = $true; break }
        if ($i % 10 -eq 0) { Write-Host "     ... inca astept ($($i*3)s)" -ForegroundColor DarkGray }
    }
    if (-not $dockerOk) { throw "Docker Desktop nu a pornit in 3 minute. Porneste-l manual si reia." }
    Write-Ok "Docker gata."
} else {
    Write-Ok "Docker ruleaza."
}

# --- 3. Open WebUI ---
Write-Step "Pornesc containerul Open WebUI ..."
docker compose up -d
if ($LASTEXITCODE -ne 0) { throw "docker compose up a esuat." }

Write-Step "Astept ca interfata sa fie gata ..."
$webOk = $false
foreach ($i in 1..40) {
    Start-Sleep -Seconds 3
    try {
        Invoke-WebRequest -Uri 'http://127.0.0.1:3000/health' -TimeoutSec 3 -UseBasicParsing | Out-Null
        $webOk = $true; break
    } catch { }
    if ($i % 10 -eq 0) { Write-Host "     ... inca astept ($($i*3)s)" -ForegroundColor DarkGray }
}

if ($webOk) {
    Write-Ok "Interfata e gata."
    Start-Process 'http://127.0.0.1:3000'
    Write-Host "`n  http://127.0.0.1:3000`n" -ForegroundColor White
} else {
    Write-Warn "Interfata nu a raspuns la /health. Verifica logurile:"
    Write-Host "    docker compose logs --tail 50" -ForegroundColor DarkGray
}
