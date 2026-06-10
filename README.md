# Zabbix Cyrus IMAP Template

A Zabbix 7.0 template for **Cyrus IMAP** health monitoring, collected over the
Zabbix agent (active). It covers:

* **Worker-process saturation** — per-service worker count vs the `maxchild` cap,
  warning *before* a service runs out of workers.
* **Service availability & latency** — IMAP/IMAPS/POP3/POP3S/LMTP/ManageSieve.
* **Log errors** — `IOERROR`, `DBERROR`, fatal errors / unexpected service exits.
* **TLS certificate expiry** — days remaining on the IMAPS certificate.
* **Supporting daemons & databases** — `master`, `idled`, `notifyd`; `mailboxes.db`
  and `deliver.db` size growth.

Saturation was the original motivation (below); the rest covers Cyrus's other
everyday failure modes.

## The problem it solves

The failure mode that's hardest to catch — and the reason this template exists —
is **worker-process saturation**. Every service in `cyrus.conf` has a `maxchild=`
cap:

```
imap   cmd="imapd"     listen="imap"  prefork=0 maxchild=100
pop3   cmd="pop3d"     listen="pop3"  prefork=0 maxchild=50
lmtp   cmd="lmtpd -a"  listen="24"    prefork=0 maxchild=20
sieve  cmd="timsieved" listen="4190"  prefork=0 maxchild=100
```

When a service reaches its cap, the Cyrus master keeps **accepting** new TCP
connections into the listen backlog but cannot fork a worker to service them, so
clients just hang until they time out:

* **IMAP / POP3** — logins fail. A front-end login proxy (e.g. Dovecot) typically
  logs `Login timed out in state=/none`.
* **LMTP** — inbound deliveries from your MTAs defer and retry, silently building
  a mail backlog.

The failure is invisible until users complain, because nothing *errors* — the
connections simply stall. This template surfaces, per service, the live worker
count and its utilisation against the configured cap, with triggers that fire at
80 % and 95 % so you can raise `maxchild` (or investigate a connection leak)
before anything stalls.

## How it works

Most metrics come from a single agent item that runs
[`cyrus-check.sh`](usr/local/lib/zabbix/externalscripts/cyrus-check.sh) once per
interval and returns one JSON document:

```json
{"master_alive":1,"idled":1,"notifyd":1,
 "imap":  {"children":7,"maxchild":600,"pct":1},
 "pop3":  {"children":2,"maxchild":250,"pct":0},
 "lmtp":  {"children":1,"maxchild":100,"pct":1},
 "sieve": {"children":0,"maxchild":200,"pct":0},
 "db":    {"mailboxes_bytes":1234567,"deliver_bytes":89012}}
```

The template turns that master item into **dependent items** via JSONPath
preprocessing — so all of those metrics are collected in a single pass, with no
extra process spawns per metric. The `maxchild` caps are read from `cyrus.conf`
at collection time, so the utilisation percentages stay correct even if you
retune the caps; you never edit the template.

The remaining checks are standard active agent items, so they need no custom
script: **availability/latency** via `net.tcp.service.perf[...]` against
`127.0.0.1`, **log errors** via `log[{$CYRUS.LOG},...]`, and the **TLS
certificate** via the agent 2 `web.certificate.get[...]` item (with a small
JavaScript preprocessing step to turn the expiry date into days remaining).

> **Note on counts:** each protocol and its TLS/unix sibling (`imap`+`imaps`,
> `pop3`+`pop3s`, `lmtp`+`lmtpunix`, `sieve`+`sieveold`) run a single shared
> binary, so per-listener counts can't be separated by `pgrep`. Utilisation is
> measured against the primary TCP listener's cap, which normally carries all the
> traffic. This is conservative — it can over-report, never hide saturation.

## What you get

All metrics come from the single `cyrus.stats` master item plus a few active
agent checks. Everything is collected via **Zabbix agent (active)**.

**Saturation (from `cyrus.stats`):**

