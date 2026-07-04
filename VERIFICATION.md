# GPSD + Chrony Verification Guide

This guide defines a layered procedure for verifying that the gpsd/chrony
container is correctly implemented and actually disciplining the system clock
from GPS + PPS. Each layer depends on the one before it — **work top to
bottom and do not skip layers**. When something fails, the layer where it
first fails tells you where the fault is.

| Layer | What is verified | Primary tool |
|-------|------------------|--------------|
| 0 | Host devices and kernel support | `ls /dev`, `dmesg` |
| 1 | Container starts and stays up | `docker ps`, `docker logs` |
| 2 | Kernel PPS pulses arriving | `ppstest` |
| 3 | gpsd has a fix and sees PPS | `gpspipe`, `cgps`, `gpsmon` |
| 4 | gpsd → chrony handoff (SHM) | `chronyc sourcestats`, `ipcs -m` |
| 5 | chrony locked to PPS | `chronyc sources`, `chronyc tracking` |
| 6 | NTP served to clients | `chronyc clients`, client-side query |
| 7 | Ongoing health | Docker healthcheck, log review |

All commands run **inside the container** unless noted otherwise:

```bash
sudo docker exec -it gpsd-chrony bash
```

---

## Layer 0 — Host prerequisites (run on the host, not the container)

1. **Device nodes exist** and match `config.env` (`GPS_DEVICE`, `PPS_DEVICE`):

   ```bash
   ls -l /dev/ttyACM0 /dev/pps0        # adjust to your platform
   ```

   If `/dev/pps0` is missing: check that the `pps-gpio` overlay/module is
   loaded (`lsmod | grep pps`, `dmesg | grep pps`) and the device tree
   overlay is applied (see `device_tree_overlays/`).

2. **No competing time daemon on the host.** `systemd-timesyncd`, host
   `chronyd`, or `ntpd` will fight the container for the clock:

   ```bash
   systemctl is-active systemd-timesyncd chrony ntp 2>/dev/null
   ```

   All should report `inactive` or `not-found`.

3. **PPS pulses visible to the kernel** (requires `pps-tools` on the host,
   or skip and rely on Layer 2 inside the container):

   ```bash
   sudo ppstest /dev/pps0
   ```

**Pass criteria:** both device nodes exist; no other NTP service active.

---

## Layer 1 — Container startup

1. **Container is running and not restart-looping:**

   ```bash
   sudo docker ps --format 'table {{.Names}}\t{{.Status}}'
   ```

   `Status` should show `Up …` and, once a healthcheck is configured,
   `(healthy)`. `Restarting` or a rising restart count means the entrypoint
   is exiting — go to the logs.

2. **Startup log is clean:**

   ```bash
   sudo docker logs gpsd-chrony 2>&1 | head -60
   ```

   Expected sequence:
   - Configuration block printed (`=== Configuration ===`)
   - `Starting Chrony service...` then `Chronyd started`
   - `Starting GPSD service...` then `GPSD started`
   - `All services started successfully`

   Red flags:
   - `WARNING: Device /dev/... does not exist` — device not passed through
     in `compose.yaml` `devices:` or wrong path in `config.env`.
   - Repeated `ERROR: gpsd died` / `chronyd died` messages — the monitor is
     mis-detecting the process or the daemon really is crash-looping. Verify
     with Layer 1 step 3 before trusting the monitor.
   - `Fatal error : Could not open ... chrony.conf` — config volume mount
     missing or wrong.

3. **Both daemons actually have live processes** (do not trust PID files —
   verify the process table directly):

   ```bash
   sudo docker exec gpsd-chrony sh -c 'ps -o pid,user,comm,args | grep -E "gpsd|chronyd" | grep -v grep'
   ```

   Expect exactly **one** `gpsd` process and **one** `chronyd` process.
   Multiple `gpsd` entries mean the restart logic is respawning against a
   stale PID (see the monitoring notes at the end of this guide).

