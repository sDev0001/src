# Audit de izolare pentru agentul local.
# Ruleaza-l oricand, mai ales inainte de a lucra cu loguri sensibile.
# Nu modifica nimic — doar citeste si raporteaza.

Set-Location $PSScriptRoot

$script:fail = 0
$script:warn = 0

function Test-Result($name, $ok, $detail, [switch]$WarnOnly) {
    if ($ok) {
        Write-Host "  [OK]   $name" -ForegroundColor Green
    } elseif ($WarnOnly) {
        Write-Host "  [?]    $name" -ForegroundColor Yellow
        $script:warn++
    } else {
        Write-Host "  [FAIL] $name" -ForegroundColor Red
        $script:fail++
    }
    if ($detail) { Write-Host "         $detail" -ForegroundColor DarkGray }
}

function Test-PrivateIp($ip) {
    if ($ip -eq '::1' -or $ip -eq '::' -or $ip -like '*:*') { return $true }   # IPv6/loopback: tratat separat
    if ($ip -notmatch '^\d+\.\d+\.\d+\.\d+$') { return $true }
    $o = $ip -split '\.' | ForEach-Object { [int]$_ }
    if ($o[0] -eq 127) { return $true }
    if ($o[0] -eq 10)  { return $true }
    if ($o[0] -eq 192 -and $o[1] -eq 168) { return $true }
    if ($o[0] -eq 172 -and $o[1] -ge 16 -and $o[1] -le 31) { return $true }
    if ($o[0] -eq 169 -and $o[1] -eq 254) { return $true }
    if ($o[0] -eq 0) { return $true }
    return $false
}

Write-Host "`n============================================" -ForegroundColor White
Write-Host " AUDIT IZOLARE — agent local" -ForegroundColor White
Write-Host "============================================`n" -ForegroundColor White

# ---------------------------------------------------------------
Write-Host "1. Porturi si expunere in retea" -ForegroundColor Cyan
# ---------------------------------------------------------------

$webui = Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue
if ($webui) {
    $badBind = $webui | Where-Object { $_.LocalAddress -notin @('127.0.0.1', '::1') }
    Test-Result "Open WebUI (3000) ascultat numai pe loopback" (-not $badBind) `
        ("adrese: " + (($webui.LocalAddress | Sort-Object -Unique) -join ', '))
} else {
    Test-Result "Open WebUI (3000) asculta" $false "portul 3000 nu e deschis — containerul nu ruleaza?" -WarnOnly
}

$oll = Get-NetTCPConnection -LocalPort 11434 -State Listen -ErrorAction SilentlyContinue
if ($oll) {
    $onAll = $oll | Where-Object { $_.LocalAddress -in @('0.0.0.0', '::') }
    if ($onAll) {
        Write-Host "  [i]    Ollama (11434) asculta pe 0.0.0.0 — necesar pentru Docker." -ForegroundColor DarkGray
        Write-Host "         Protectia reala e regula de firewall verificata mai jos." -ForegroundColor DarkGray
    } else {
        Test-Result "Ollama (11434) numai pe loopback" $true (($oll.LocalAddress | Sort-Object -Unique) -join ', ')
    }
} else {
    Test-Result "Ollama (11434) asculta" $false "Ollama nu ruleaza" -WarnOnly
}

# ---------------------------------------------------------------
Write-Host "`n2. Reguli de firewall pe 11434" -ForegroundColor Cyan
# ---------------------------------------------------------------

# Se verifica DOUA feluri de reguli. Installerul Ollama nu creeaza reguli pe
# port, ci pe PROGRAM (ollama.exe) — o verificare doar pe portul 11434 raporteaza
# "0 reguli" si da o falsa asigurare in timp ce accesul e larg deschis.
$inbound = @()

# a) reguli legate de portul 11434
Get-NetFirewallPortFilter -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -eq '11434' } |
    ForEach-Object {
        $inbound += Get-NetFirewallRule -AssociatedNetFirewallPortFilter $_ -ErrorAction SilentlyContinue |
                    Where-Object { $_.Direction -eq 'Inbound' -and $_.Enabled -eq 'True' }
    }