| Key | Description |
|-----|-------------|
| `cyrus.stats` | Master item — raw JSON (active check) |
| `cyrus.{imap,pop3,lmtp,sieve}.children` | Current worker count per service |
| `cyrus.{imap,pop3,lmtp,sieve}.pct` | Worker count as % of that service's `maxchild` |

**Processes & databases (from `cyrus.stats`):**

| Key | Description |
|-----|-------------|
| `cyrus.master.alive` | Cyrus master process up (1) / down (0) |
| `cyrus.idled.alive` | `idled` (IMAP IDLE push) up/down |
| `cyrus.notifyd.alive` | `notifyd` (event notifications) up/down |
| `cyrus.db.mailboxes.size` | `mailboxes.db` size in bytes (trend) |
| `cyrus.db.deliver.size` | `deliver.db` size in bytes (trend) |

**Availability & latency** (agent `net.tcp.service.perf`, run against `127.0.0.1`):

| Key | Description |
|-----|-------------|
| `net.tcp.service.perf[imap,127.0.0.1,143]` | IMAP connect+banner time (0 = down) |
| `net.tcp.service.perf[pop,127.0.0.1,110]` | POP3 connect+banner time |
| `net.tcp.service.perf[tcp,127.0.0.1,{993,995,24,4190}]` | IMAPS / POP3S / LMTP / ManageSieve port reachable |

**Log errors** (active `log[]`, path from `{$CYRUS.LOG}`):

| Key | Matches |
|-----|---------|
| `log[{$CYRUS.LOG},"IOERROR"]` | Mailbox/disk I/O errors, possible corruption |
| `log[{$CYRUS.LOG},"DBERROR"]` | Cyrus database errors |
| `log[{$CYRUS.LOG},"Fatal error\|master:.*exited"]` | Fatal errors / unexpected service exits |

**TLS certificate** (agent 2 `web.certificate.get` against the IMAPS port):

| Key | Description |
|-----|-------------|
| `web.certificate.get[{HOST.CONN},993]` | Master item — raw certificate JSON |
| `cyrus.cert.imaps.daysleft` | Days until expiry |
| `cyrus.cert.imaps.valid` | Validation result (collected for visibility) |

**Triggers:**

* `cyrus.master.alive = 0` → **High**; `idled`/`notifyd` down → **Warning**
* each `*.pct` > 80 % / > 95 % (3-sample average) → **Warning** / **High**
* each port not responding → **High** (suppressed when the master is down, via
  trigger dependency); IMAP/POP3 slow (> 2 s avg) → **Warning**
* `IOERROR` / `DBERROR` in log → **High**; fatal/exit → **Average** (manual close)
* TLS cert < 14 days → **Warning**, < 3 days/expired → **High**

**Graphs:** *children per service*, *utilisation % per service* (fixed 0–100),
*service response time*, and *database sizes* (mailboxes.db / deliver.db bytes).

**Dashboard:** a **Cyrus** tab on the host's monitoring page with all four
graphs, a master-process status widget, and a TLS-days-left widget.

## Requirements

* Zabbix **7.0** server and agent.
* **Zabbix Agent 2** is required for the TLS certificate items
  (`web.certificate.get`). Everything else works with Agent 1 too; drop those two
  cert dependent items + their master if you only run Agent 1.
* A Cyrus IMAP host you can deploy a small shell script to.
* `pgrep`, `stat` and (optionally) `systemctl` on that host.
* The agent user must be able to **read the Cyrus log** (`{$CYRUS.LOG}`) for the
  log items. This needs the log to be group-readable *and* `zabbix` in that group
  — adding `zabbix` to `adm` only helps if the file is `root:adm 640`. If your
  `mail.log` is `root:root` (some distros), set it group-readable in all three
  places that own its mode (now, logrotate's `create 640 root adm`, and rsyslog's
  `$FileCreateMode 0640` / `$FileGroup adm`), then `usermod -aG adm zabbix` and
  restart the agent. Alternatively grant an ACL (`setfacl -m u:zabbix:r …`) and
  re-apply it from a logrotate `postrotate`.
