#!/usr/bin/env bash
# =============================================================================
# TradingAgents — Container-Setup (läuft IM LXC, Debian 12, als root)
# Wird vom Host-Installer per pct push + pct exec aufgerufen oder manuell:
#   curl -fsSL https://raw.githubusercontent.com/HatchetMan111/TradingAgent/main/install/setup-container.sh | bash
# Idempotent: kann mehrfach laufen (venv wiederverwenden, Pakete updaten).
# Debugging: DEBUG=1 bash -x setup-container.sh  -> volles Trace-Log
# =============================================================================
set -euo pipefail

# --- Variablen (oben, Community-Scripts-Stil) ---------------------------------
APP="tradingagents"
BASE_DIR="/opt/tradingagents"
SRC_DIR="${BASE_DIR}/src/TradingAgents"
WEBUI_SRC_DIR="${BASE_DIR}/webui"          # kommt per Wrapper-Tarball vom Host
VENV_DIR="${BASE_DIR}/venv"
WEB_PORT="${WEB_PORT:-8080}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
UPSTREAM_REPO="https://github.com/TauricResearch/TradingAgents.git"
SERVICE_NAME="tradingagents-web"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# --- Fehlerkette: immer VOLL ausgeben, nie nur letzte Zeile -------------------
fail() {
  local code=$?
  echo "==================================================================" >&2
  echo "[FATAL] Setup fehlgeschlagen (Exit-Code: ${code})" >&2
  echo "--- Befehl / Kontext ---" >&2
  echo "Befehl : ${BASH_COMMAND}" >&2
  echo "Zeile  : ${BASH_LINENO[0]:-?} in ${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}" >&2
  echo "--- Stacktrace ---" >&2
  local i
  for ((i=0; i<${#FUNCNAME[@]}; i++)); do
    echo "  #${i} ${FUNCNAME[$i]:-main} @ ${BASH_SOURCE[$i]}:${BASH_LINENO[$i]:-?}" >&2
  done
  echo "--- Relevante Logs ---" >&2
  journalctl -u "${SERVICE_NAME}" --no-pager -n 50 2>&1 | tail -n 50 >&2 || true
  echo "Tipp: Re-Run mit Debug-Trace: DEBUG=1 bash -x $0" >&2
  echo "==================================================================" >&2
  exit "${code}"
}
trap fail ERR

if [[ "${DEBUG:-0}" == "1" ]]; then set -x; fi

echo "[1/7] Systempakete ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  "${PYTHON_BIN}" "${PYTHON_BIN}-venv" "${PYTHON_BIN}-dev" \
  git curl ca-certificates build-essential

echo "[2/7] Verzeichnisse ..."
mkdir -p "${BASE_DIR}" "${SRC_DIR%/*}"

echo "[3/7] Upstream TradingAgents klonen/aktualisieren ..."
if [[ -d "${SRC_DIR}/.git" ]]; then
  git -C "${SRC_DIR}" fetch --all --prune
  git -C "${SRC_DIR}" pull --ff-only || git -C "${SRC_DIR}" reset --hard origin/main
else
  rm -rf "${SRC_DIR}"
  git clone --depth 1 "${UPSTREAM_REPO}" "${SRC_DIR}"
fi

echo "[4/7] venv + Abhängigkeiten (idempotent) ..."
if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  "${PYTHON_BIN}" -m venv "${VENV_DIR}"
fi
"${VENV_DIR}/bin/pip" install --upgrade pip wheel
"${VENV_DIR}/bin/pip" install "${SRC_DIR}"
"${VENV_DIR}/bin/pip" install -r "${WEBUI_SRC_DIR}/requirements-web.txt"
"${VENV_DIR}/bin/python" -c "import tradingagents; print('framework import OK:', tradingagents.__file__)"
"${VENV_DIR}/bin/python" -c "import fastapi, uvicorn; print('webui deps OK')"

echo "[5/7] .env + systemd-Unit ..."
touch "${BASE_DIR}/.env"
chmod 600 "${BASE_DIR}/.env"
# Service-Unit aus Wrapper-Repo übernehmen (kommt per Tarball nach
# /opt/tradingagents/systemd/). Fehlt sie, laut abbrechen statt schweigend
# eine veraltete Unit weiterzuverwenden.
SERVICE_SRC=""
for cand in "${BASE_DIR}/systemd/tradingagents-web.service" \
            "${BASE_DIR}/repo-files/systemd/tradingagents-web.service" \
            "./systemd/tradingagents-web.service"; do
  if [[ -f "${cand}" ]]; then SERVICE_SRC="${cand}"; break; fi
done
if [[ -z "${SERVICE_SRC}" ]]; then
  echo "Service-Unit nicht gefunden (gesucht in ${BASE_DIR}/systemd/, repo-files/, ./systemd/)." >&2
  echo "Wrapper-Tarball unvollständig übertragen?" >&2
  exit 1
fi
cp "${SERVICE_SRC}" "${SERVICE_FILE}"
echo "  - Service-Unit von: ${SERVICE_SRC}"
# Port im Service sicherstellen (neutral gegenüber Template-Abweichungen)
if grep -q -- "--port" "${SERVICE_FILE}"; then
  sed -i -E "s/--port [0-9]+/--port ${WEB_PORT}/" "${SERVICE_FILE}"
fi
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
systemctl restart "${SERVICE_NAME}"

echo "[6/7] Verifikation ..."
sleep 3
echo "  - Service: $(systemctl is-active "${SERVICE_NAME}")"
systemctl is-active --quiet "${SERVICE_NAME}" || {
  echo "Service läuft NICHT. Journal:" >&2
  journalctl -u "${SERVICE_NAME}" --no-pager -n 100 >&2
  exit 1
}
echo "  - HTTP-Check auf localhost:${WEB_PORT} ..."
for i in $(seq 1 15); do
  if curl -fsS "http://127.0.0.1:${WEB_PORT}/healthz" 2>&1; then
    echo; echo "  - Web UI antwortet."
    break
  fi
  if [[ "$i" == "15" ]]; then
    echo "Web UI antwortet NICHT nach 15 Versuchen. Journal:" >&2
    journalctl -u "${SERVICE_NAME}" --no-pager -n 100 >&2
    curl -v "http://127.0.0.1:${WEB_PORT}/healthz" >&2 || true
    exit 1
  fi
  sleep 2
done

CT_IP="$(hostname -I | awk '{print $1}')"
echo "[7/7] Fertig."
echo "=================================================================="
echo " TradingAgents Web UI: http://${CT_IP}:${WEB_PORT}"
echo " Service: systemctl status ${SERVICE_NAME}"
echo " Logs   : journalctl -u ${SERVICE_NAME} -f"
echo " API-Keys & Provider in der Web UI eintragen (Schritt 1), dann analysieren."
echo " Reboot-Test: pct reboot <CTID> && nach Neustart URL erneut öffnen."
echo "=================================================================="
