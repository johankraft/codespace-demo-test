#!/usr/bin/env bash
set -euo pipefail

DISPLAY_NUM="${DISPLAY_NUM:-1}"
GEOMETRY="${GEOMETRY:-1900x900}"
DEPTH="${DEPTH:-24}"
VNC_PORT=$((5900 + DISPLAY_NUM))
NOVNC_PORT="${NOVNC_PORT:-6080}"

STATE_DIR="${HOME}/.local/share/tracealyzer-web"
CONFIG_DIR="${HOME}/.tracealyzer"
DOWNLOAD_DIR="${HOME}/downloads/tracealyzer"
NOVNC_PID_FILE="${STATE_DIR}/novnc.pid"
TZ_INFO_FILE="${CONFIG_DIR}/tracealyzer-path.txt"
LICENSE_FILE="${CONFIG_DIR}/license.txt"
LICENSE_DONE_FILE="${CONFIG_DIR}/license-activated.ok"
VNC_XSTARTUP="${HOME}/.vnc/xstartup"
AUTOSTART_DIR="${HOME}/.config/autostart"
AUTOSTART_FILE="${AUTOSTART_DIR}/tracealyzer.desktop"
SESSION_LAUNCHER="${CONFIG_DIR}/start-tracealyzer-session.sh"

mkdir -p "${STATE_DIR}" "${CONFIG_DIR}" "${DOWNLOAD_DIR}" "${HOME}/.vnc" "${AUTOSTART_DIR}"

