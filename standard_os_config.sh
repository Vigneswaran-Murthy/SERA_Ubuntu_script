
#!/bin/bash
set -euo pipefail

# === Paths & filenames (master) ===
BASE_DIR="/data/automation/os_config/ubuntu_os_config"
SERVERS_FILE="${BASE_DIR}/servers.txt"
SCRIPT_NAME="ubuntu_os_config.sh"
LOGFILE="${BASE_DIR}/provisioning.log"
OUTPUT_DIR="${BASE_DIR}/ubuntu_output"

mkdir -p "$BASE_DIR" "$OUTPUT_DIR"
touch "$LOGFILE"

# === Initialize provisioning log ===
echo "Provisioning started at $(date)" > "$LOGFILE"
echo "----------------------------------------" >> "$LOGFILE"

# Root check (logged)
if [[ $EUID -ne 0 ]]; then
  echo "***** Please run this script as root to change the system time zone *****" | tee -a "$LOGFILE"
  exit 1
fi
echo "[MASTER] Running as root user — OK" | tee -a "$LOGFILE"

# Helper: write task status in master for a host
log_task_master() {
  local HOST="$1"
  local TASK_NAME="$2"
  local STATUS="$3"
  local HOST_DIR="${OUTPUT_DIR}/${HOST}"
  mkdir -p "$HOST_DIR"
  echo -e "${TASK_NAME}\t${STATUS}" >> "${HOST_DIR}/status.txt"
}

# Validate servers file exists
if [[ ! -f "$SERVERS_FILE" ]]; then
  echo "[MASTER] Servers file not found: $SERVERS_FILE" | tee -a "$LOGFILE"
  exit 1
fi

echo "[MASTER] Provisioning started at $(date)" | tee -a "$LOGFILE"
echo "----------------------------------------" >> "$LOGFILE"

# Iterate through servers (skip blank lines and comments)
while IFS= read -r RAW_HOST || [[ -n "$RAW_HOST" ]]; do
  HOST="$(echo "$RAW_HOST" | awk '{$1=$1;print}')"
  [[ -z "$HOST" || "$HOST" =~ ^# ]] && continue

  echo "[MASTER] === [$HOST] Starting provisioning... ===" | tee -a "$LOGFILE"
  HOST_DIR="${OUTPUT_DIR}/${HOST}"
  mkdir -p "$HOST_DIR"
  : > "${HOST_DIR}/status.txt"   # fresh run: truncate

  # 1) Test SSH connectivity
  ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "echo SSH_OK" >/dev/null 2>&1
  if [[ $? -ne 0 ]]; then
    echo "[MASTER] [$HOST] SSH connection failed. Skipping." | tee -a "$LOGFILE"
    log_task_master "$HOST" "SSH Connection" "Failed"
    continue
  else
    echo "[MASTER] [$HOST] SSH connection successful." | tee -a "$LOGFILE"
    log_task_master "$HOST" "SSH Connection" "Success"
  fi

  # 2) Copy provisioning script
  scp "${BASE_DIR}/${SCRIPT_NAME}" "$HOST:/tmp/${SCRIPT_NAME}" >> "$LOGFILE" 2>&1
  if [[ $? -ne 0 ]]; then
    echo "[MASTER] [$HOST] Failed to copy ${SCRIPT_NAME}" | tee -a "$LOGFILE"
    log_task_master "$HOST" "Copy Provisioning Script" "Failed"
    continue
  else
    echo "[MASTER] [$HOST] Copied ${SCRIPT_NAME}" | tee -a "$LOGFILE"
    log_task_master "$HOST" "Copy Provisioning Script" "Success"
  fi

  # 3) Copy optional artifacts (adjust paths if needed)
  scp /root/important_package/team.keys "$HOST:/tmp/ssh_keys.txt" >> "$LOGFILE" 2>&1
  if [[ $? -ne 0 ]]; then
    echo "[MASTER] [$HOST] Copy SSH Keys FAILED" | tee -a "$LOGFILE"
    log_task_master "$HOST" "Copy SSH Keys File" "Failed"
  else
    echo "[MASTER] [$HOST] Copy SSH Keys OK" | tee -a "$LOGFILE"
    log_task_master "$HOST" "Copy SSH Keys File" "Success"
  fi

  scp /root/important_package/falcon_package/falcon-sensor_7.20.17306.deb "$HOST:/tmp/" >> "$LOGFILE" 2>&1
  if [[ $? -ne 0 ]]; then
    echo "[MASTER] [$HOST] Copy Falcon Sensor FAILED" | tee -a "$LOGFILE"
    log_task_master "$HOST" "Copy Falcon Sensor" "Failed"
  else
    echo "[MASTER] [$HOST] Copy Falcon Sensor OK" | tee -a "$LOGFILE"
    log_task_master "$HOST" "Copy Falcon Sensor" "Success"
  fi

  # 4) Write per-host FQDN file and copy
  echo "$HOST" > /tmp/pws
  scp /tmp/pws "$HOST:/tmp/servers.txt" >> "$LOGFILE" 2>&1
  if [[ $? -ne 0 ]]; then
    echo "[MASTER] [$HOST] Copy FQDN File FAILED" | tee -a "$LOGFILE"
    log_task_master "$HOST" "Copy FQDN File" "Failed"
  else
    echo "[MASTER] [$HOST] Copy FQDN File OK" | tee -a "$LOGFILE"
    log_task_master "$HOST" "Copy FQDN File" "Success"
  fi

  # 5) Execute remote provisioning and capture output to temp file
  echo "[MASTER] [$HOST] Executing remote provisioning script" | tee -a "$LOGFILE"
  TMP_OUT="$(mktemp)"
  # Run ssh and capture both stdout/stderr into TMP_OUT
  ssh -o StrictHostKeyChecking=no "$HOST" "bash /tmp/${SCRIPT_NAME}" > "$TMP_OUT" 2>&1
  SSH_RC=$?

  # Process captured output line-by-line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == TASK::* ]]; then
      TASK_NAME="$(echo "$line" | cut -d'::' -f2)"
      STATUS="$(echo "$line" | cut -d'::' -f3)"
      TASK_NAME="$(echo -e "$TASK_NAME" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      STATUS="$(echo -e "$STATUS" | awk '{print tolower($0)}' | sed -e 's/^./\U&/')"
      echo -e "${TASK_NAME}\t${STATUS}" >> "${HOST_DIR}/status.txt"
      echo "[${HOST}] TASK ${TASK_NAME}: ${STATUS}" >> "$LOGFILE"
    else
      # generic output
      echo "[${HOST}] ${line}" >> "$LOGFILE"
    fi
  done < "$TMP_OUT"

  rm -f "$TMP_OUT"

  # Log overall ssh exit
  if [[ $SSH_RC -eq 0 ]]; then
    log_task_master "$HOST" "Remote Provisioning Script" "Success"
    echo "[MASTER] [$HOST] Remote provisioning completed successfully." | tee -a "$LOGFILE"
  else
    log_task_master "$HOST" "Remote Provisioning Script" "Failed"
    echo "[MASTER] [$HOST] Remote provisioning finished with error (ssh rc=${SSH_RC})." | tee -a "$LOGFILE"
  fi

  echo "[MASTER] === [$HOST] Finished provisioning ===" | tee -a "$LOGFILE"
  echo "----------------------------------------" >> "$LOGFILE"

done < "$SERVERS_FILE"

echo "[MASTER] Provisioning completed at $(date)" | tee -a "$LOGFILE"
