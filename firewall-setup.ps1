# Restrange expunerea in retea a Ollama (portul 11434).
#
# TREBUIE RULAT CA ADMINISTRATOR. Modifica reguli de firewall — citeste-l inainte.
#
# Ce face:
#   1. Dezactiveaza regulile inbound "Allow" create de installerul Ollama pe
#      profilul Public. Fara asta, pe o retea publica (Wi-Fi de cafenea) oricine
#      din aceeasi retea poate interoga modelul pe 11434.
#   2. Adauga o regula inbound stricta: portul 11434 accesibil DOAR din subnetul
#      Docker/WSL (172.16.0.0/12), de unde vine containerul Open WebUI.
#
# Reversibil:  .\firewall-setup.ps1 -Undo
#
# De ce e nevoie de asta: Ollama asculta pe 0.0.0.0 (necesar ca containerul sa-l
# poata contacta prin host.docker.internal). Firewall-ul e stratul care
# transforma "asculta pe tot" in "accesibil doar din Docker".

[CmdletBinding()]
param(
    [switch]$Undo
)

$ErrorActionPreference = 'Stop'

$RULE_NAME    = 'Agent local - Ollama 11434 (numai Docker/WSL)'
$DOCKER_SUBNET = '172.16.0.0/12'
$PORT          = 11434

# --- Verificare privilegii ---
$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "`nEROARE: scriptul are nevoie de drepturi de administrator." -ForegroundColor Red
    Write-Host "Deschide PowerShell ca administrator si ruleaza din nou:`n" -ForegroundColor Yellow
    Write-Host "  cd '$PSScriptRoot'" -ForegroundColor Gray
    Write-Host "  .\firewall-setup.ps1`n" -ForegroundColor Gray
    exit 1
}

function Show-OllamaRules($titlu) {
    Write-Host "`n--- $titlu ---" -ForegroundColor Cyan
    $rules = Get-NetFirewallRule -ErrorAction SilentlyContinue |
             Where-Object { $_.DisplayName -like '*llama*' -or $_.DisplayName -eq $RULE_NAME }
    if (-not $rules) { Write-Host "  (nicio regula)" -ForegroundColor DarkGray; return }
    foreach ($r in $rules) {
        $addr = (Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $r -ErrorAction SilentlyContinue).RemoteAddress
        $col = if ($r.Enabled -eq 'True' -and $r.Action -eq 'Allow' -and ($addr -contains 'Any')) { 'Red' } else { 'Gray' }
        Write-Host ("  {0,-45} {1,-8} {2,-6} enabled={3,-5} prof={4,-16} remote={5}" -f `
            $r.DisplayName, $r.Direction, $r.Action, $r.Enabled, $r.Profile, ($addr -join ',')) -ForegroundColor $col
    }
}

Show-OllamaRules "INAINTE"

if ($Undo) {
    Write-Host "`n=== ANULARE ===" -ForegroundColor Yellow

    Get-NetFirewallRule -DisplayName $RULE_NAME -ErrorAction SilentlyContinue |
        ForEach-Object {
            Remove-NetFirewallRule -Name $_.Name -Confirm:$false
            Write-Host "  sters: $RULE_NAME" -ForegroundColor Gray
        }

    Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like '*llama*' -and $_.Direction -eq 'Inbound' -and $_.Enabled -eq 'False' } |
        ForEach-Object {
            Set-NetFirewallRule -Name $_.Name -Enabled True
            Write-Host "  reactivat: $($_.DisplayName) [$($_.Profile)]" -ForegroundColor Gray
        }

    Show-OllamaRules "DUPA ANULARE"
    Write-Host "`nRegulile originale ale installerului au fost restaurate.`n" -ForegroundColor Green
    exit 0
}

# --- 1. Dezactiveaza allow-urile permisive ale installerului ---
Write-Host "`n=== 1. Dezactivez regulile permisive ale installerului ===" -ForegroundColor Cyan

$permisive = Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object {
    $_.DisplayName -like '*llama*' -and
    $_.Direction   -eq 'Inbound'   -and
    $_.Action      -eq 'Allow'     -and
    $_.Enabled     -eq 'True'
}

if (-not $permisive) {
    Write-Host "  Nicio regula permisiva de dezactivat." -ForegroundColor Gray
} else {
    foreach ($r in $permisive) {
        # Dezactivat, nu sters: un update de Ollama le recreeaza oricum, iar
        # dezactivarea e reversibila cu -Undo.
        Set-NetFirewallRule -Name $r.Name -Enabled False
        Write-Host "  dezactivat: $($r.DisplayName) [profil=$($r.Profile)]" -ForegroundColor Green
    }
}

# --- 2. Regula stricta pentru Docker ---
Write-Host "`n=== 2. Adaug regula stricta pentru subnetul Docker ===" -ForegroundColor Cyan

Get-NetFirewallRule -DisplayName $RULE_NAME -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-NetFirewallRule -Name $_.Name -Confirm:$false }

New-NetFirewallRule `
    -DisplayName   $RULE_NAME `
    -Direction     Inbound `
    -Action        Allow `
    -Protocol      TCP `
    -LocalPort     $PORT `
    -RemoteAddress $DOCKER_SUBNET `
    -Profile       Any `
    -Description   'Permite containerului Open WebUI sa contacteze Ollama. Orice alta sursa cade pe default-deny inbound.' | Out-Null

Write-Host "  creat: $RULE_NAME" -ForegroundColor Green
Write-Host "         port $PORT/TCP, remote = $DOCKER_SUBNET" -ForegroundColor DarkGray

Show-OllamaRules "DUPA"

Write-Host @"

=== Gata ===

Ollama e acum accesibil doar de pe aceasta masina si din subnetul Docker.

Pasul urmator — confirma ca interfata mai vorbeste cu modelul:
  .\start.ps1
  .\verifica-privacy.ps1

Daca containerul NU mai ajunge la Ollama, subnetul Docker e altul decat
172.16.0.0/12. Afla-l cu:
  docker network inspect bridge --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
si ajusteaza `$DOCKER_SUBNET din acest script.

Anulare completa:  .\firewall-setup.ps1 -Undo

"@ -ForegroundColor White
