
#!/bin/bash
# Remote provisioning script. Emits TASK::<NAME>::<Status> lines that master parses.
set -euo pipefail

# helper to print task outcome for master to parse
report_task() {
  local TASK="$1"
  local STATUS="$2"   # Success|Failed|Skipped
  echo "TASK::${TASK}::${STATUS}"
}

# Optional local remote log file (useful for troubleshooting on host)
LOG_REMOTE="/var/log/provisioning_remote.log"
# Try to append; ignore failure if no permission (should be root)
exec >> "$LOG_REMOTE" 2>&1 || true

# Helper wrapper to run a command and report
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

# ---- Begin tasks ----

# 1) Change root password (non-interactive)
run_and_report "Change Root Password" bash -c 'echo "root:SNDK~R3d^H@t" | chpasswd' || true

# 2) Set hostname from /tmp/servers.txt
FQDN_FILE="/tmp/servers.txt"
if [[ -f "$FQDN_FILE" ]]; then
  if run_and_report "Set Hostname from FQDN file" bash -c "hostnamectl set-hostname \"\$(head -n1 $FQDN_FILE)\""; then
    true
  else
    true
  fi
else
  report_task "Set Hostname from FQDN file" "Skipped"
fi

# 3) Update resolv.conf
if bash -c 'cat > /etc/resolv.conf <<EOF
search sandisk.com corp.sandisk.com
nameserver 10.86.1.1
nameserver 10.86.2.1
EOF' ; then
  report_task "Update /etc/resolv.conf" "Success"
else
  report_task "Update /etc/resolv.conf" "Failed"
fi

# 4) Chrony install & configure
if command -v chronyd &>/dev/null; then
  systemctl stop chronyd || true
fi
if run_and_report "Install Chrony (apt-get update)" apt-get update -y >/dev/null 2>&1 && \
   run_and_report "Install Chrony (apt-get install)" apt-get install -y chrony >/dev/null 2>&1; then
  if bash -c 'cat > /etc/chrony/chrony.conf <<EOF
server 10.86.1.1 iburst
server 10.86.2.1 iburst
EOF' ; then
    systemctl enable chrony || true
    systemctl restart chrony || true
    report_task "Configure Chrony" "Success"
  else
    report_task "Configure Chrony" "Failed"
  fi
else
  report_task "Install Chrony" "Failed"
fi

# 5) Install Postfix and configure relay
if apt-get install -y postfix >/dev/null 2>&1; then
  cp /etc/postfix/main.cf /etc/postfix/main.cf.bak_$(date +%F_%T) 2>/dev/null || true
  HOSTNAME_LOCAL="$(hostname)"
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

# 6) Install Check-MK agent if provided by master
if [[ -f /tmp/check-mk-agent.deb ]]; then
  if dpkg -i /tmp/check-mk-agent.deb >/dev/null 2>&1 || apt-get -f install -y >/dev/null 2>&1; then
    report_task "Install Check-MK Agent" "Success"
  else
    report_task "Install Check-MK Agent" "Failed"
  fi
else
  report_task "Install Check-MK Agent" "Skipped"
fi

# 7) Install Falcon Sensor (CrowdStrike) if present
if [[ -f /tmp/falcon-sensor_7.20.17306.deb ]]; then
  if dpkg -i /tmp/falcon-sensor_7.20.17306.deb >/dev/null 2>&1 || apt-get -f install -y >/dev/null 2>&1; then
    CID="06C18613D2124D6CA8757655E830126E-83"
    /opt/CrowdStrike/falconctl -s -f --cid="$CID" >/dev/null 2>&1 || true
    systemctl enable falcon-sensor || true
    systemctl start falcon-sensor || true
    report_task "Install Falcon Sensor" "Success"
  else
    report_task "Install Falcon Sensor" "Failed"
  fi
else
  report_task "Install Falcon Sensor" "Skipped"
fi

# 8) UFW firewall and ports
if apt-get install -y ufw >/dev/null 2>&1; then
  for port in 22 80 443 6556; do
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
  done
  ufw --force enable >/dev/null 2>&1 || true
  report_task "Configure Firewall (UFW)" "Success"
else
  report_task "Configure Firewall (UFW)" "Failed"
fi

