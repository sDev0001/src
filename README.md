# Agent local pentru analiză de loguri private

Chat cu un model de limbaj care rulează **integral pe această mașină**. Niciun cont,
niciun API extern, nicio telemetrie. Destinat analizei de loguri care nu au voie să
părăsească laptopul.

## Pornire / oprire

```powershell
.\start.ps1
```

Pornește Docker Desktop dacă e nevoie, ridică interfața și deschide browserul pe
<http://127.0.0.1:3000>. Prima pornire durează mai mult (containerul își inițializează
baza de date).

```powershell
.\stop.ps1
```

Oprește interfața și descarcă modelul din memorie. Conversațiile se păstrează.

```powershell
.\verifica-privacy.ps1
```

Audit de izolare — porturi, reguli de firewall, conexiuni active, configurația
containerului. Nu modifică nimic. Rulează-l înainte de a lucra cu date sensibile.

## Ce rulează unde

| Componentă | Unde | Port | Vizibil din rețea? |
|---|---|---|---|
| Open WebUI (interfața) | container Docker | `127.0.0.1:3000` | nu — doar loopback |
| Ollama (motorul) | serviciu Windows nativ | `0.0.0.0:11434` | nu — blocat de firewall |
| Model `qwen2.5:7b` | în RAM/VRAM, la cerere | — | — |

Ollama e instalat nativ, nu în container, ca să folosească direct CUDA pe GTX 1660 Ti.
În Docker, accesul GPU pe Windows cere WSL2 + nvidia-container-toolkit și e fragil —
diferența practică e ~20 tok/s față de ~5 tok/s.

Consecința: Ollama trebuie să asculte pe `0.0.0.0` ca să fie accesibil din container, nu
doar pe loopback. Compensat de o regulă de firewall care permite inbound pe 11434 **numai**
din subnetul Docker/WSL (`172.16.0.0/12`); restul rețelei cade pe default-deny inbound al
Windows Firewall. `verifica-privacy.ps1` verifică exact asta.

## Aplicația desktop Ollama — de ce NU o folosim

Ollama 0.32.5 nu mai e doar un server; vine cu o aplicație GUI care are **integrare
cloud activată implicit**. Observat direct în logurile de la instalare:

```
"Ollama cloud disabled: false"
OLLAMA_REMOTES:[ollama.com]
POST "/api/me"                              ← apel de identitate către ollama.com
updater.go "beginning update checker" interval=1h0m0s
model_recommendations.go                    ← descarcă recomandări de modele
"Created Startup shortcut"                  ← se autopornește la boot
```

Și, concret: la prima deschidere a interfeței ei, aplicația a pornit singură
descărcarea unui model de **~7 GB** pe care nimeni nu l-a cerut.

Măsurile luate:

| Măsură | Cum |
|---|---|
| Nu rulăm GUI-ul, doar serverul | `start.ps1` lansează `ollama serve`, nu `ollama app.exe` |
| Ruta spre cloud tăiată | `OLLAMA_NO_CLOUD=1` |
| Fără istoric de prompturi pe disc | `OLLAMA_NOHISTORY=1` |
| Fără autostart al GUI-ului | shortcut-ul mutat în `Ollama-autostart-dezactivat.lnk.bak` |

`verifica-privacy.ps1` verifică toate patru. **Un update de Ollama le poate reseta** —
de aceea auditul se rulează din nou după fiecare update.

Ca să restaurezi autostart-ul GUI-ului (nu e recomandat), mută
`Ollama-autostart-dezactivat.lnk.bak` înapoi în
`%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Ollama.lnk`.

## Curățare blob-uri parțiale

Descărcările întrerupte lasă fișiere `-partial` care ocupă spațiu și nu sunt curățate
automat (Ollama șterge doar blob-urile complete nefolosite). Verifică ce e acolo:

```powershell
Get-ChildItem "$env:USERPROFILE\.ollama\models\blobs" -File | Where-Object { $_.Name -like '*partial*' } | Select-Object Name, @{n='MB';e={[math]::Round($_.Length/1MB,0)}}
```

