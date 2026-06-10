#!/bin/bash
# cyrus-check.sh — Cyrus IMAP/POP3/LMTP/ManageSieve child-saturation monitoring for Zabbix
#
# Each Cyrus service in cyrus.conf has a `maxchild=` cap. When a service reaches
# that cap, the master process accepts new connections into the listen backlog
# but cannot fork a worker to handle them, so clients hang until they time out
# (IMAP/POP3 logins fail; LMTP deliveries defer and retry). This script reports,
# per service, the current number of worker processes, the configured cap, and
# the utilisation percentage, so Zabbix can alert *before* a service saturates.
#
# Run locally on the Cyrus host (it counts local processes). Paths default to
# /etc/cyrus.conf and /etc/imapd.conf and can be overridden with the CYRUS_CONF
# and IMAPD_CONF env vars.
#
# Primary mode (Zabbix master/dependent items): one-pass JSON
#   cyrus-check.sh json
#     -> {"master_alive":1,"idled":1,"notifyd":1,
#         "imap":  {"children":7,"maxchild":600,"pct":1},
#         "pop3":  {"children":2,"maxchild":250,"pct":0},
#         "lmtp":  {"children":1,"maxchild":100,"pct":1},
#         "sieve": {"children":0,"maxchild":200,"pct":0},
#         "db":    {"mailboxes_bytes":1234567,"deliver_bytes":89012}}
#
# Individual checks (CLI debugging / legacy single-value UserParameters):
#   master_alive | idled_alive | notifyd_alive
#   imap_children  | pop3_children  | lmtp_children  | sieve_children
#   imap_pct       | pop3_pct       | lmtp_pct       | sieve_pct
#   db_mailboxes   | db_deliver        (sizes in bytes of the Cyrus databases)
#
# pct denominators: each protocol and its TLS/unix sibling (imap+imaps,
# pop3+pop3s, lmtp+lmtpunix, sieve+sieveold) run the same binary, so the child
# count cannot be split per-listener by ps/pgrep. Utilisation is computed against
# the primary TCP listener's cap (imap/pop3/lmtp/sieve in cyrus.conf), which
# normally carries all the traffic; the TLS/unix siblings are usually idle. This
# is conservative: it can only over-report utilisation, never hide saturation.
#
# Repository: https://github.com/a-schild/Zabbix-Cyrus-Imap-Template

CYRUS_CONF="${CYRUS_CONF:-/etc/cyrus.conf}"
IMAPD_CONF="${IMAPD_CONF:-/etc/imapd.conf}"

# maxchild= for a given cyrus.conf service (first field == name, active lines
# only — commented "#imap" murder-frontend lines are ignored). Empty if absent.
maxchild_for() {
    awk -v svc="$1" '
        $1 == svc {
            for (i = 1; i <= NF; i++)
                if ($i ~ /^maxchild=/) { split($i, a, "="); print a[2]; exit }
        }' "$CYRUS_CONF"
}

# configdirectory from imapd.conf (where mailboxes.db / deliver.db live).
config_dir() {
    local d
    d=$(awk -F: '/^[[:space:]]*configdirectory[[:space:]]*:/ {
            sub(/^[^:]*:[[:space:]]*/, ""); gsub(/[[:space:]]+$/, ""); print; exit }' \
        "$IMAPD_CONF" 2>/dev/null)
    echo "${d:-/var/lib/cyrus}"
}

# Size in bytes of a file, 0 if missing/unreadable.
file_size() {
    [ -f "$1" ] && stat -c %s "$1" 2>/dev/null || echo 0
}

# 1 if at least one process of the exact-named binary is running, else 0.
alive() {
    [ "$(count_proc "$1")" -gt 0 ] && echo 1 || echo 0
}

# Count children of an exact-named binary. Always prints a single integer (0 on
# no match or pgrep error) so it is safe to embed directly in JSON.
count_proc() {
    local n
    n=$(pgrep -xc "$1" 2>/dev/null)
    case "$n" in
        ''|*[!0-9]*) echo 0 ;;
        *)           echo "$n" ;;
    esac
}

# pct <count> <cap> -> integer percent, -1 if cap unknown/zero
pct() {
    local cnt="$1" cap="$2"
    [ -n "$cap" ] && [ "$cap" -gt 0 ] 2>/dev/null || { echo -1; return; }
    echo $(( cnt * 100 / cap ))
}

master_alive_val() {
    # The Cyrus master process is named "cyrmaster" on Debian/Ubuntu. Avoid bare
    # "master" (Postfix's master process would false-positive). Fall back to the
    # systemd unit state. Adjust the unit name if your distro differs.
    if pgrep -x cyrmaster >/dev/null 2>&1 \
       || systemctl is-active --quiet cyrus-imapd 2>/dev/null; then
        echo 1
    else
        echo 0
    fi
}

emit_json() {
    local ma id nd ic im ip pc pm pp lc lm lp sc sm sp cfg mb dv
    ma=$(master_alive_val)
    id=$(alive idled); nd=$(alive notifyd)
    ic=$(count_proc imapd);     im=$(maxchild_for imap);  ip=$(pct "$ic" "$im")
    pc=$(count_proc pop3d);     pm=$(maxchild_for pop3);  pp=$(pct "$pc" "$pm")
    lc=$(count_proc lmtpd);     lm=$(maxchild_for lmtp);  lp=$(pct "$lc" "$lm")
    sc=$(count_proc timsieved); sm=$(maxchild_for sieve); sp=$(pct "$sc" "$sm")
    cfg=$(config_dir); mb=$(file_size "$cfg/mailboxes.db"); dv=$(file_size "$cfg/deliver.db")
    printf '{"master_alive":%s,"idled":%s,"notifyd":%s,"imap":{"children":%s,"maxchild":%s,"pct":%s},"pop3":{"children":%s,"maxchild":%s,"pct":%s},"lmtp":{"children":%s,"maxchild":%s,"pct":%s},"sieve":{"children":%s,"maxchild":%s,"pct":%s},"db":{"mailboxes_bytes":%s,"deliver_bytes":%s}}\n' \
        "$ma" "$id" "$nd" "$ic" "${im:-0}" "$ip" "$pc" "${pm:-0}" "$pp" \
        "$lc" "${lm:-0}" "$lp" "$sc" "${sm:-0}" "$sp" "$mb" "$dv"
}

case "$1" in
    json)            emit_json ;;
    master_alive)    master_alive_val ;;
    idled_alive)     alive idled ;;
    notifyd_alive)   alive notifyd ;;
    imap_children)   count_proc imapd ;;
    pop3_children)   count_proc pop3d ;;
    lmtp_children)   count_proc lmtpd ;;
    sieve_children)  count_proc timsieved ;;
    imap_pct)   pct "$(count_proc imapd)"     "$(maxchild_for imap)" ;;
    pop3_pct)   pct "$(count_proc pop3d)"     "$(maxchild_for pop3)" ;;
    lmtp_pct)   pct "$(count_proc lmtpd)"     "$(maxchild_for lmtp)" ;;
    sieve_pct)  pct "$(count_proc timsieved)" "$(maxchild_for sieve)" ;;
    db_mailboxes)  file_size "$(config_dir)/mailboxes.db" ;;
    db_deliver)    file_size "$(config_dir)/deliver.db" ;;
    *)
        echo "Usage: $0 {json|master_alive|idled_alive|notifyd_alive|{imap,pop3,lmtp,sieve}_{children,pct}|db_mailboxes|db_deliver}" >&2
        echo -1
        exit 1
        ;;
esac