**Pass criteria:** container `Up`, one gpsd process, one chronyd process,
no repeating ERROR lines in the log.

---

## Layer 2 — Kernel PPS inside the container

```bash
ppstest /dev/pps0
```

Good output — one `assert` line per second, with the fractional part
stable in the sub-millisecond range:

```
trying PPS source "/dev/pps0"
found PPS source "/dev/pps0"
ok, found 1 source(s), now start fetching data...
source 0 - assert 1739485509.000083980, sequence: 100 - clear  0.000000000, sequence: 0
source 0 - assert 1739485510.000083988, sequence: 101 - clear  0.000000000, sequence: 0
```

Interpretation:
- **No lines at all / `time_pps_fetch` timeout** — GPS has no fix yet (most
  receivers only emit PPS after a fix), wiring problem on the PPS pin, or
  wrong GPIO in the overlay. Check Layer 3 first: if gpsd shows a 3D fix
  but no PPS, it is wiring/overlay.
- **Sequence numbers jumping** by more than 1 — pulses being missed;
  usually EMI or a marginal signal level.
- Ctrl-C to exit. Note: gpsd holds the PPS device too; `ppstest` sharing it
  is fine for a spot check.

**Pass criteria:** steady 1 Hz assert lines with monotonically increasing
sequence numbers.

---

## Layer 3 — gpsd

1. **Fix status (quick, scriptable):**

   ```bash
   gpspipe -w -n 10 | grep -m1 '"class":"TPV"'
   ```

   Look for `"mode":3` (3D fix). `"mode":1` = no fix — antenna view,
   antenna power, or receiver still in cold start. `"mode":2` (2D) is
   marginal but usable for time.

2. **gpsd sees the PPS source:**

   ```bash
   gpspipe -w -n 30 | grep -m1 '"class":"PPS"'
   ```

   A `PPS` class JSON message must appear within a few seconds. If TPV
   shows mode 3 but no PPS messages appear, gpsd was not given the PPS
   device (check the `Executing: gpsd ...` line in the startup log — the
   PPS device path must be listed) or the kernel PPS layer (Layer 2) is
   dead.

