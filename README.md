# TradingAgents — Proxmox LXC Installer + Web UI

Lokale TradingAgents-Installation als **LXC-Container auf Proxmox VE** im Stil der
[Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE/):
**Einzeiler auf dem Host → Container + App + Web UI + systemd läuft.**

> Upstream: [TauricResearch/TradingAgents](https://github.com/TauricResearch/TradingAgents)
> (Multi-Agents LLM Financial Trading Framework, Python).
> Upstream hat **keine** Web UI — dieses Repo legt einen schlanken
> **FastAPI-Wrapper** (`webui/`) darüber, in dem man alles einstellen kann
> (Ticker, Datum, Provider, Modelle, Runden, API-Keys) und Analysen startet.

| Feld | Wert |
|---|---|
| App-Name | `tradingagents` |
| Zweck | Multi-Agent-LLM-Trading-Analysen lokal im LXC, Bedienung per Web UI |
| Tech-Stack | Python 3 / FastAPI + Uvicorn (Wrapper), Upstream: LangGraph/LangChain |
| Upstream-Repo | https://github.com/TauricResearch/TradingAgents |
| Web-UI-Port | `8080` (konfigurierbar) |
| Default-Ressourcen | 2 vCPU · 2048 MB RAM · 8 GB Disk · Debian 12 LXC, `onboot: 1` |

## 1 · Installation (Einzeiler auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/TradingAgent/main/install/tradingagents.sh)"
```

Das Script fragt interaktiv ab (mit sinnvollen Defaults):
`CT-ID` (150) · Hostname · vCPU (2) · RAM (2048) · Disk (8G) ·
Storage (`local-lvm`) · Bridge (`vmbr0`, DHCP) · Web-Port (8080).

Danach läuft vollautomatisch:
1. Debian-12-Template sicherstellen (`pveam download` falls nötig)
2. `pct create` + `onboot: 1` + Start
3. Wrapper-Dateien per `pct push` in den Container
4. `install/setup-container.sh` im Container: Python-venv, Upstream-Clone,
   `pip install`, Web-UI-Deps, systemd-Unit `tradingagents-web.service`
   (`enable`, `Restart=always`, `After=network-online.target`)
5. Selbst-Verifikation: `systemctl is-active` + HTTP-Check auf
   `localhost:8080/healthz`

**Erwartete Ausgabe (Ende):**

```text
[6/7] Verifikation ...
  - Service: active
  - HTTP-Check auf localhost:8080 ...
{"status":"ok","framework":true,"framework_detail":"ok"}
  - Web UI antwortet.
[7/7] Fertig.
==================================================================
 TradingAgents Web UI: http://192.168.1.50:8080
 ...
==================================================================
 ✅ Fertig! TradingAgents Web UI: http://192.168.1.50:8080
    CT-ID 150 (tradingagents), onboot=1, Service=tradingagents-web
```

Web UI öffnen → **Schritt 1**: Provider + API-Key eintragen → **Schritt 2**:
Ticker/Datum wählen → Analyse starten → Live-Log + Ergebnis + Reports.

## 2 · Update / mehrere Instanzen

Jeder Installer-Lauf erstellt einen **neuen** Container: ist die gewünschte
CT-ID belegt, wird automatisch die nächste freie genommen (der Hostname wird
dann mit `-<CTID>` suffixiert, um Duplikate zu vermeiden).
Für ein Update im **bestehenden** Container:

```bash
pct push 150 install/setup-container.sh /opt/tradingagents/setup-container.sh
pct exec 150 -- bash /opt/tradingagents/setup-container.sh
```

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/TradingAgent/main/install/tradingagents.sh)"
# -> "CT 150 existiert. Setup erneut ausführen (Update)?" -> Ja
```

## 3 · Deinstallation

```bash
pct stop 150 && pct destroy 150
```

## 4 · Reboot-Test (Nachweis Reboot-Sicherheit)

```bash
pct reboot 150
sleep 20
pct exec 150 -- systemctl is-active tradingagents-web   # -> active
curl -fsS http://<LXC-IP>:8080/healthz                  # -> {"status":"ok",...}
# Web UI im Browser neu laden -> wieder erreichbar
```

Container startet durch `onboot: 1` nach Host-Reboot automatisch;
die Web UI durch `systemctl enable` + `Restart=always`.

## 5 · Debugging (volle Fehlerkette)

- Installer mit Trace: `DEBUG=1 bash -x install/tradingagents.sh`
- Setup im Container: `DEBUG=1 bash -x /opt/tradingagents/setup-container.sh`
- Service-Logs: `pct exec 150 -- journalctl -u tradingagents-web -f`
- Analyse-Fehler: Web UI zeigt **vollen Stacktrace** im Live-Log
  (Exception-Chain, kein Abschneiden) + `/api/status/<job>` als JSON.

## 6 · Repo-Struktur

```text
install/tradingagents.sh      Host-Installer (Einzeiler, Community-Scripts-Stil)
install/setup-container.sh    Setup IM Container (idempotent, set -euo pipefail)
webui/app.py                  FastAPI-Wrapper (Config, Analyse-Jobs, Reports)
webui/templates/index.html    Web UI (3 Schritte: Config → Analyse → Log/Reports)
webui/requirements-web.txt    fastapi + uvicorn + pydantic
systemd/tradingagents-web.service  systemd-Unit (enable, Restart=always)
.env.example                  Beispiel-Keys/Defaults
```

## 7 · Hinweise

- **LXC vs. VM:** Standard ist LXC (leicht, ideal für Remote-LLM-APIs wie
  OpenAI/Anthropic/Google). Nur wer **lokale** Modelle (Ollama/vLLM) mit
  großem RAM/GPU will, sollte stattdessen eine VM mit mehr Ressourcen nehmen —
  das Setup-Script läuft dort unverändert (Debian 12 vorausgesetzt).
- **Keine Anlageberatung:** Upstream ist ein Research-Framework; Ergebnisse
  sind nicht-deterministisch (LLM-Sampling + Live-Daten). Siehe Upstream-README.