* For the **DB-size** items, the agent user must be able to **traverse the Cyrus
  `configdirectory`** (e.g. `/var/lib/cyrus`, mode `0750 cyrus:mail`). Add the
  `zabbix` user to the owning group and restart the agent:
  ```bash
  usermod -aG mail zabbix && systemctl restart zabbix-agent2
  ```
  Only directory *search* permission is needed (not read on the DB files), so the
  database modes can stay as they are. If the sizes report `0`, this is why.

## Macros

| Macro | Default | Purpose |
|-------|---------|---------|
| `{$CYRUS.LOG}` | `/var/log/mail.log` | Cyrus syslog path (RHEL/CentOS: `/var/log/maillog`). |

The TLS items use the built-in `{HOST.CONN}` so they validate against the host's
own interface address. For the `valid` result to be meaningful, that interface
should be the certificate's hostname; the **days-left** metric works regardless.

## Repository layout

The agent-side files are stored under the **same paths they occupy on the Cyrus
host**, so you can drop them straight in (Agent 2 paths shown):

```
etc/zabbix/zabbix_agent2.d/userparameter_cyrus.conf   ->  /etc/zabbix/zabbix_agent2.d/
usr/local/lib/zabbix/externalscripts/cyrus-check.sh   ->  /usr/local/lib/zabbix/externalscripts/
zbx_template_cyrus_imap.yaml                           ->  import on the Zabbix server
```

Using Agent 1 instead? Put the UserParameter in `/etc/zabbix/zabbix_agentd.d/`.

## Installation

On the **Cyrus host** (run from a checkout of this repo):

1. Copy the agent files into place:
   ```bash
   install -m 0755 usr/local/lib/zabbix/externalscripts/cyrus-check.sh \
       /usr/local/lib/zabbix/externalscripts/cyrus-check.sh
   cp etc/zabbix/zabbix_agent2.d/userparameter_cyrus.conf \
       /etc/zabbix/zabbix_agent2.d/
   ```
   (If your `cyrus.conf` isn't at `/etc/cyrus.conf`, set `CYRUS_CONF` — see below.)

2. The template collects via **active checks**, so the agent config must have:
   ```
   ServerActive=<your Zabbix server or proxy>
   Hostname=<exact host name as configured in Zabbix>
   ```

3. Restart the agent and test locally:
   ```bash
   systemctl restart zabbix-agent2
   zabbix_agent2 -t cyrus.stats        # should print the JSON
   ```

On the **Zabbix server**:

4. **Data collection → Templates → Import** [`zbx_template_cyrus_imap.yaml`](zbx_template_cyrus_imap.yaml).
5. Link the template *Cyrus IMAP by Zabbix agent* to your Cyrus host.

Graphs and the Cyrus dashboard tab populate once the dependent items have a few
data points.

## Configuration

| Setting | Default | Notes |
|---------|---------|-------|
| `CYRUS_CONF` | `/etc/cyrus.conf` | Path to `cyrus.conf` (read for `maxchild` caps). |
| `IMAPD_CONF` | `/etc/imapd.conf` | Path to `imapd.conf` (read for `configdirectory`, to locate the databases). |
| `{$CYRUS.LOG}` | `/var/log/mail.log` | Template macro — Cyrus syslog path for the log items. |

Set the env vars in the agent's environment (or a wrapper) if your distro differs.
The script detects the Cyrus master as `cyrmaster` (Debian/Ubuntu) and falls back
to the `cyrus-imapd` systemd unit; adjust `master_alive_val()` if your packaging
uses different names.

## Tuning guidance

Keep each service's `maxchild` **above** the maximum concurrency its front end can
push at it — e.g. a Dovecot login proxy's `process_limit`, or the sum of your
MTAs' `lmtp_destination_concurrency_limit`. If the backend cap is lower than the
front-end ceiling, a burst can exhaust it and stall clients. These triggers tell
you when you're approaching that point.

## License

[Apache License 2.0](LICENSE).