3. **Interactive confirmation (human check):**

   ```bash
   cgps          # dashboard: expect "Status: 3D FIX" and plausible lat/lon
   gpsmon        # bottom panel: expect TOFF and PPS offset values updating
   ```

   In `gpsmon`, `TOFF` is the serial-time offset (typically tens to
   hundreds of ms — that's normal for NMEA) and `PPS` should be in the
   nanosecond-to-microsecond range.

**Pass criteria:** `"mode":3` TPV messages and periodic `PPS` messages.

---

## Layer 4 — gpsd → chrony handoff (SHM)

Chrony reads GPS time from gpsd via shared memory segment `SHM 0`
(refclock `GPS` in `chrony.conf`).

1. **SHM segments exist:**

   ```bash
   ipcs -m
   ```

   Expect at least one segment with key `0x4e545030` (ASCII "NTP0").
   Missing segment = gpsd never attached (gpsd only creates it once it has
   data to deliver) or chronyd's `refclock SHM 0` line is absent.

2. **Chrony is receiving samples from both refclocks:**

   ```bash
   chronyc sourcestats
   ```

   Both `GPS` and `PPS` rows must show a non-zero, growing `NP` (number of
   sample points). `NP 0` on `GPS` = SHM handoff broken. `NP 0` on `PPS` =
   chrony can't read `/dev/pps0` or PPS never fires.

> **Permissions note:** chronyd runs as user `chrony` (dropped from root
> after startup) while gpsd runs as root. SHM units 0/1 are created
> root-only. This works here because chronyd creates/attaches the segment
> *while still root* at startup — which is also why **chronyd must start
> before or at the same time as gpsd is delivering data, and restarting
> gpsd alone is safe, but if chronyd is ever restarted by hand it must be
> restarted the same way the entrypoint does it** (as root with `-u
> chrony`), never directly as the chrony user.

**Pass criteria:** NTP0 SHM segment present; `sourcestats` shows samples
accumulating for both GPS and PPS.

---

## Layer 5 — chrony lock

1. **Source selection:**

   ```bash
   chronyc sources
   ```

   Healthy steady-state (after ~5–15 minutes of warm-up):

   ```
   MS Name/IP address         Stratum Poll Reach LastRx Last sample
   ===============================================================================
   #x NMEA                          0   0   377     0    +87ms[  +87ms] +/- 1000us
   #* PPS                           0   3   377    10   -310ns[   +9ns] +/- 13ms
   ```

   How to read this:
   - `#* PPS` — the **`*` on PPS is the single most important character in
     this whole guide**: chrony is synchronized to the PPS refclock.
   - `#x NMEA/GPS` — `x` (false ticker) on the NMEA source is **normal and
     expected**: NMEA serial time is jittery and chrony correctly rejects
     it for steering while still using it (via `lock GPS`) to number the
     PPS pulses.
   - `Reach 377` — octal bitmask of the last 8 polls; `377` = 8/8 received.
     Anything persistently below `377` after warm-up means dropped samples.
   - `?` on both sources — no data at all; go back to Layer 4.
   - `#* GPS` with PPS at `?` or `x` — running on NMEA only; time will be
     off by milliseconds, not microseconds. PPS path is broken.

2. **Tracking quality:**

   ```bash
   chronyc tracking
   ```

   Pass thresholds for a locked PPS system:

   | Field | Expect | Meaning if out of range |
   |-------|--------|--------------------------|
   | Reference ID | `(PPS)` | Locked to something else / nothing |
   | Stratum | `1` | Not serving as a GPS-disciplined stratum 1 |
   | Leap status | `Normal` | `Not synchronised` = not locked yet or lost lock |
   | System time | < 10 µs of NTP time | Still converging, or NMEA-only lock |
   | RMS offset | < 100 µs after 1 h | Jitter problem (check PPS, Layer 2) |
   | Skew | < 1 ppm after 1 h | Unstable oscillator/thermal, or recent start |

   Note: immediately after startup, `RMS offset` will be dominated by the
   initial step — judge it after an hour of uptime.

3. **The false-lock trap.** `chrony.conf` uses `local stratum 1`, so this
   server will *claim* stratum 1 even with the antenna unplugged. **Never
   verify with stratum alone.** `Reference ID : (PPS)` + `Leap status :
   Normal` is the real test of lock.

**Pass criteria:** `#*` on PPS, Reference ID `(PPS)`, Leap status
`Normal`, System time within microseconds.

---

## Layer 6 — NTP service to clients

1. **Chrony is answering clients** (run on the container after at least one
   client has queried):

   ```bash
   chronyc clients
   ```

2. **From another machine on the network:**

   ```bash
   # any of, depending on what's installed on the client:
   chronyd -Q 'server <server-ip> iburst'      # one-shot measurement
   ntpdate -q <server-ip>
   chronyc -h <server-ip> tracking             # will fail: cmdport 0 — expected
   ```

   Expect stratum 1 and offset consistent with your network path (LAN:
   tens to hundreds of µs). Note `chrony.conf` sets `cmdport 0`, so remote
   `chronyc` monitoring is intentionally disabled — only NTP (123/udp)
   is served. Confirm the port mapping `123:123/udp` exists in
   `compose.yaml`.

3. **Point a real client at it** and verify the client's own
   `chronyc sources` selects this server with a sane offset.

**Pass criteria:** external client gets stratum-1 responses with expected
LAN-level offsets.

---

## Layer 7 — Ongoing health

1. **Docker healthcheck.** `chronyc tracking` exits 0 even when
   unsynchronized, so the stock `HEALTHCHECK` only proves chronyd is alive,
   not that time is valid. A meaningful check is:

   ```dockerfile
   HEALTHCHECK --interval=60s --timeout=10s --start-period=300s \
     CMD chronyc tracking | grep -q "Leap status *: Normal" || exit 1
   ```

   (`--start-period` matters: GPS cold start + chrony convergence can take
   several minutes and shouldn't count as failure.)

2. **Periodic spot-check** (cron on the host, or manual):

   ```bash
   sudo docker exec gpsd-chrony chronyc tracking | grep -E "Reference ID|Leap status|System time"
   ```

3. **Log review.** `chrony.conf` enables `log tracking measurements
   statistics` into `logdir`; the tracking log's offset column should stay
   in the sub-10 µs band. `logchange 0.1` also emits a syslog line any time
   chrony steps more than 100 ms — any such line after initial startup is
   an incident worth investigating.

4. **Long-term drift/offset analysis:** use
   [`calibration/CHRONY_OFFSET_CALIBRATION.md`](calibration/CHRONY_OFFSET_CALIBRATION.md)
   and `chrony_statistics_analyzer.py` for offset calibration once the
   basic verification passes.

---

## Troubleshooting quick reference

| Symptom | First check | Likely cause |
|---|---|---|
| Container restart loop | `docker logs` | Missing device node; chronyd config error |
| Log spams `ERROR: gpsd died` but gpsd is running | `ps` inside container | Monitor tracking a stale PID (gpsd daemonized; parent PID recorded) — see note below |
| Multiple gpsd processes in `ps` | startup log restart lines | Same stale-PID bug: monitor respawning gpsd every interval |
| `ppstest` silent, gpsd has 3D fix | wiring / dtoverlay | PPS pin not reaching the kernel |
| gpsd `mode:1` forever | antenna sky view, `cgps` SNR column | No fix — antenna placement or receiver power |
| `sourcestats` GPS row NP=0 | `ipcs -m` | SHM handoff broken (gpsd started without data / chronyd restarted wrongly) |
| `sources` shows PPS `?` | Layer 2, then gpsd log for the PPS device on its command line | chrony can't get PPS samples |
| Locked to GPS (`#* GPS`), PPS rejected | `refclock PPS ... lock GPS` names must match `refid` of the SHM source | Millisecond-only accuracy |
| Client gets stratum 1 but time is wrong | `chronyc tracking` Leap status | `local stratum 1` masking a lost lock |

### Note on the entrypoint monitor (known defect)

The `monitor_services` loop in `entrypoint.sh` checks the PID captured from
`gpsd ... &`. Because gpsd **daemonizes by default** (it is not started
with `-N`), that PID belongs to a parent process that exits immediately —
so the check fails on every cycle, and with `RESTART_ON_FAILURE=true` the
monitor spawns a new gpsd every `MONITOR_INTERVAL` seconds. Until the
entrypoint is fixed (run gpsd with `-N`, or supervise with `wait -n`
instead of PID files), treat monitor output as unreliable and verify
process health with Layer 1 step 3 instead.

---

## Acceptance checklist

- [ ] L0: `GPS_DEVICE` and `PPS_DEVICE` nodes exist on host; no host NTP daemon active
- [ ] L1: container `Up`; exactly one `gpsd` and one `chronyd` process; clean startup log
- [ ] L2: `ppstest` shows 1 Hz asserts, sequential
- [ ] L3: `gpspipe -w` shows `"mode":3` TPV and `PPS` messages
- [ ] L4: NTP0 SHM segment present; `sourcestats` NP growing for GPS and PPS
- [ ] L5: `chronyc sources` shows `#*` on PPS; `tracking` shows Ref ID `(PPS)`, Leap `Normal`, offset < 10 µs
- [ ] L6: external client syncs at stratum 1 with LAN-level offset
- [ ] L7: healthcheck validates Leap status (not just chronyd liveness); no `logchange` step events after warm-up
