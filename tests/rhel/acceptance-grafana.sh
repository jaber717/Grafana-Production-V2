#!/usr/bin/env bash
# Acceptance run of grafana-platform on an ISOLATED, DISPOSABLE test machine.  Run it from a workstation:
#
#   G=<grafana VM ip> A=<akvorado VM ip> SSH_KEY=~/.ssh/key tests/rhel/acceptance-grafana.sh [--offline-bundle <dir-on-G>] [--skip-upgrade] [--skip-reboot]
#
# G: clean RHEL 9.x VM (>= 2 vCPU, 3 GiB, RHEL repositories, passwordless sudo for $SSH_USER).
# A: the Akvorado test machine (already installed by tests/rhel/acceptance-akvorado.sh in the Akvorado repository, holding synthetic flows); Grafana's
#    ClickHouse datasource is pointed at it over verified TLS with that machine's dummy read-only password and throw-away CA.
# No production or LAB system is involved: Zabbix is a TLS mock (tests/rhel/mock-zabbix.py) answering a dummy credential; the NOC item map is synthetic.
# The script DESTROYS and rebuilds Grafana on G several times (disaster-recovery test) — never point it at a real server.
# Result: one [PASS]/[FAIL] line per check, exit status 0 only if every check passed.  Set ACC_LOG=<file> to keep the log.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); REPO=$(cd "$HERE/../.." && pwd)
# shellcheck disable=SC1091
. "$HERE/lib-accept.sh"
: "${G:?set G=<grafana VM ip>}" "${A:?set A=<akvorado VM ip>}"
OLD_VER=${OLD_GRAFANA_VERSION:-13.2.2}
SKIP_UP=0; SKIP_REBOOT=0; BUNDLE=""
while [ $# -gt 0 ]; do case "$1" in --skip-upgrade) SKIP_UP=1 ;; --skip-reboot) SKIP_REBOOT=1 ;; --offline-bundle) BUNDLE=$2; shift ;; esac; shift; done
[ -n "$BUNDLE" ] && SKIP_UP=1   # the upgrade test installs an older package from the repository: not possible offline
HG=/home/qual/gp
RG() { local b; b=$(printf '%s' "source $HG/tests/rhel/remote-lib.sh; $*" | base64 -w0); _ssh "$G" "sudo bash -c \"\$(echo $b | base64 -d)\""; }
RA() { local b; b=$(printf '%s' "$*" | base64 -w0); _ssh "$A" "sudo bash -c \"\$(echo $b | base64 -d)\""; }
wait_ssh() { local i; for i in $(seq 1 60); do _ssh "$1" "uptime -p" | grep -qa '^up' && return 0; sleep 5; done; return 1; }
EV=/root/gp-test/test.env
GREP_OK='VERIFY: [0-9]+ PASS, [0-9]+ WARN, 0 FAIL'

mkdir -p "$(dirname "${ACC_LOG:-/dev/null}")" 2>/dev/null || true
section "0. Environment"
note "grafana G=$G, akvorado A=$A; release $(cat "$REPO/VERSION"); commit $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo n/a)"
tar --exclude=.git --exclude=node_modules --exclude=./dist -czf - -C "$REPO" . | ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$G" 'rm -rf ~/gp && mkdir ~/gp && tar -xzf - -C ~/gp' 2>&1 | grep -av '^\*\*' || true
RG "chmod +x $HG/bin/grafana-platform"
expect_match "G is RHEL 9" "$(_ssh "$G" 'grep ^PRETTY_NAME /etc/os-release')" 'Red Hat Enterprise Linux 9'
expect_eq "G SELinux" "$(_ssh "$G" getenforce)" Enforcing
expect_eq "G firewalld" "$(_ssh "$G" 'systemctl is-active firewalld')" active
expect_eq "G has no Grafana yet (clean host)" "$(_ssh "$G" 'rpm -q grafana >/dev/null 2>&1 && echo present || echo absent')" absent
for try in 1 2 3; do
  SETUP_OUT=$(RG "bash $HG/tests/rhel/setup-grafana-test.sh $HG $A 2>&1")
  [ "$(RG 'test -f /root/gp-test/test.env && echo yes || echo no')" = yes ] && break; sleep 20
done
expect_eq "test host prepared (PKI, dummy secrets, mock Zabbix, item map, environment file)" "$(RG 'test -f /root/gp-test/test.env && echo yes || echo no')" yes
[ "$(RG 'test -f /root/gp-test/test.env && echo yes || echo no')" = yes ] || { note "setup output: ${SETUP_OUT: -700}"; acc_summary; exit 1; }
# the ClickHouse datasource: the Akvorado test machine, verified TLS, dummy password, its throw-away CA
CA=$(RA 'cat /etc/akvorado-platform/restored-tls/ca.pem 2>/dev/null || cat /root/ap-test/pki/ca.pem'); PW=$(RA 'tr -d "\r\n" < /etc/akvorado-platform/secrets/grafana-ro-password')
printf '%s\n' "$CA" | ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$G" 'cat > /tmp/akvorado-ca.pem' 2>&1 | grep -av '^\*\*' || true
printf '%s' "$PW" | ssh -i "$SSH_KEY" -o BatchMode=yes "$SSH_USER@$G" 'cat > /tmp/chpw.txt' 2>&1 | grep -av '^\*\*' || true
RG "install -m 0600 /tmp/chpw.txt /etc/grafana-platform/secrets/clickhouse-password; rm -f /tmp/chpw.txt; install -m 0644 /tmp/akvorado-ca.pem /root/gp-test/pki/akvorado-ca.pem; sed -i '/netflow.test.lab/d' /etc/hosts; echo '$A netflow.test.lab # gp-test' >> /etc/hosts; sed -i 's#^CLICKHOUSE_HOST=.*#CLICKHOUSE_HOST=netflow.test.lab#; s#^CLICKHOUSE_CA_FILE=.*#CLICKHOUSE_CA_FILE=/root/gp-test/pki/akvorado-ca.pem#; s#^GRAFANA_ALLOWED_CIDRS=.*#GRAFANA_ALLOWED_CIDRS=192.168.1.0/24#' $EV"
RG "nft insert rule inet claude_isolation output ip daddr $A accept"
[ -n "$BUNDLE" ] && RG "sed -i \"s#^PACKAGE_SOURCE=.*#PACKAGE_SOURCE=bundle\nBUNDLE_DIR=$BUNDLE#\" $EV"
_ssh "$A" "sudo nft insert rule inet claude_isolation output ip daddr $G accept" >/dev/null

section "1. Preflight is read-only"
out=$(RG "\$(gpc) preflight --env-file $EV; echo RC=\$?")
expect_match "preflight finishes without FAIL" "$out" 'PREFLIGHT: [0-9]+ PASS, [0-9]+ WARN, 0 FAIL'
expect_eq "preflight installed nothing" "$(_ssh "$G" 'rpm -q grafana >/dev/null 2>&1 && echo rpm || echo none; test -e /etc/grafana-platform/release.json && echo release || echo norelease' | tr '\n' ' ')" "none norelease "
expect_eq "preflight generated no secrets" "$(_ssh "$G" 'sudo test -e /etc/grafana-platform/secrets/admin-password && echo yes || echo no')" no

section "2. Install (clean host) and idempotent re-run"
RG "\$(gpc) install --env-file $EV > /tmp/ginstall1.log 2>&1; echo \$? > /tmp/ginstall1.rc"
expect_eq "install exit status" "$(_ssh "$G" 'sudo cat /tmp/ginstall1.rc')" 0
expect_match "install summary" "$(_ssh "$G" 'sudo tail -3 /tmp/ginstall1.log')" 'INSTALL: [0-9]+ PASS, [0-9]+ WARN, 0 FAIL'
expect_match "content applied: 12 objects created" "$(_ssh "$G" 'sudo grep -a "^applied:" /tmp/ginstall1.log')" 'applied: 12 created, 0 updated'
RG "\$(gpc) install --env-file $EV > /tmp/ginstall2.log 2>&1; echo \$? > /tmp/ginstall2.rc"
expect_eq "second install exit status" "$(_ssh "$G" 'sudo cat /tmp/ginstall2.rc')" 0
expect_match "second install writes nothing (idempotent)" "$(_ssh "$G" 'sudo grep -a "^applied:" /tmp/ginstall2.log')" 'applied: 0 created, 0 updated, 12 unchanged, 0 refused'
out=$(RG "\$(gpc) verify; echo RC=\$?"); expect_match "verify: no FAIL" "$out" "$GREP_OK"

section "3. Package, service, TLS, SELinux, firewall"
expect_match "RPM signed by the pinned Grafana Labs key" "$(_ssh "$G" 'rpm -q grafana --qf "%{RSAHEADER:pgpsig}"')" "$(sed -n 's/^GRAFANA_RPM_GPG_FPR=.*\(................\)$/\1/p' "$REPO/VERSIONS.env" | tr A-F a-f)"
expect_eq "installed Grafana version" "$(RG version)" "$(sed -n 's/^GRAFANA_VERSION=//p' "$REPO/VERSIONS.env")"
expect_eq "package is version-locked" "$(_ssh "$G" "sudo dnf -q versionlock list 2>/dev/null | grep -c '^grafana-'")" 1
expect_eq "service runs as the unprivileged user" "$(_ssh "$G" "ps -o user= -C grafana | sort -u | tr -d ' \n'")" grafana
expect_eq "TLS certificate verifies for grafana.test.lab" "$(RG 'curl -s -m 8 -o /dev/null -w "%{http_code}" --resolve grafana.test.lab:3000:127.0.0.1 https://grafana.test.lab:3000/api/health')" 200
expect_eq "TLS 1.0/1.1 refused" "$(RG 'curl -s -m 8 --tls-max 1.1 -o /dev/null -w "%{http_code}" --resolve grafana.test.lab:3000:127.0.0.1 https://grafana.test.lab:3000/api/health; true')" 000
expect_eq "SELinux denials for grafana since boot" "$(_ssh "$G" "sudo ausearch -m avc,user_avc -ts boot -c grafana-server 2>/dev/null | grep -c 'type=AVC' || true")" 0
expect_eq "no literal password in grafana.ini" "$(_ssh "$G" "sudo grep -ciE '^(admin_)?password *= *[^\$ ]' /etc/grafana/grafana.ini || true")" 0
expect_match "firewalld admits the port only by source rule" "$(_ssh "$G" 'sudo firewall-cmd --list-rich-rules; sudo firewall-cmd --list-ports')" 'source address="192.168.1.0/24" port port="3000"'

section "4. Content: dashboards, folders, datasources, playlist"
expect_eq "9 dashboards with the original UIDs (+ noc-command-center, noc-network-traffic)" "$(RG dash_uids)" "netflow-asn netflow-exporters netflow-health netflow-overview netflow-top-talkers noc-command-center noc-device-health noc-network-traffic noc-wan-overview"
expect_eq "2 folders" "$(RG folders)" "netflow noc"
expect_eq "playlist" "$(RG playlists)" "NetFlow NOC Rotation"
expect_eq "both datasources healthy (Zabbix mock + Akvorado ClickHouse over verified TLS)" "$(RG ds_status)" "zabbix-lab=OK netflow-clickhouse=OK "
out=$(RG "export PATH=/usr/local/bin:\$PATH; cd $HG && GRAFANA_URL=\$B GRAFANA_USER=admin GRAFANA_PASSWORD=\$(cat /etc/grafana-platform/secrets/admin-password) GRAFANA_CONNECT_ADDR=127.0.0.1 GRAFANA_CA_FILE=/etc/pki/tls/certs/ca-bundle.crt node tools/panel-smoke.mjs | tail -1")
expect_match "every ClickHouse panel query of the NetFlow dashboards executes (panel smoke test)" "$out" 'panel-smoke: [0-9]+ PASS \([0-9]+ with no rows\), 0 FAIL'

section "5. Network admission (allowed, denied, restored)"
code() { _ssh "$A" "curl -sk -m 6 -o /dev/null -w '%{http_code}' https://$G:3000/api/health" | tail -1; }
expect_eq "allowed source reaches Grafana" "$(code)" 200
RG "sed -i 's#^GRAFANA_ALLOWED_CIDRS=.*#GRAFANA_ALLOWED_CIDRS=192.0.2.1/32#' $EV; \$(gpc) install --env-file $EV >/dev/null 2>&1"
expect_eq "source outside GRAFANA_ALLOWED_CIDRS is refused" "$(code)" 000
RG "sed -i 's#^GRAFANA_ALLOWED_CIDRS=.*#GRAFANA_ALLOWED_CIDRS=192.168.1.0/24#' $EV; \$(gpc) install --env-file $EV >/dev/null 2>&1"
expect_eq "restored: reachable again" "$(code)" 200

section "6. Backup, damage, restore"
RG "mark_dash m-keep; \$(gpc) backup > /tmp/gbk1.log 2>&1; echo \$? > /tmp/gbk1.rc"
expect_eq "backup exit status" "$(_ssh "$G" 'sudo cat /tmp/gbk1.rc')" 0
ARCH=$(RG 'ls -1t /var/backups/grafana-platform/*manual.tar.gz | head -1')
RG 'mark_dash m-drop; api -X DELETE "$B/api/dashboards/uid/noc-wan-overview" >/dev/null; api -X DELETE "$B/api/datasources/uid/zabbix-lab" >/dev/null'
expect_eq "damage applied (dashboard deleted, junk created)" "$(RG 'echo $(has_dash noc-wan-overview) $(has_dash m-drop)')" "absent present"
RG "\$(gpc) restore $ARCH --yes > /tmp/grs1.log 2>&1; echo \$? > /tmp/grs1.rc"
expect_eq "restore exit status" "$(_ssh "$G" 'sudo cat /tmp/grs1.rc')" 0
expect_eq "deleted dashboard is back, junk dashboard gone, kept marker present" "$(RG 'echo $(has_dash noc-wan-overview) $(has_dash m-drop) $(has_dash m-keep)')" "present absent present"
expect_eq "datasources healthy after the restore" "$(RG ds_status)" "zabbix-lab=OK netflow-clickhouse=OK "
RG "printf 'dummy-passphrase-2' > /root/gp-test/bp; printf 'wrong' > /root/gp-test/bp.wrong; chmod 600 /root/gp-test/bp*; cp /etc/grafana-platform/platform.env /tmp/gpe.keep; echo BACKUP_GPG_PASSPHRASE_FILE=/root/gp-test/bp >> /etc/grafana-platform/platform.env; \$(gpc) backup --include-secrets > /tmp/gbk2.log 2>&1"
ENC=$(RG 'ls -1t /var/backups/grafana-platform/*manual.tar.gz.gpg | head -1')
expect_match "encrypted archive written" "$ENC" '\.tar\.gz\.gpg$'
RG "sed -i 's#^BACKUP_GPG_PASSPHRASE_FILE=.*#BACKUP_GPG_PASSPHRASE_FILE=/root/gp-test/bp.wrong#' /etc/grafana-platform/platform.env"
expect_match "wrong passphrase refused before anything changes" "$(RG "\$(gpc) restore $ENC --yes 2>&1 | tail -2")" 'decryption failed'
RG "cp /tmp/gpe.keep /etc/grafana-platform/platform.env"
expect_eq "Grafana still healthy after the refused restore" "$(RG ds_status)" "zabbix-lab=OK netflow-clickhouse=OK "

section "7. Secret rotation"
RG "cp /etc/grafana-platform/secrets/clickhouse-password /tmp/chpw.keep; printf 'definitely-wrong' > /etc/grafana-platform/secrets/clickhouse-password; \$(gpc) rotate-secrets > /tmp/grot1.log 2>&1; echo \$? > /tmp/grot1.rc"
expect_match "a wrong datasource password is detected (non-zero exit)" "$(_ssh "$G" 'sudo cat /tmp/grot1.rc')" '^[1-9]'
RG "cp /tmp/chpw.keep /etc/grafana-platform/secrets/clickhouse-password; chmod 600 /etc/grafana-platform/secrets/clickhouse-password; \$(gpc) rotate-secrets > /tmp/grot2.log 2>&1; echo \$? > /tmp/grot2.rc"
expect_eq "correct password written back: exit status" "$(_ssh "$G" 'sudo cat /tmp/grot2.rc')" 0
expect_eq "ClickHouse datasource healthy again" "$(RG ds_status)" "zabbix-lab=OK netflow-clickhouse=OK "

section "8. Disaster recovery: destroy everything, rebuild from one backup archive"
RG "mark_dash dr-marker; \$(gpc) backup --include-secrets > /tmp/gbk3.log 2>&1"
ARCH=$(RG 'ls -1t /var/backups/grafana-platform/*manual.tar.gz | head -1'); RG "mkdir -p /root/keep; cp $ARCH /root/keep/archive.tar.gz"
RG 'systemctl stop grafana-server; dnf -q versionlock delete grafana >/dev/null 2>&1; dnf -y -q remove grafana >/dev/null 2>&1; rm -rf /etc/grafana /var/lib/grafana /var/log/grafana /opt/grafana-platform /etc/grafana-platform /usr/local/sbin/grafana-platform /etc/yum.repos.d/grafana-platform.repo /var/backups/grafana-platform; mv /root/gp-test/tls /root/gp-test/tls.lost; mv /root/gp-test/pki /root/gp-test/pki.lost'
expect_eq "disaster applied: no Grafana, no configuration, no secrets" "$(_ssh "$G" 'rpm -q grafana >/dev/null 2>&1 && echo rpm || echo none; test -e /etc/grafana-platform && echo cfg || echo nocfg' | tr '\n' ' ')" "none nocfg "
RG "$HG/bin/grafana-platform restore /root/keep/archive.tar.gz --bootstrap > /tmp/gdr1.log 2>&1; echo \$? > /tmp/gdr1.rc"
expect_eq "bootstrap exit status" "$(_ssh "$G" 'sudo cat /tmp/gdr1.rc')" 0
RG "$HG/bin/grafana-platform install > /tmp/gdr2.log 2>&1; echo \$? > /tmp/gdr2.rc"
expect_eq "install on the rebuilt host exit status" "$(_ssh "$G" 'sudo cat /tmp/gdr2.rc')" 0
expect_eq "fresh install has no marker dashboard" "$(RG 'has_dash dr-marker')" absent
RG "\$(gpc) restore /root/keep/archive.tar.gz --yes > /tmp/gdr3.log 2>&1; echo \$? > /tmp/gdr3.rc"
expect_eq "restore on the rebuilt host exit status" "$(_ssh "$G" 'sudo cat /tmp/gdr3.rc')" 0
expect_eq "marker dashboard restored" "$(RG 'has_dash dr-marker')" present
expect_eq "datasources healthy with the restored secret key" "$(RG ds_status)" "zabbix-lab=OK netflow-clickhouse=OK "
out=$(RG "\$(gpc) verify; echo RC=\$?"); expect_match "verify after the rebuild: no FAIL" "$out" "$GREP_OK"

if [ "$SKIP_UP" -eq 0 ]; then
section "9. Upgrade from the previous release, rollback, automatic rollback of a failing upgrade"
RG "bash $HG/tests/rhel/make-prev-release.sh $HG /home/qual/gp-prev $OLD_VER >/dev/null; chmod +x /home/qual/gp-prev/bin/grafana-platform"
RG 'systemctl stop grafana-server; dnf -q versionlock delete grafana >/dev/null 2>&1; dnf -y -q remove grafana >/dev/null 2>&1; rm -rf /etc/grafana /var/lib/grafana /var/log/grafana /opt/grafana-platform /usr/local/sbin/grafana-platform /etc/grafana-platform/release.json /etc/grafana-platform/.install-started /etc/grafana-platform/secrets/admin-password /etc/grafana-platform/secrets/secret-key /etc/yum.repos.d/grafana-platform.repo'
RG "/home/qual/gp-prev/bin/grafana-platform install > /tmp/gup0.log 2>&1; echo \$? > /tmp/gup0.rc"
expect_eq "previous release installs" "$(_ssh "$G" 'sudo cat /tmp/gup0.rc')" 0
expect_eq "previous release runs Grafana $OLD_VER" "$(RG version)" "$OLD_VER"
RG "mark_dash user-before-upgrade"
RG "$HG/bin/grafana-platform upgrade --yes > /tmp/gup1.log 2>&1; echo \$? > /tmp/gup1.rc"
expect_eq "upgrade exit status" "$(_ssh "$G" 'sudo cat /tmp/gup1.rc')" 0
expect_eq "Grafana upgraded" "$(RG version)" "$(sed -n 's/^GRAFANA_VERSION=//p' "$REPO/VERSIONS.env")"
expect_eq "user data survived the upgrade; repository content intact" "$(RG 'echo $(has_dash user-before-upgrade) $(has_dash netflow-overview)')" "present present"
RG "mark_dash user-after-upgrade; /usr/local/sbin/grafana-platform rollback --yes > /tmp/gup2.log 2>&1; echo \$? > /tmp/gup2.rc"
expect_eq "rollback exit status" "$(_ssh "$G" 'sudo cat /tmp/gup2.rc')" 0
expect_eq "after rollback Grafana is $OLD_VER" "$(RG version)" "$OLD_VER"
expect_eq "rollback restored the pre-upgrade state (post-upgrade data gone, earlier data kept)" "$(RG 'echo $(has_dash user-before-upgrade) $(has_dash user-after-upgrade)')" "present absent"
RG "$HG/bin/grafana-platform upgrade --yes > /tmp/gup3.log 2>&1; echo \$? > /tmp/gup3.rc"
expect_eq "re-upgrade exit status" "$(_ssh "$G" 'sudo cat /tmp/gup3.rc')" 0
RG "rm -rf /home/qual/gp-bad; cp -a $HG /home/qual/gp-bad; sed -i 's/^GRAFANA_VERSION=.*/GRAFANA_VERSION=13.9.9/' /home/qual/gp-bad/VERSIONS.env; echo 1.0.1-bad > /home/qual/gp-bad/VERSION; chmod +x /home/qual/gp-bad/bin/grafana-platform"
RG "/home/qual/gp-bad/bin/grafana-platform upgrade --yes > /tmp/gup4.log 2>&1; echo \$? > /tmp/gup4.rc"
expect_match "failing upgrade exits non-zero" "$(_ssh "$G" 'sudo cat /tmp/gup4.rc')" '^[1-9]'
expect_match "failing upgrade rolled back automatically" "$(_ssh "$G" 'sudo tail -3 /tmp/gup4.log')" 'UPGRADE \(rolled back\)'
expect_eq "still on the current Grafana after the failed upgrade" "$(RG version)" "$(sed -n 's/^GRAFANA_VERSION=//p' "$REPO/VERSIONS.env")"
out=$(RG "/usr/local/sbin/grafana-platform verify; echo RC=\$?"); expect_match "platform healthy after the failed upgrade" "$out" "$GREP_OK"
fi

if [ "$SKIP_REBOOT" -eq 0 ]; then
section "10. Reboot"
_ssh "$G" 'sudo systemctl reboot' >/dev/null; sleep 40; wait_ssh "$G"; ok "G is back after the reboot"
_ssh "$G" "sudo nft insert rule inet claude_isolation output ip daddr $A accept" >/dev/null
RG "d=/root/gp-test/pki; [ -d \$d ] || d=/root/gp-test/pki.lost; systemd-run --unit=gp-mock-zabbix-r --description=mock-zabbix /usr/bin/python3 $HG/tests/rhel/mock-zabbix.py \$d/zabbix.test.lab.crt \$d/zabbix.test.lab.key 8443 >/dev/null 2>&1; true"
rc=1; for i in $(seq 1 30); do out=$(RG "/usr/local/sbin/grafana-platform verify"); if grep -qaE "$GREP_OK" <<<"$out"; then rc=0; break; fi; sleep 8; done
check "Grafana came back on its own and verifies (test-only mock Zabbix and egress exception re-created)" "$rc"
fi

section "11. Final state"
out=$(RG "\$(gpc) verify"); expect_match "final verify: no FAIL" "$out" "$GREP_OK"; note "$(echo "$out" | tail -1)"
acc_summary