# 9) LVM setup: create VG datavg from available non-OS disks (preserves original behavior)
LVM_FAILED=0
while read -r disk; do
  [[ -z "$disk" ]] && continue
  if ! pvs | grep -q "/dev/${disk}"; then
    if pvcreate "/dev/${disk}" >/dev/null 2>&1 && vgcreate datavg "/dev/${disk}" >/dev/null 2>&1; then
      report_task "LVM create VG on /dev/${disk}" "Success"
    else
      report_task "LVM create VG on /dev/${disk}" "Failed"
      LVM_FAILED=1
    fi
  else
    report_task "LVM create VG on /dev/${disk}" "Skipped"
  fi
done < <(lsblk -d -n -o NAME | grep -v sr0)

if [[ $LVM_FAILED -eq 0 ]]; then
  report_task "LVM Setup Summary" "Success"
else
  report_task "LVM Setup Summary" "Failed"
fi

# 10) Install common utilities
if apt-get install -y wget sysstat openssl at bzip2 git htop iproute2 lsof nfs-common pcp rsync screen tcpdump telnet tmux traceroute unzip vim zip zsh ksh >/dev/null 2>&1; then
  report_task "Install Common Utilities" "Success"
else
  report_task "Install Common Utilities" "Failed"
fi

# 11) Add SSH keys for root if provided by master
if [[ -f /tmp/ssh_keys.txt ]]; then
  mkdir -p /root/.ssh
  cp -a /root/.ssh/authorized_keys /root/.ssh/authorized_keys_bak_$(date +%F_%T) 2>/dev/null || true
  if cp -a /tmp/ssh_keys.txt /root/.ssh/authorized_keys >/dev/null 2>&1; then
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys
    chown -R root:root /root/.ssh
    report_task "Install SSH Keys" "Success"
  else
    report_task "Install SSH Keys" "Failed"
  fi
else
  report_task "Install SSH Keys" "Skipped"
fi

# 12) Timezone mapping & setup (detect from hostname)
declare -A TIMEZONES=(
  ["ULS"]="America/Los_Angeles" ["USE"]="America/Los_Angeles" ["USS"]="America/Los_Angeles"
  ["USG"]="America/Los_Angeles" ["UIM"]="America/Los_Angeles" ["TBM"]="Asia/Bangkok"
  ["TBB"]="Asia/Bangkok" ["TPT"]="Asia/Bangkok" ["IKY"]="Asia/Jerusalem"
  ["CSJ"]="Asia/Shanghai" ["CSS"]="Asia/Shanghai" ["CSF"]="Asia/Shanghai"
  ["IOI"]="Asia/Jerusalem" ["IBP"]="Asia/Kolkata" ["IBS"]="Asia/Kolkata"
  ["IBV"]="Asia/Kolkata" ["IBT"]="Asia/Kolkata" ["KSG"]="Asia/Seoul"
  ["MSK"]="Asia/Kuala_Lumpur" ["MJP"]="Asia/Kuala_Lumpur" ["MPP"]="Asia/Kuala_Lumpur"
  ["MPL"]="Asia/Kuala_Lumpur" ["MPS"]="Asia/Kuala_Lumpur" ["PBT"]="Asia/Manila"
  ["JAN"]="Asia/Tokyo" ["JFK"]="Asia/Tokyo" ["JOK"]="Asia/Tokyo" ["JOM"]="Asia/Tokyo"
  ["JTK"]="Asia/Tokyo" ["JON"]="Asia/Tokyo" ["JYU"]="Asia/Tokyo" ["JOO"]="Asia/Tokyo"
  ["JTY"]="Asia/Tokyo" ["JYY"]="Asia/Tokyo" ["IBH"]="Asia/Kolkata"
)

HOSTNAME_UPPER="$(hostname | tr '[:lower:]' '[:upper:]')"
LOCATION_CODE=""
for CODE in "${!TIMEZONES[@]}"; do
  if [[ "$HOSTNAME_UPPER" == *"$CODE"* ]]; then
    LOCATION_CODE="$CODE"
    break
  fi
done

if [[ -z "$LOCATION_CODE" ]]; then
  report_task "Timezone Setup" "Skipped"
else
  TIMEZONE="${TIMEZONES[$LOCATION_CODE]}"
  if timedatectl set-timezone "$TIMEZONE" >/dev/null 2>&1; then
    report_task "Timezone Setup" "Success"
  else
    report_task "Timezone Setup" "Failed"
  fi
fi

# Final report & exit
report_task "Provisioning Script Exit" "Success"
exit 0
