#!/usr/bin/env bash
# =============================================================================
# TradingAgents — Proxmox LXC Installer (Community-Scripts-Stil)
#
# Einzeiler (auf dem Proxmox-HOST als root ausführen):
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/TradingAgent/main/install/tradingagents.sh)"
#
# Was passiert:
#   1. Fragt CT-ID, Hostname, CPU/RAM/Disk, Storage, Netzwerk, Web-Port ab
#   2. Erstellt einen Debian-12-LXC (onboot=1), startet ihn
#   3. Schiebt Wrapper-Dateien (webui/, systemd/, setup) in den Container
#   4. Installiert dort TradingAgents + Web UI als systemd-Service
#   5. Verifiziert Service + HTTP und gibt die finale URL aus
#
# Belegte CT-ID -> automatisch nächste freie nehmen (LXC *und* VM werden geprüft).
# Debugging:  DEBUG=1 bash -x install/tradingagents.sh   (volles Trace-Log)
# =============================================================================
set -euo pipefail

# ============================ VARIABLEN (oben) ================================
APP="tradingagents"
GITHUB_USER="${GITHUB_USER:-HatchetMan111}"
GITHUB_REPO="${GITHUB_REPO:-TradingAgent}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"
TARBALL="https://github.com/${GITHUB_USER}/${GITHUB_REPO}/archive/refs/heads/${GITHUB_BRANCH}.tar.gz"

DEFAULT_CTID="${DEFAULT_CTID:-150}"
DEFAULT_HOSTNAME="${DEFAULT_HOSTNAME:-tradingagents}"
DEFAULT_CORES="${DEFAULT_CORES:-2}"
DEFAULT_MEMORY="${DEFAULT_MEMORY:-2048}"     # MB
DEFAULT_DISK="${DEFAULT_DISK:-8}"            # GB
DEFAULT_STORAGE="${DEFAULT_STORAGE:-local-lvm}"
DEFAULT_TEMPLATE_STORAGE="${DEFAULT_TEMPLATE_STORAGE:-local}"
DEFAULT_BRIDGE="${DEFAULT_BRIDGE:-vmbr0}"
DEFAULT_WEB_PORT="${DEFAULT_WEB_PORT:-8080}"
DEBIAN_TEMPLATE_PATTERN="debian-12-standard.*amd64.tar.zst"

