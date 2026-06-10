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
# Run locally on the Cyrus host (it counts local processes). The cyrus.conf path
# defaults to /etc/cyrus.conf and can be overridden with the CYRUS_CONF env var.
#
# Primary mode (Zabbix master/dependent items): one-pass JSON
#   cyrus-check.sh json
#     -> {"master_alive":1,
#         "imap":  {"children":7,"maxchild":600,"pct":1},
#         "pop3":  {"children":2,"maxchild":250,"pct":0},
#         "lmtp":  {"children":1,"maxchild":100,"pct":1},
#         "sieve": {"children":0,"maxchild":200,"pct":0}}
#
# Individual checks (CLI debugging / legacy single-value UserParameters):
#   master_alive
#   imap_children  | pop3_children  | lmtp_children  | sieve_children
#   imap_pct       | pop3_pct       | lmtp_pct       | sieve_pct
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

# maxchild= for a given cyrus.conf service (first field == name, active lines
# only — commented "#imap" murder-frontend lines are ignored). Empty if absent.
maxchild_for() {
    awk -v svc="$1" '
        $1 == svc {
            for (i = 1; i <= NF; i++)
                if ($i ~ /^maxchild=/) { split($i, a, "="); print a[2]; exit }
        }' "$CYRUS_CONF"
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
    local ma ic im ip pc pm pp lc lm lp sc sm sp
    ma=$(master_alive_val)
    ic=$(count_proc imapd);     im=$(maxchild_for imap);  ip=$(pct "$ic" "$im")
    pc=$(count_proc pop3d);     pm=$(maxchild_for pop3);  pp=$(pct "$pc" "$pm")
    lc=$(count_proc lmtpd);     lm=$(maxchild_for lmtp);  lp=$(pct "$lc" "$lm")
    sc=$(count_proc timsieved); sm=$(maxchild_for sieve); sp=$(pct "$sc" "$sm")
    printf '{"master_alive":%s,"imap":{"children":%s,"maxchild":%s,"pct":%s},"pop3":{"children":%s,"maxchild":%s,"pct":%s},"lmtp":{"children":%s,"maxchild":%s,"pct":%s},"sieve":{"children":%s,"maxchild":%s,"pct":%s}}\n' \
        "$ma" "$ic" "${im:-0}" "$ip" "$pc" "${pm:-0}" "$pp" \
        "$lc" "${lm:-0}" "$lp" "$sc" "${sm:-0}" "$sp"
}

case "$1" in
    json)            emit_json ;;
    master_alive)    master_alive_val ;;
    imap_children)   count_proc imapd ;;
    pop3_children)   count_proc pop3d ;;
    lmtp_children)   count_proc lmtpd ;;
    sieve_children)  count_proc timsieved ;;
    imap_pct)   pct "$(count_proc imapd)"     "$(maxchild_for imap)" ;;
    pop3_pct)   pct "$(count_proc pop3d)"     "$(maxchild_for pop3)" ;;
    lmtp_pct)   pct "$(count_proc lmtpd)"     "$(maxchild_for lmtp)" ;;
    sieve_pct)  pct "$(count_proc timsieved)" "$(maxchild_for sieve)" ;;
    *)
        echo "Usage: $0 {json|master_alive|{imap,pop3,lmtp,sieve}_{children,pct}}" >&2
        echo -1
        exit 1
        ;;
esac