log()  { printf "\n[INFO] %s\n" "$*"; }
warn() { printf "\n[WARN] %s\n" "$*" >&2; }
die()  { printf "\n[ERROR] %s\n" "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

ensure_dependencies() {
  need_cmd vncserver
  need_cmd wget
  need_cmd tar
  need_cmd curl
  need_cmd ss
  if ! command -v novnc_proxy >/dev/null 2>&1; then
    [[ -x /usr/share/novnc/utils/novnc_proxy ]] || die "novnc_proxy was not found."
  fi
}

ensure_vnc_password() {
  if [[ ! -f "${HOME}/.vnc/passwd" ]]; then
    log "No VNC password is configured yet."
    echo "Please choose a VNC password for the browser session."
    echo "You will enter this password when noVNC asks for it."
    vncpasswd
  else
    log "A VNC password is already configured."
  fi
}

write_xstartup() {
  cat > "${VNC_XSTARTUP}" <<'XEOF'
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
exec dbus-launch --exit-with-session startxfce4
XEOF
  chmod +x "${VNC_XSTARTUP}"
}

prompt_tz_url() {
  local url=""
  local default_url="https://download.tracealyzer.io/Tracealyzer-4.11.1-linux-standalone-x86-64.tgz"

  echo >&2
  echo "Enter the URL to the Tracealyzer .tgz package." >&2
  echo "Default (press Enter to accept): ${default_url}" >&2
  printf "> " >&2

  IFS= read -r url

  if [[ -z "${url}" ]]; then
    url="${default_url}"
    echo "Using default URL: ${url}" >&2
  fi

  printf '%s\n' "${url}"
}

download_and_unpack_tracealyzer() {
  local url="$1"
  local filename
  local extracted_dir=""
  local tar_output_file="${STATE_DIR}/tar-output.txt"

  filename="$(basename "${url}")"
  [[ "${filename}" == *.tgz ]] || warn "The URL does not end with .tgz, but continuing anyway."

  cd "${DOWNLOAD_DIR}"

  log "Downloading the Tracealyzer package..."
  wget -O "${filename}" "${url}"

  log "Extracting the package..."
  tar xvf "${filename}" | tee "${tar_output_file}"

  extracted_dir="$(awk -F/ 'NF>1 {print $1; exit}' "${tar_output_file}" || true)"
  if [[ -z "${extracted_dir}" ]]; then
    extracted_dir="$(find "${DOWNLOAD_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2- || true)"
  else
    extracted_dir="${DOWNLOAD_DIR}/${extracted_dir}"
  fi

  [[ -n "${extracted_dir}" && -d "${extracted_dir}" ]] || die "Could not locate the extracted Tracealyzer directory."

  echo "${extracted_dir}" > "${TZ_INFO_FILE}"
  log "Tracealyzer was extracted to: ${extracted_dir}"
}

run_cert_sync() {
  local tz_dir="$1"
  if [[ -x "${tz_dir}/cert-sync" ]]; then
    log "Running cert-sync with --user..."
    (
      cd "${tz_dir}"
      ./cert-sync --user cacerts_from_mozilla.pem
    )
  else
    warn "Could not find ${tz_dir}/cert-sync. Skipping cert-sync."
  fi
}

prompt_license_key_if_missing() {
  if [[ -f "${LICENSE_FILE}" && -s "${LICENSE_FILE}" ]]; then
    log "A saved license key was found in ${LICENSE_FILE}."
    return
  fi

  local license_key=""
  echo >&2
  echo "Enter your Tracealyzer license key and press Enter." >&2
  echo "The key will be saved locally in: ${LICENSE_FILE}" >&2
  printf "> " >&2
  IFS= read -r license_key

  [[ -n "${license_key}" ]] || die "No license key was entered."

  printf "%s\n" "${license_key}" > "${LICENSE_FILE}"
  chmod 600 "${LICENSE_FILE}"
  log "The license key was saved."
}

write_session_launcher() {
  local tz_dir="$1"
  [[ -x "${tz_dir}/launch-tz.sh" ]] || die "Could not find ${tz_dir}/launch-tz.sh"

  cat > "${SESSION_LAUNCHER}" <<EOF2
#!/usr/bin/env bash
set -euo pipefail

TZ_DIR="${tz_dir}"
LICENSE_FILE="${LICENSE_FILE}"
LICENSE_DONE_FILE="${LICENSE_DONE_FILE}"

cd "\${TZ_DIR}"

if [[ ! -f "\${LICENSE_DONE_FILE}" ]]; then
  if [[ -f "\${LICENSE_FILE}" && -s "\${LICENSE_FILE}" ]]; then
    LICENSE_KEY="\$(tr -d '\r\n' < "\${LICENSE_FILE}")"
    if [[ -n "\${LICENSE_KEY}" ]]; then
      ./launch-tz.sh /license -k "\${LICENSE_KEY}" || true
      touch "\${LICENSE_DONE_FILE}"
    fi
  fi
fi

exec ./launch-tz.sh
EOF2
  chmod +x "${SESSION_LAUNCHER}"
  log "Created the session launcher script."
}

write_tracealyzer_autostart() {
  cat > "${AUTOSTART_FILE}" <<EOF2
[Desktop Entry]
Type=Application
Version=1.0
Name=Tracealyzer
Comment=Start Tracealyzer automatically in the VNC session
Exec=${SESSION_LAUNCHER}
Terminal=false
X-GNOME-Autostart-enabled=true
StartupNotify=false
EOF2
  log "Configured Tracealyzer to start automatically with the XFCE session."
}

wait_for_port() {
  local port="$1"
  local timeout="${2:-15}"
  local i
  for ((i=1; i<=timeout; i++)); do
    if ss -tln | awk '{print $4}' | grep -Eq "(^|:)$port$"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

stop_old_vnc() {
  log "Stopping any existing VNC session on :${DISPLAY_NUM}..."
  vncserver -kill ":${DISPLAY_NUM}" >/dev/null 2>&1 || true
  pkill -f "Xtightvnc.*:${DISPLAY_NUM}" >/dev/null 2>&1 || true
  sleep 1
}

stop_old_novnc() {
  log "Stopping any existing noVNC/websockify process on port ${NOVNC_PORT}..."
  if [[ -f "${NOVNC_PID_FILE}" ]]; then
    local oldpid
    oldpid="$(cat "${NOVNC_PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${oldpid}" ]] && kill -0 "${oldpid}" 2>/dev/null; then
      kill "${oldpid}" >/dev/null 2>&1 || true
      sleep 1
    fi
    rm -f "${NOVNC_PID_FILE}"
  fi
  pkill -f "novnc_proxy.*${NOVNC_PORT}" >/dev/null 2>&1 || true
  pkill -f "websockify.*${NOVNC_PORT}" >/dev/null 2>&1 || true
  sleep 1
}

start_vnc() {
  log "Starting VNC server on :${DISPLAY_NUM} (${GEOMETRY}, depth ${DEPTH})..."
  vncserver ":${DISPLAY_NUM}" -geometry "${GEOMETRY}" -depth "${DEPTH}"
  if wait_for_port "${VNC_PORT}" 15; then
    log "VNC server is listening on port ${VNC_PORT}."
  else
    die "VNC server did not start correctly on port ${VNC_PORT}."
  fi
}

start_novnc() {
  local novnc_bin
  if command -v novnc_proxy >/dev/null 2>&1; then
    novnc_bin="$(command -v novnc_proxy)"
  else
    novnc_bin="/usr/share/novnc/utils/novnc_proxy"
  fi

  log "Starting noVNC on port ${NOVNC_PORT}..."
  nohup "${novnc_bin}" --vnc "localhost:${VNC_PORT}" --listen "0.0.0.0:${NOVNC_PORT}" > "${STATE_DIR}/novnc.log" 2>&1 &
  echo $! > "${NOVNC_PID_FILE}"
  sleep 2

  if [[ ! -f "${NOVNC_PID_FILE}" ]] || ! kill -0 "$(cat "${NOVNC_PID_FILE}")" 2>/dev/null; then
    warn "noVNC process appears to have exited early."
    warn "See log: ${STATE_DIR}/novnc.log"
    return 1
  fi

  if wait_for_port "${NOVNC_PORT}" 15; then
    log "noVNC is listening on port ${NOVNC_PORT}."
  else
    warn "noVNC process started, but port ${NOVNC_PORT} did not become ready."
    warn "See log: ${STATE_DIR}/novnc.log"
    return 1
  fi

  return 0
}

ensure_novnc_ready() {
  if start_novnc; then
    return 0
  fi
  warn "Retrying noVNC startup once..."
  stop_old_novnc
  sleep 1
  if start_novnc; then
    return 0
  fi
  die "noVNC web interface did not come up on port ${NOVNC_PORT}."
}

print_instructions() {
  local tz_dir="$1"
  local guessed_base=""
  local full_url=""
  local lite_url=""

  if [[ -n "${CODESPACE_NAME:-}" && -n "${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-}" ]]; then
    guessed_base="https://${CODESPACE_NAME}-${NOVNC_PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
    full_url="${guessed_base}/vnc.html"
    lite_url="${guessed_base}/vnc_lite.html"
  fi

  cat <<EOF2

============================================================
Tracealyzer browser session is ready
============================================================

Configured components:
  - Tracealyzer directory: ${tz_dir}
  - License file: ${LICENSE_FILE}
  - XFCE + VNC + noVNC
  - VNC port: ${VNC_PORT}
  - Web interface port: ${NOVNC_PORT}
  - Tracealyzer will start automatically with the desktop session

How to connect:
  1. Open the PORTS tab in GitHub Codespaces
  2. Find port ${NOVNC_PORT}
  3. Open the URL for that port in your browser
  4. If you land on a directory listing, open:
       /vnc.html
     or:
       /vnc_lite.html
  5. Enter the VNC password you chose earlier

What happens on first launch:
  - Tracealyzer starts inside the VNC/XFCE session
  - License activation is attempted there, inside the desktop session
  - If the activation path shows a dialog, it should now have a display available

EOF2

  if [[ -n "${guessed_base}" ]]; then
    cat <<EOF2
Likely direct URL:
  ${full_url}

Lightweight client:
  ${lite_url}

EOF2
  else
    cat <<EOF2
The exact published URL could not be determined automatically.
Please open port ${NOVNC_PORT} from the PORTS tab.

EOF2
  fi

  cat <<EOF2
Notes:
  - This script always restarts the VNC server and the noVNC web interface when run.
  - noVNC log file: ${STATE_DIR}/novnc.log

To stop everything:
  vncserver -kill :${DISPLAY_NUM}
  kill \$(cat "${NOVNC_PID_FILE}" 2>/dev/null) 2>/dev/null || true

EOF2
}

main() {
  local tz_dir=""
  local tz_url=""

  ensure_dependencies
  ensure_vnc_password
  write_xstartup

  if [[ -f "${TZ_INFO_FILE}" && -s "${TZ_INFO_FILE}" ]]; then
    tz_dir="$(cat "${TZ_INFO_FILE}")"
    if [[ -d "${tz_dir}" ]]; then
      log "Found an existing Tracealyzer installation: ${tz_dir}"
    else
      warn "The saved Tracealyzer path no longer exists. A new download is required."
      tz_url="$(prompt_tz_url)"
      download_and_unpack_tracealyzer "${tz_url}"
      tz_dir="$(cat "${TZ_INFO_FILE}")"
      run_cert_sync "${tz_dir}"
      rm -f "${LICENSE_DONE_FILE}"
    fi
  else
    tz_url="$(prompt_tz_url)"
    download_and_unpack_tracealyzer "${tz_url}"
    tz_dir="$(cat "${TZ_INFO_FILE}")"
    run_cert_sync "${tz_dir}"
    rm -f "${LICENSE_DONE_FILE}"
  fi

  prompt_license_key_if_missing
  write_session_launcher "${tz_dir}"
  write_tracealyzer_autostart

  stop_old_vnc
  stop_old_novnc
  start_vnc
  ensure_novnc_ready
  print_instructions "${tz_dir}"
}

main "$@"
