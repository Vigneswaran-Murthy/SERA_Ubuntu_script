#!/bin/bash
set -euo pipefail

BASE_DIR="/data/automation/os_config/ubuntu_os_config"
OUTPUT_DIR="${BASE_DIR}/ubuntu_output"

MAIL_TO="vigneswaran.murthy@sandisk.com"
MAIL_FROM="ansible_automation@sandisk.com"
MAIL_CC="PDL-IT-Linux-Support@sandisk.com"

# Sendmail/Mailx command (auto-detection)
MAIL_BIN=$(command -v mail || command -v mailx || echo "")

if [[ -z "$MAIL_BIN" ]]; then
    echo "ERROR: Neither mail nor mailx is installed. Cannot send email."
    exit 1
fi

for HOST_DIR in "$OUTPUT_DIR"/*/; do
    [[ ! -d "$HOST_DIR" ]] && continue

    HOST=$(basename "$HOST_DIR")
    STATUS_FILE="${HOST_DIR}/status.txt"

    if [[ -f "$STATUS_FILE" ]]; then
        mapfile -t STATUS_LINES < "$STATUS_FILE"
    else
        STATUS_LINES=("No tasks executed for this host")
    fi

    # Build HTML table rows
    HTML_ROWS=""
    idx=0
    for LINE in "${STATUS_LINES[@]}"; do
        TASK=$(echo "$LINE" | awk -F'\t' '{print $1}')
        STATUS=$(echo "$LINE" | awk -F'\t' '{print $2}')

        # Alternate background color
        if (( idx % 2 == 0 )); then
            ROW_COLOR="#ffffff"
        else
            ROW_COLOR="#f9f9f9"
        fi

        # Status icons
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
                     </tr>
        "

        ((idx++))
    done

    # Build final HTML email body
    EMAIL_BODY=$(cat <<EOF
<html>
<body style="font-family: Arial, sans-serif; text-align: center; background-color: #fafafa; padding: 20px;">
  <div style="display: inline-block; text-align: left; background: #fff; padding: 20px; border-radius: 8px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);">
    <p style="text-align: center; font-size: 16px; font-weight: bold;">
      Playbook Task Status Summary for ${HOST}:
    </p>
    <table border="1" cellpadding="8" cellspacing="0" style="border-collapse: collapse; width: 600px; margin: 0 auto; text-align: center;">
      <tr style="background-color: #f2f2f2;">
        <th style="text-align: center;">Task Name</th>
        <th style="text-align: center;">Status</th>
      </tr>
      ${HTML_ROWS}
    </table>
  </div>
</body>
</html>
EOF
    )

    # Send the email
    echo "$EMAIL_BODY" | $MAIL_BIN -a "Content-Type: text/html" \
        -s "Provisioning Task Status Summary - ${HOST}" \
        -r "${MAIL_FROM}" \
        -c "${MAIL_CC}" \
        "${MAIL_TO}"

    echo "[EMAIL] Sent report for ${HOST}"
done

echo "All summary emails delivered successfully."
