#!/bin/bash
# === Linux Provisioning Script ===
# Supports: Ubuntu OS
# Emits TASK::<TaskName>::<Status>
# Master server parses these lines into status.txt

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ================================================================
# Remote log file (master will scp this back)
# ================================================================
LOG_REMOTE="/tmp/provisioning_remote.log"
: > "$LOG_REMOTE"
exec >> "$LOG_REMOTE" 2>&1


# ================================================================
# Helper functions
# ================================================================
report_task() {
    local TASK="$1"
    local STATUS="$2"
    echo "TASK::${TASK}::${STATUS}"
}

run_and_report() {
    local TASK="$1"; shift
    if "$@"; then
        report_task "$TASK" "Success"
        return 0
    else
        report_task "$TASK" "Failed"
        return 1
    fi
}

echo "=== Starting Provisioning: $(date) ==="


# ================================================================
# 1. Change Root Password
# ================================================================
run_and_report "Change Root Password" bash -c 'echo "root:SNDK~R3d^H@t" | chpasswd'


# ================================================================
# 2. Set Hostname
# ================================================================
FQDN_FILE=/tmp/servers.txt
if [ -f "$FQDN_FILE" ]; then
    HOSTNAME_VALUE=$(head -n 1 "$FQDN_FILE")
    run_and_report "Set Hostname" hostnamectl set-hostname "$HOSTNAME_VALUE"
else
    report_task "Set Hostname" "Skipped"
fi


# ================================================================
# 3. DNS Configuration
# ================================================================
if bash -c 'cat > /etc/resolv.conf <<EOF
search sandisk.com corp.sandisk.com
nameserver 10.86.1.1
nameserver 10.86.2.1
EOF'; then
    report_task "Configure resolv.conf" "Success"
else
    report_task "Configure resolv.conf" "Failed"
fi


# ================================================================
# 4. Chrony Setup
# ================================================================
apt-get update -y >/dev/null 2>&1 || true

run_and_report "Install Chrony" apt-get install -y chrony >/dev/null 2>&1

if bash -c 'cat > /etc/chrony/chrony.conf <<EOF
server 10.86.1.1 iburst
server 10.86.2.1 iburst
EOF'; then
    systemctl enable chrony || true
    systemctl restart chrony || true
    report_task "Configure Chrony" "Success"
else
    report_task "Configure Chrony" "Failed"
fi


# ================================================================
# 5. Postfix Setup
# ================================================================
if apt-get install -y postfix >/dev/null 2>&1; then
    cp /etc/postfix/main.cf /etc/postfix/main.cf.bak_$(date +%F_%T) 2>/dev/null || true

    HOSTNAME_LOCAL=$(hostname)

    cat > /etc/postfix/main.cf <<EOF
myhostname = ${HOSTNAME_LOCAL}
myorigin = /etc/mailname
mydestination = \$myhostname, localhost.\$mydomain, localhost
mynetworks = 127.0.0.0/8
relayhost = [mailrelay.sandisk.com]:25
smtp_sasl_auth_enable = no
smtp_use_tls = no
smtp_tls_security_level = none
home_mailbox = Maildir/
mailbox_command =
smtpd_banner = \$myhostname ESMTP
biff = no
append_dot_mydomain = no
readme_directory = no
compatibility_level = 2
smtpd_recipient_restrictions = permit_mynetworks, reject_unauth_destination
EOF

    systemctl restart postfix || true
    report_task "Install Postfix" "Success"
else
    report_task "Install Postfix" "Failed"
fi


# ================================================================
# 6. Install Check-MK Agent
# ================================================================
if [[ -f /tmp/check-mk-agent.deb ]]; then
    if dpkg -i /tmp/check-mk-agent.deb >/dev/null 2>&1 || apt-get -f install -y >/dev/null 2>&1; then
        report_task "Install Check-MK Agent" "Success"
    else
        report_task "Install Check-MK Agent" "Failed"
    fi
else
    report_task "Install Check-MK Agent" "Skipped"
fi


# ================================================================
# 7. CrowdStrike Falcon Sensor
# ================================================================
if [[ -f /tmp/falcon-sensor_7.20.17306.deb ]]; then
    if dpkg -i /tmp/falcon-sensor_7.20.17306.deb >/dev/null 2>&1; then

        CID="06C18613D2124D6CA8757655E830126E-83"
        /opt/CrowdStrike/falconctl -s -f --cid="$CID" >/dev/null 2>&1

        systemctl enable falcon-sensor || true
        systemctl start falcon-sensor || true

        report_task "Install Falcon Sensor" "Success"
    else
        report_task "Install Falcon Sensor" "Failed"
    fi
else
    report_task "Install Falcon Sensor" "Skipped"
fi


