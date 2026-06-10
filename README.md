# Zabbix Cyrus IMAP Template

A Zabbix 7.0 template that monitors **Cyrus IMAP** worker-process saturation and
warns you *before* a service runs out of workers.

## The problem it solves

Every service in `cyrus.conf` has a `maxchild=` cap:

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

A single agent item runs [`cyrus-check.sh`](cyrus-check.sh) once per interval and
returns one JSON document:

```json
{"master_alive":1,
 "imap":  {"children":7,"maxchild":600,"pct":1},
 "pop3":  {"children":2,"maxchild":250,"pct":0},
 "lmtp":  {"children":1,"maxchild":100,"pct":1},
 "sieve": {"children":0,"maxchild":200,"pct":0}}
```

The template turns that master item into **dependent items** via JSONPath
preprocessing — so all metrics are collected in a single pass, with no extra
process spawns per metric. The `maxchild` caps are read from `cyrus.conf` at
collection time, so the utilisation percentages stay correct even if you retune
the caps; you never edit the template.

> **Note on counts:** each protocol and its TLS/unix sibling (`imap`+`imaps`,
> `pop3`+`pop3s`, `lmtp`+`lmtpunix`, `sieve`+`sieveold`) run a single shared
> binary, so per-listener counts can't be separated by `pgrep`. Utilisation is
> measured against the primary TCP listener's cap, which normally carries all the
> traffic. This is conservative — it can over-report, never hide saturation.

## What you get

**Items** (one master + dependent):

| Key | Description |
|-----|-------------|
| `cyrus.stats` | Master item — raw JSON (active check) |
| `cyrus.master.alive` | Cyrus master process up (1) / down (0) |
| `cyrus.{imap,pop3,lmtp,sieve}.children` | Current worker count per service |
| `cyrus.{imap,pop3,lmtp,sieve}.pct` | Worker count as % of that service's `maxchild` |

**Triggers:**

* `cyrus.master.alive = 0` → **High**
* each `*.pct` > 80 % (3-sample average) → **Warning**
* each `*.pct` > 95 % (3-sample average) → **High**

**Graphs:** *children per service* and *utilisation % per service* (fixed 0–100).

**Dashboard:** a **Cyrus** tab on the host's monitoring page with both graphs and
a master-process status widget.

## Requirements

* Zabbix **7.0** server and agent (Zabbix Agent 2 or Agent 1).
* A Cyrus IMAP host you can deploy a small shell script to.
* `pgrep` and (optionally) `systemctl` available on that host.

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
| `CYRUS_CONF` | `/etc/cyrus.conf` | Path to `cyrus.conf`. Export it in the agent's environment if your distro differs. |

The script detects the Cyrus master as `cyrmaster` (Debian/Ubuntu) and falls back
to the `cyrus-imapd` systemd unit. Adjust `master_alive_val()` if your packaging
uses different names.

## Tuning guidance

Keep each service's `maxchild` **above** the maximum concurrency its front end can
push at it — e.g. a Dovecot login proxy's `process_limit`, or the sum of your
MTAs' `lmtp_destination_concurrency_limit`. If the backend cap is lower than the
front-end ceiling, a burst can exhaust it and stall clients. These triggers tell
you when you're approaching that point.

## License

[Apache License 2.0](LICENSE).