Șterge-le doar când niciun `ollama pull` nu rulează — altfel întrerupi o descărcare în curs.

## Ce a fost dezactivat deliberat

Setările sunt în [docker-compose.yml](docker-compose.yml), fiecare cu motivul alături.

| Setare | Efect |
|---|---|
| `WEBUI_AUTH=False` | fără cont, fără parolă — intri direct în chat |
| `ENABLE_OPENAI_API=False` | altfel Open WebUI interoghează `api.openai.com` pentru lista de modele |
| `OFFLINE_MODE=True` | blochează descărcările runtime de pe HuggingFace |
| `ENABLE_WEB_SEARCH=False` | nicio căutare web declanșată din chat |
| `ENABLE_TAGS_GENERATION=False` | nu trimite fragmente de conversație într-un prompt separat de titrare |
| `ANONYMIZED_TELEMETRY`, `DO_NOT_TRACK`, `SCARF_NO_ANALYTICS` | zero raportare de utilizare |

**Ce pierzi:** atașarea de documente (RAG) nu funcționează cât timp `OFFLINE_MODE=True`,
fiindcă modelul de embedding s-ar descărca la prima utilizare. Dacă e nevoie, se
pre-descarcă deliberat, ca pas conștient — nu accidental la runtime.

## Dovada că datele nu ies

Verificarea automată acoperă configurația. Dovada practică e alta, și nu poate fi
automatizată:

> Oprește Wi-Fi/Ethernet. Pune o întrebare în chat. Răspunsul vine normal.

Un sistem care funcționează fără internet nu are unde să trimită datele.

## De ținut minte

**Conversațiile cu Claude Code (asistentul din terminal) nu sunt locale.** Logurile reale
se pun exclusiv în interfața de la `127.0.0.1:3000`. Dacă ceri ajutor la dezvoltarea
agentului, dă structura și formatul logurilor, nu conținutul lor.

Nu muta acest folder în `C:\Users\sergi\OneDrive` — procesul OneDrive rulează și ar
sincroniza totul. `verifica-privacy.ps1` verifică și asta.

## Unde stau datele

Conversațiile și configurația interfeței sunt în volumul Docker
`agent-local-webui-data`. Modelele sunt în `%USERPROFILE%\.ollama\models`.

Ștergere completă a istoricului de chat:

```powershell
docker compose down -v
```

## Limite ale hardware-ului actual

Ryzen 7 4800H · GTX 1660 Ti 6 GB · 15.4 GB RAM

Măsurat pe această mașină cu qwen2.5:7b Q4_K_M:

| | |
|---|---|
| Viteză generare | **28 tok/s** (52 tok/s cu modelul deja încărcat) |
| Încărcare model | 7.6 s la prima întrebare |
| Repartiție | **79% GPU / 21% CPU**, 4.1 GB din 6 GB VRAM |
| Context | 8192 (`OLLAMA_CONTEXT_LENGTH`) |

- 13-14B ar merge, dar lent — nu merită pe 6 GB VRAM
- la loguri mari, filtrarea se face **în cod** înainte de model, nu turnând tot fișierul
  în prompt: 8192 tokeni sunt ~30 KB de text
- WSL2 e plafonat la 4 GB prin `C:\Users\sergi\.wslconfig`, altfel ar concura cu modelul
  pentru RAM
- generarea automată de titluri/tag-uri/sugestii e dezactivată: fiecare ar fi un apel
  suplimentar la model la fiecare mesaj

Cel mai bun upgrade rămâne RAM la 32 GB, nu GPU.

## Următoarea fază

Tools Python în Open WebUI (Workspace → Tools) prin care modelul citește singur fișiere,
filtrează și agregă. Rulează **în interiorul containerului**, deci folderul cu loguri
trebuie montat read-only în `docker-compose.yml`:

```yaml
volumes:
  - C:\calea\catre\loguri:/data/logs:ro
```

Montarea `:ro` e și plasa de siguranță — agentul nu poate modifica sau șterge probe.