# ================================================================
# 8. Firewall
# ================================================================
if apt-get install -y ufw >/dev/null 2>&1; then
    for port in 22 80 443 6556; do
        ufw allow "$port"/tcp >/dev/null 2>&1 || true
    done
    ufw --force enable >/dev/null 2>&1
    report_task "Configure Firewall" "Success"
else
    report_task "Configure Firewall" "Failed"
fi


# ================================================================
# 9. LVM Setup (original logic preserved)
# ================================================================
LVM_FAILED=0

lsblk -d -n -o NAME | grep -v sr0 | while read -r disk; do

    if ! pvs | grep -q "/dev/$disk"; then
        if pvcreate "/dev/$disk" >/dev/null 2>&1 && vgcreate datavg "/dev/$disk" >/dev/null 2>&1; then
            report_task "LVM VG datavg on /dev/$disk" "Success"
        else
            report_task "LVM VG datavg on /dev/$disk" "Failed"
            LVM_FAILED=1
        fi
    else
        report_task "LVM VG datavg on /dev/$disk" "Skipped"
    fi

done

if [[ $LVM_FAILED -eq 0 ]]; then
    report_task "LVM Setup Summary" "Success"
else
    report_task "LVM Setup Summary" "Failed"
fi


# ================================================================
# 10. Common Utilities
# ================================================================
if apt-get install -y wget sysstat openssl at bzip2 git htop iproute2 lsof nfs-common pcp rsync screen tcpdump telnet tmux traceroute unzip vim zip zsh ksh >/dev/null 2>&1; then
    report_task "Install Common Utilities" "Success"
else
    report_task "Install Common Utilities" "Failed"
fi


# ================================================================
# 11. SSH Keys
# ================================================================
if [[ -f /tmp/ssh_keys.txt ]]; then
    mkdir -p /root/.ssh
    cp -a /root/.ssh/authorized_keys /root/.ssh/authorized_keys_bak_$(date +%F_%T) 2>/dev/null || true

    if cp -a /tmp/ssh_keys.txt /root/.ssh/authorized_keys >/dev/null 2>&1; then
        chmod 700 /root/.ssh
        chmod 600 /root/.ssh/authorized_keys
        report_task "Install SSH Keys" "Success"
    else
        report_task "Install SSH Keys" "Failed"
    fi
else
    report_task "Install SSH Keys" "Skipped"
fi


# ================================================================
# 12. Timezone auto-detection
# ================================================================
declare -A TIMEZONES=(
  ["ULS"]="America/Los_Angeles" ["USE"]="America/Los_Angeles"
  ["USS"]="America/Los_Angeles" ["USG"]="America/Los_Angeles"
  ["UIM"]="America/Los_Angeles" ["TBM"]="Asia/Bangkok"
  ["TBB"]="Asia/Bangkok" ["TPT"]="Asia/Bangkok"
  ["IKY"]="Asia/Jerusalem"
  ["CSJ"]="Asia/Shanghai" ["CSS"]="Asia/Shanghai" ["CSF"]="Asia/Shanghai"
  ["IOI"]="Asia/Jerusalem"
  ["IBP"]="Asia/Kolkata" ["IBS"]="Asia/Kolkata" ["IBV"]="Asia/Kolkata"
  ["IBT"]="Asia/Kolkata" ["IBH"]="Asia/Kolkata"
  ["KSG"]="Asia/Seoul"
  ["MSK"]="Asia/Kuala_Lumpur" ["MJP"]="Asia/Kuala_Lumpur"
  ["MPP"]="Asia/Kuala_Lumpur" ["MPL"]="Asia/Kuala_Lumpur"
  ["MPS"]="Asia/Kuala_Lumpur"
  ["PBT"]="Asia/Manila"
  ["JAN"]="Asia/Tokyo" ["JFK"]="Asia/Tokyo" ["JOK"]="Asia/Tokyo"
  ["JOM"]="Asia/Tokyo" ["JTK"]="Asia/Tokyo" ["JON"]="Asia/Tokyo"
  ["JYU"]="Asia/Tokyo" ["JOO"]="Asia/Tokyo" ["JTY"]="Asia/Tokyo"
  ["JYY"]="Asia/Tokyo"
)

HOST_UP=$(hostname | tr '[:lower:]' '[:upper:]')

FOUND_CODE=""
for CODE in "${!TIMEZONES[@]}"; do
    if [[ "$HOST_UP" == *"$CODE"* ]]; then
        FOUND_CODE="$CODE"
        break
    fi
done

if [[ -z "$FOUND_CODE" ]]; then
    report_task "Timezone Setup" "Skipped"
else
    TZ_VALUE="${TIMEZONES[$FOUND_CODE]}"
    if timedatectl set-timezone "$TZ_VALUE" >/dev/null 2>&1; then
        report_task "Timezone Setup" "Success"
    else
        report_task "Timezone Setup" "Failed"
    fi
fi


# ================================================================
# End
# ================================================================
report_task "Provisioning Script Exit" "Success"
exit 0
