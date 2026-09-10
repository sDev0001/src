# Opreste agentul local si elibereaza RAM-ul.

$ErrorActionPreference = 'Continue'
Set-Location $PSScriptRoot

Write-Host "`n=== Agent local — oprire ===`n" -ForegroundColor White

Write-Host "  Opresc containerul Open WebUI ..." -ForegroundColor Cyan
docker compose down

# Descarca modelul din RAM/VRAM. Datele conversatiilor ramin in volum,
# doar memoria se elibereaza.
$ollama = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
if (Test-Path $ollama) {
    Write-Host "  Descarc modelele din memorie ..." -ForegroundColor Cyan
    $running = & $ollama ps 2>$null
    if ($running -and $running.Count -gt 1) {
        $running | Select-Object -Skip 1 | ForEach-Object {
            $name = ($_ -split '\s+')[0]
            if ($name) { & $ollama stop $name 2>$null; Write-Host "    oprit: $name" -ForegroundColor DarkGray }
        }
    } else {
        Write-Host "    niciun model incarcat" -ForegroundColor DarkGray
    }
}

Write-Host "`n  Gata. Conversatiile sunt pastrate in volumul agent-local-webui-data.`n" -ForegroundColor Green