# b) reguli legate de executabilul ollama.exe
Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue |
    Where-Object { $_.Program -like '*ollama*' } |
    ForEach-Object {
        $inbound += Get-NetFirewallRule -AssociatedNetFirewallApplicationFilter $_ -ErrorAction SilentlyContinue |
                    Where-Object { $_.Direction -eq 'Inbound' -and $_.Enabled -eq 'True' }
    }

$inbound = $inbound | Sort-Object -Property Name -Unique

$permissive = @()
foreach ($r in $inbound) {
    if ($r.Action -ne 'Allow') { continue }
    $addr = (Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $r -ErrorAction SilentlyContinue).RemoteAddress
    if ($addr -contains 'Any' -or -not $addr) { $permissive += "$($r.DisplayName) [$($r.Profile)]" }
}

Test-Result "Nicio regula inbound permisiva (RemoteAddress=Any)" ($permissive.Count -eq 0) `
    $(if ($permissive.Count) { "permisive: " + ($permissive -join '; ') + "  ->  ruleaza firewall-setup.ps1 ca admin" }
      else { "reguli inbound active pe port sau program: $($inbound.Count)" })

$profileState = Get-NetFirewallProfile | Select-Object Name, Enabled, DefaultInboundAction
$badProfiles = $profileState | Where-Object { $_.Enabled -ne 'True' -or $_.DefaultInboundAction -eq 'Allow' }
Test-Result "Firewall activ pe toate profilurile, inbound default = Block" ($badProfiles.Count -eq 0) `
    (($profileState | ForEach-Object { "$($_.Name)=$($_.Enabled)/$($_.DefaultInboundAction)" }) -join ' ')

# ---------------------------------------------------------------
Write-Host "`n3. Conexiuni active spre internet (ollama.exe)" -ForegroundColor Cyan
# ---------------------------------------------------------------

$ollamaPids = (Get-Process -Name 'ollama', 'ollama app' -ErrorAction SilentlyContinue).Id
if ($ollamaPids) {
    $conns = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
             Where-Object { $ollamaPids -contains $_.OwningProcess }
    $public = $conns | Where-Object { -not (Test-PrivateIp $_.RemoteAddress) }
    Test-Result "ollama.exe nu are conexiuni spre IP-uri publice" ($public.Count -eq 0) `
        $(if ($public.Count) { ($public | ForEach-Object { "$($_.RemoteAddress):$($_.RemotePort)" }) -join ', ' }
          else { "conexiuni active: $($conns.Count), toate locale" })
} else {
    Test-Result "Proces ollama activ" $false "ollama nu ruleaza — nimic de auditat" -WarnOnly
}

# ---------------------------------------------------------------
Write-Host "`n4. Ollama: cloud, GUI, modele nesolicitate" -ForegroundColor Cyan
# ---------------------------------------------------------------

# Aplicatia desktop Ollama are integrare cloud activata implicit si a fost
# observata pornind singura descarcarea unui model de ~7 GB. Nu trebuie sa ruleze.
$gui = Get-Process -Name 'ollama app' -ErrorAction SilentlyContinue
Test-Result "Aplicatia GUI Ollama nu ruleaza" (-not $gui) `
    $(if ($gui) { "PID $($gui.Id) — opreste-o: Stop-Process -Name 'ollama app' -Force" }
      else { "doar serverul, cum trebuie" })

$noCloud = [Environment]::GetEnvironmentVariable('OLLAMA_NO_CLOUD','User')
Test-Result "OLLAMA_NO_CLOUD = 1" ($noCloud -eq '1') "valoare: $(if ($noCloud) { $noCloud } else { '<nesetata>' })"

# Ollama scrie logurile INFO pe stderr, deci in .err.log — nu in .log.
$srvLog = Join-Path $PSScriptRoot 'logs\ollama-server.err.log'
if (Test-Path $srvLog) {
    $cloudLine = Select-String -Path $srvLog -Pattern 'cloud disabled' | Select-Object -Last 1
    if ($cloudLine) {
        Test-Result "Serverul confirma in log: cloud dezactivat" ($cloudLine.Line -match 'disabled: true') `
            $cloudLine.Line.Trim()
    }
} else {
    Test-Result "Log server prezent (logs\ollama-server.log)" $false "porneste cu .\start.ps1 ca sa se genereze" -WarnOnly
}

