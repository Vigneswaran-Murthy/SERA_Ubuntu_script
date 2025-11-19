#!/bin/bash

cd /data/automation/os_config/ubuntu_os_config/

SERVERS_FILE="servers.txt"
SCRIPT="ubuntu_os_config.sh"
LOGFILE="provisioning.log"
OUTPUT_DIR="./ubuntu_output"

MAIL_TO="vigneswaran.murthy@sandisk.com"
MAIL_FROM="ansible_automation@sandisk.com"
MAIL_CC="PDL-IT-Linux-Support@sandisk.com"

mkdir -p "$OUTPUT_DIR"

echo "Provisioning started at $(date)" > "$LOGFILE"
echo "----------------------------------------" >> "$LOGFILE"

# Requires root privileges
if [[ $EUID -ne 0 ]]; then
  echo "***** Please run this script as root to change the system time zone *****" | tee -a "$LOGFILE"
  exit 1
fi

if [ ! -f "$SERVERS_FILE" ]; then
  echo "***** Error: $SERVERS_FILE not found *****" | tee -a "$LOGFILE"
  exit 1
fi

# ====== PROCESS EACH HOST ======
for HOST in `cat $SERVERS_FILE`
do
  [ -z "$HOST" ] && continue

  echo "=== [$HOST] Starting provisioning... ===" | tee -a "$LOGFILE"

  HOST_DIR="${OUTPUT_DIR}/${HOST}"
  mkdir -p "$HOST_DIR"
  : > "$HOST_DIR/status.txt"

  echo "$HOST" > /tmp/pws

  # Test SSH connection
  ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "echo OK" >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo "=== [$HOST] SSH connection failed ===" | tee -a "$LOGFILE"
    echo -e "SSH Connection\tFailed" >> "$HOST_DIR/status.txt"
    continue
  fi

  echo -e "SSH Connection\tSuccess" >> "$HOST_DIR/status.txt"

  # Copy files
  scp "$SCRIPT" "$HOST:/tmp/$SCRIPT" >> "$LOGFILE" 2>&1
  scp /root/important_package/team.keys "$HOST:/tmp/ssh_keys.txt" >> "$LOGFILE" 2>&1
  scp /root/important_package/falcon_package/falcon-sensor_7.20.17306.deb "$HOST:/tmp" >> "$LOGFILE" 2>&1
  scp /tmp/pws "$HOST:/tmp/servers.txt" >> "$LOGFILE" 2>&1

  if [ $? -ne 0 ]; then
    echo -e "Copy Required Files\tFailed" >> "$HOST_DIR/status.txt"
    continue
  else
    echo -e "Copy Required Files\tSuccess" >> "$HOST_DIR/status.txt"
  fi

  echo "=== [$HOST] Running remote provisioning ... ===" | tee -a "$LOGFILE"

  # Capture TASK::<task>::<status>
  ssh -o StrictHostKeyChecking=no "$HOST" "bash /tmp/$SCRIPT" 2>&1 | while IFS= read -r line; do

    if [[ "$line" == TASK::* ]]; then
        TASK_NAME=$(echo "$line" | cut -d"::" -f2)
        STATUS=$(echo "$line" | cut -d"::" -f3)

        echo -e "${TASK_NAME}\t${STATUS}" >> "$HOST_DIR/status.txt"
        echo "[${HOST}] TASK ${TASK_NAME}: ${STATUS}" >> "$LOGFILE"
    else
        echo "[${HOST}] ${line}" >> "$LOGFILE"
    fi

  done

  # Retrieve remote provisioning log
  scp "$HOST:/tmp/provisioning_remote.log" "$HOST_DIR/provisioning_remote.log" >> "$LOGFILE" 2>&1 || \
      echo "[${HOST}] No remote provisioning log found" >> "$LOGFILE"

  echo -e "Remote Provisioning Script\tSuccess" >> "$HOST_DIR/status.txt"

done

# ================================================
#  SEND EMAIL REPORT FOR EACH HOST (HTML FORMAT)
# ================================================

MAIL_BIN=$(command -v mail || command -v mailx || echo "")

if [[ -z "$MAIL_BIN" ]]; then
    echo "ERROR: mail/mailx not installed. Cannot send email." | tee -a "$LOGFILE"
    exit 1
fi

for HOST_DIR in "$OUTPUT_DIR"/*/; do
    HOST=$(basename "$HOST_DIR")
    STATUS_FILE="${HOST_DIR}/status.txt"

    if [[ -f "$STATUS_FILE" ]]; then
        mapfile -t STATUS_LINES < "$STATUS_FILE"
    else
        STATUS_LINES=("No tasks executed for this host")
    fi

    HTML_ROWS=""
    idx=0
    for LINE in "${STATUS_LINES[@]}"; do
        TASK=$(echo "$LINE" | awk -F'\t' '{print $1}')
        STATUS=$(echo "$LINE" | awk -F'\t' '{print $2}')

        if (( idx % 2 == 0 )); then
            ROW_COLOR="#ffffff"
        else
            ROW_COLOR="#f9f9f9"
        fi

        if [[ "$STATUS" == "Success" ]]; then
            STATUS_HTML='<span style="color: green; font-weight: bold;">✅ Success</span>'
        elif [[ "$STATUS" == "Failed" ]]; then
            STATUS_HTML='<span style="color: red; font-weight: bold;">❌ Failed</span>'
        else
            STATUS_HTML="<span style=\"color: orange; font-weight: bold;\">⚠️ ${STATUS}</span>"
        fi

        HTML_ROWS+="<tr style=\"background-color: ${ROW_COLOR};\">
                        <td style=\"padding: 6px;\">${TASK}</td>
                        <td style=\"padding: 6px; text-align: center;\">${STATUS_HTML}</td>
                    </tr>"
        ((idx++))
    done

    EMAIL_BODY=$(cat <<EOF
<html>
<body style="font-family: Arial; background-color: #fafafa; padding: 20px; text-align:center;">
  <div style="background:#fff; padding:20px; border-radius:8px; display:inline-block;">
    <p style="font-size: 16px; font-weight: bold;">Provisioning Task Summary for ${HOST}</p>
    <table border="1" cellpadding="8" cellspacing="0" style="width:650px; border-collapse: collapse;">
      <tr style="background:#f2f2f2;">
        <th>Task Name</th>
        <th>Status</th>
      </tr>
      ${HTML_ROWS}
    </table>
  </div>
</body>
</html>
EOF
    )

    echo "$EMAIL_BODY" | $MAIL_BIN -a "Content-Type: text/html" \
        -s "Provisioning Task Summary - ${HOST}" \
        -r "${MAIL_FROM}" \
        -c "${MAIL_CC}" \
        "${MAIL_TO}"

    echo "[EMAIL] Sent summary for ${HOST}" | tee -a "$LOGFILE"

done

echo "All emails delivered."