# ========================= FEHLERKETTE (voll, nie 1 Zeile) =====================
fail() {
  local code=$?
  echo "==================================================================" >&2
  echo "[FATAL] Installation fehlgeschlagen (Exit-Code: ${code})" >&2
  echo "Befehl : ${BASH_COMMAND}" >&2
  echo "Zeile  : ${BASH_LINENO[0]:-?}" >&2
  echo "--- Funktions-Stack ---" >&2
  local i
  for ((i=0; i<${#FUNCNAME[@]}; i++)); do
    echo "  #${i} ${FUNCNAME[$i]:-main} @ ${BASH_SOURCE[$i]}:${BASH_LINENO[$i]:-?}" >&2
  done
  echo "--- Letzte pct/journal-Auszüge (falls vorhanden) ---" >&2
  pct status "${CTID:-?}" 2>&1 | tail -n 20 >&2 || true
  echo "Tipp: Re-Run mit Trace: DEBUG=1 bash -x $0" >&2
  echo "==================================================================" >&2
  exit "${code}"
}
trap fail ERR
[[ "${DEBUG:-0}" == "1" ]] && set -x

# ================================ CHECKS ======================================
[[ "$(id -u)" == "0" ]] || { echo "Bitte als root auf dem Proxmox-Host ausführen." >&2; exit 1; }
command -v pct >/dev/null || { echo "pct nicht gefunden — kein Proxmox-Host?" >&2; exit 1; }
command -v pveam >/dev/null || { echo "pveam nicht gefunden — kein Proxmox-Host?" >&2; exit 1; }

ask() { # ask VAR "Prompt" "Default"
  local __var=$1 prompt=$2 def=$3 val
  if command -v whiptail >/dev/null; then
    val=$(whiptail --inputbox "${prompt}" 8 70 "${def}" 3>&1 1>&2 2>&3) || val="${def}"
  else
    read -rp "${prompt} [${def}]: " val; val="${val:-$def}"
  fi
  printf -v "${__var}" '%s' "${val}"
}

echo "=== ${APP} LXC-Installer (Proxmox VE Community-Scripts-Stil) ==="
ask CTID        "Container-ID (CT-ID)"            "${DEFAULT_CTID}"
ask HOSTNAME    "Hostname"                        "${DEFAULT_HOSTNAME}"
ask CORES       "vCPU-Kerne"                      "${DEFAULT_CORES}"
ask MEMORY      "RAM in MB"                       "${DEFAULT_MEMORY}"
ask DISK        "Disk in GB"                      "${DEFAULT_DISK}"
ask STORAGE     "Storage für Disk (z. B. local-lvm)" "${DEFAULT_STORAGE}"
ask TPL_STORAGE "Storage für Templates"           "${DEFAULT_TEMPLATE_STORAGE}"
ask BRIDGE      "Netzwerk-Bridge"                 "${DEFAULT_BRIDGE}"
ask WEB_PORT    "Web-UI-Port"                     "${DEFAULT_WEB_PORT}"

# --- CT-ID: belegt? -> automatisch nächste freie nehmen -------------------------
# Eingabe säubern (Leerzeichen/CR entfernen — passiert bei Copy&Paste),
# leer -> Default.
CTID="$(printf '%s' "${CTID:-}" | tr -d '[:space:]')"
[[ -z "${CTID}" ]] && CTID="${DEFAULT_CTID}"
if ! [[ "${CTID}" =~ ^[0-9]+$ ]]; then
  echo "Ungültige CT-ID: '${CTID}' (nur Zahlen erlaubt)." >&2; exit 1
fi
# 10er-Basis erzwingen (führende Nullen würden sonst als Oktal gerechnet)
CTID=$((10#${CTID}))
if [[ "${CTID}" -lt 100 ]]; then
  echo "Ungültige CT-ID: ${CTID} (Proxmox-IDs beginnen bei 100)." >&2; exit 1
fi

id_taken() { # Rückgabe 0 = belegt — prüft LXC *und* QEMU-VMs.
  # pct status allein reicht NICHT: es sieht nur Container, keine VMs!
  local id=$1
  [[ -f "/etc/pve/lxc/${id}.conf" || -f "/etc/pve/qemu-server/${id}.conf" ]] && return 0
  pct status "${id}" >/dev/null 2>&1 && return 0
  if command -v qm >/dev/null 2>&1; then
    qm status "${id}" >/dev/null 2>&1 && return 0
  fi
  return 1
}

ORIG_CTID="${CTID}"
while id_taken "${CTID}"; do
  CTID=$((CTID + 1))
  if [[ "${CTID}" -gt 999999 ]]; then
    echo "Keine freie CT-ID gefunden." >&2; exit 1
  fi
done
if [[ "${CTID}" != "${ORIG_CTID}" ]]; then
  echo "CT-ID ${ORIG_CTID} belegt -> nehme nächste freie: ${CTID}"
  HOSTNAME="${HOSTNAME}-${CTID}"
  echo "Hostname angepasst (Duplikate vermeiden): ${HOSTNAME}"
fi

# --- Template sicherstellen ----------------------------------------------------
echo "-> Suche Debian-12-Template in ${TPL_STORAGE} ..."
TEMPLATE="$(pveam list "${TPL_STORAGE}" 2>/dev/null | grep -oE "${DEBIAN_TEMPLATE_PATTERN}" | sort -V | tail -n 1 || true)"
if [[ -z "${TEMPLATE:-}" ]]; then
  echo "-> Kein Template gefunden, lade aktuelles (pveam update + download) ..."
  pveam update
  TEMPLATE="$(pveam available 2>/dev/null | grep -oE "${DEBIAN_TEMPLATE_PATTERN}" | sort -V | tail -n 1)"
  [[ -n "${TEMPLATE}" ]] || { echo "Kein Debian-12-Template verfügbar." >&2; exit 1; }
  pveam download "${TPL_STORAGE}" "${TEMPLATE}"
fi
echo "-> Template: ${TEMPLATE}"

# --- Container erstellen ----------------------------------------------------------
echo "-> Erstelle LXC ${CTID} (${CORES} CPU / ${MEMORY} MB / ${DISK} GB) ..."
pct create "${CTID}" "${TPL_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "${HOSTNAME}" \
  --cores "${CORES}" --memory "${MEMORY}" \
  --rootfs "${STORAGE}:${DISK}" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp" \
  --onboot 1 --start 1 \
  --unprivileged 1 \
  --features nesting=1
# onboot doppelt absichern (Config-Key)
grep -q "^onboot:" "/etc/pve/lxc/${CTID}.conf" \
  || echo "onboot: 1" >> "/etc/pve/lxc/${CTID}.conf"
echo "-> Warte auf Container-Boot ..."
sleep 8

pct exec "${CTID}" -- bash -c "echo Container erreichbar: \$(hostname) \$(hostname -I | awk '{print \$1}')"

# --- Wrapper-Dateien in den Container schieben ----------------------------------
WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "${WORKDIR}"; }
trap 'cleanup; fail' ERR
echo "-> Lade Wrapper-Repo (${GITHUB_USER}/${GITHUB_REPO}@${GITHUB_BRANCH}) ..."
if command -v git >/dev/null; then
  git clone --depth 1 --branch "${GITHUB_BRANCH}" \
    "https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git" "${WORKDIR}/repo"
else
  cd "${WORKDIR}" && wget -qO repo.tar.gz "${TARBALL}" && tar xzf repo.tar.gz
  mv "${WORKDIR}/${GITHUB_REPO}-${GITHUB_BRANCH}" "${WORKDIR}/repo"
fi

echo "-> Push nach CT:${CTID} ..."
# WICHTIG: pct push kann nur DATEIEN übertragen, keine Ordner!
# (Ein Ordner-Push erzeugt eine Datei statt Verzeichnis -> "Not a directory".)
# Darum: alles als Tarball pushen und im Container entpacken.
tar -czf "${WORKDIR}/wrapper.tar.gz" -C "${WORKDIR}/repo" webui systemd install/setup-container.sh
pct push "${CTID}" "${WORKDIR}/wrapper.tar.gz" /opt/tradingagents/wrapper.tar.gz
pct exec "${CTID}" -- tar -xzf /opt/tradingagents/wrapper.tar.gz -C /opt/tradingagents
pct exec "${CTID}" -- chmod +x /opt/tradingagents/install/setup-container.sh
pct exec "${CTID}" -- test -f /opt/tradingagents/webui/requirements-web.txt \
  || { echo "Wrapper-Tarball unvollständig im Container angekommen." >&2; exit 1; }

# --- Setup IM Container ausführen ------------------------------------------------
echo "-> Führe Setup im Container aus (dauert einige Minuten) ..."
pct exec "${CTID}" -- env WEB_PORT="${WEB_PORT}" DEBUG="${DEBUG:-0}" \
  bash /opt/tradingagents/install/setup-container.sh

# --- Verifikation vom Host -------------------------------------------------------
echo "-> Verifikation ..."
pct exec "${CTID}" -- systemctl is-active --quiet tradingagents-web \
  || { echo "Service läuft NICHT. Log:" >&2
       pct exec "${CTID}" -- journalctl -u tradingagents-web --no-pager -n 100 >&2
       exit 1; }
CT_IP="$(pct exec "${CTID}" -- hostname -I | awk '{print $1}')"
echo "-> HTTP-Check http://${CT_IP}:${WEB_PORT}/healthz ..."
curl -fsS "http://${CT_IP}:${WEB_PORT}/healthz" || {
  echo "HTTP-Check fehlgeschlagen." >&2
  pct exec "${CTID}" -- journalctl -u tradingagents-web --no-pager -n 100 >&2
  exit 1
}
cleanup
trap fail ERR

echo "=================================================================="
echo " ✅ Fertig! TradingAgents Web UI: http://${CT_IP}:${WEB_PORT}"
echo "    CT-ID ${CTID} (${HOSTNAME}), onboot=1, Service=tradingagents-web"
echo "    Update : pct exec ${CTID} -- bash /opt/tradingagents/install/setup-container.sh"
echo "    Logs   : pct exec ${CTID} -- journalctl -u tradingagents-web -f"
echo "    Löschen: pct stop ${CTID} && pct destroy ${CTID}"
echo "=================================================================="