$lnk = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup\Ollama.lnk"
Test-Result "GUI-ul Ollama nu porneste la boot" (-not (Test-Path $lnk)) `
    $(if (Test-Path $lnk) { "shortcut recreat (probabil de un update) — muta-l sau sterge-l" })

# Blob-uri partiale orfane = descarcari intrerupte sau nesolicitate care ocupa disc.
$blobDir = "$env:USERPROFILE\.ollama\models\blobs"
if (Test-Path $blobDir) {
    $orfane = Get-ChildItem $blobDir -File -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -like '*partial*' -and $_.Length -gt 100MB }
    $gb = if ($orfane) { [math]::Round((($orfane | Measure-Object Length -Sum).Sum)/1GB, 2) } else { 0 }
    Test-Result "Niciun blob partial mare pe disc" ($orfane.Count -eq 0) `
        $(if ($orfane.Count) { "$($orfane.Count) fisier(e), $gb GB — vezi README, secțiunea curatare" }) -WarnOnly

    $modele = & "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe" list 2>$null | Select-Object -Skip 1 |
              Where-Object { $_.Trim() } | ForEach-Object { ($_ -split '\s+')[0] }
    Write-Host "  [i]    Modele instalate: $(if ($modele) { $modele -join ', ' } else { 'niciunul' })" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------
Write-Host "`n5. Configuratia containerului" -ForegroundColor Cyan
# ---------------------------------------------------------------

$running = $false
try {
    $state = docker inspect -f '{{.State.Running}}' agent-local-webui 2>$null
    if ($LASTEXITCODE -eq 0 -and $state -eq 'true') { $running = $true }
} catch { }

if ($running) {
    $env_ = docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' agent-local-webui 2>$null
    $expected = @{
        'WEBUI_AUTH'           = 'False'
        'ENABLE_OPENAI_API'    = 'False'
        'ANONYMIZED_TELEMETRY' = 'False'
        'DO_NOT_TRACK'         = 'True'
        'OFFLINE_MODE'         = 'True'
        'ENABLE_WEB_SEARCH'    = 'False'
    }
    foreach ($k in $expected.Keys | Sort-Object) {
        $line = $env_ | Where-Object { $_ -like "$k=*" }
        $val = if ($line) { ($line -split '=', 2)[1] } else { '<lipsa>' }
        Test-Result "$k = $($expected[$k])" ($val -eq $expected[$k]) $(if ($val -ne $expected[$k]) { "gasit: $val" })
    }
} else {
    Test-Result "Container agent-local-webui ruleaza" $false "opreste-te aici si porneste cu .\start.ps1" -WarnOnly
}

# ---------------------------------------------------------------
Write-Host "`n6. Sincronizare cloud a folderului de lucru" -ForegroundColor Cyan
# ---------------------------------------------------------------

$here = $PSScriptRoot
$inOneDrive = $env:OneDrive -and $here.StartsWith($env:OneDrive, 'OrdinalIgnoreCase')
Test-Result "Folderul proiectului nu e sub OneDrive" (-not $inOneDrive) $here

# ---------------------------------------------------------------
Write-Host "`n============================================" -ForegroundColor White
if ($script:fail -eq 0 -and $script:warn -eq 0) {
    Write-Host " REZULTAT: toate verificarile trecute." -ForegroundColor Green
} elseif ($script:fail -eq 0) {
    Write-Host " REZULTAT: $($script:warn) avertisment(e), nicio problema grava." -ForegroundColor Yellow
} else {
    Write-Host " REZULTAT: $($script:fail) PROBLEMA(E), $($script:warn) avertisment(e)." -ForegroundColor Red
}
Write-Host "============================================`n" -ForegroundColor White

Write-Host " Testul decisiv nu poate fi automatizat:" -ForegroundColor White
Write-Host "   Opreste Wi-Fi/Ethernet, pune o intrebare in chat, vezi ca raspunde." -ForegroundColor Gray
Write-Host "   Daca merge fara internet, nu exista dependenta de cloud.`n" -ForegroundColor Gray
