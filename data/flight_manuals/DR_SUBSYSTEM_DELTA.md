# DR-SUBSYSTEM-DELTA — Delta Power Bus Disaster Recovery Runbook

> **FICTIONAL TRAINING DOCUMENT — Project Critical Orbit bootcamp scenario.**
> Issuing body: Orbital Dynamics Directorate (fictional). Document class:
> RECOVERY — Level 2. Revision 2C.

## 1. Purpose

Recovery procedure for the DELTA power bus aboard fictional Aurora-class
spacecraft. The Delta bus feeds the telemetry encoder and the attitude
determination heaters.

## 2. Symptoms Requiring This Runbook

| Symptom | Telemetry field | Threshold |
|---|---|---|
| Bus undervoltage | `delta_bus_v` | < `26.4 V` |
| Charge controller fault | `ccu_fault` | `true` |
| Heater overcurrent | `heater_i` | > `4.2 A` |
| Encoder reset loop | `encoder_resets` | > `3 / hour` |

## 3. Recovery Sequence

Execute in order. Each step has a **verify gate** — do not proceed if the gate
fails; escalate to the on-call Guidance Officer (fictional role).

### Step 1 — Isolate the heater string

Command: `DELTA-HTS-OFF` (protected command — requires Level 4 authorization).

- Verify gate: `heater_i` drops to `0.0 A` within 30 s.
- If `heater_i` remains > `0.5 A`: **STOP**, declare `BUS-LOCK` and follow
  section 5 (safe-hold).

### Step 2 — Power-cycle the charge controller

Command: `DELTA-CCU-CYCLE`.

- Verify gate: `ccu_fault` clears within 90 s.
- Constraint: maximum two cycles per orbit. A third cycle requires a Level 4
  directive.

### Step 3 — Restore telemetry encoder

Command: `DELTA-ENC-RESET`.

- Verify gate: `encoder_resets` stops incrementing; `delta_bus_v` recovers to
  `27.8 V ± 0.4 V` within 120 s.

### Step 4 — Re-enable heater string

Command: `DELTA-HTS-ON` (protected command — Level 4).

- Verify gate: `heater_i` stabilizes at `3.1 A ± 0.3 A`.

## 4. Data Handling During Recovery

- All telemetry frames from `T-10 min` to recovery `+10 min` are flagged
  `RECOVERY-CANDIDATE` and mirrored to the blackbox store
  (`10.42.20.15`, fictional).
- Do not purge the blackbox until the Guidance Officer signs off.

## 5. Safe-Hold (Bus-Lock)

If any verify gate fails twice:

1. Command `DELTA-SAFE-HOLD` (Level 4).
2. Spacecraft enters Sun-pointing safe mode; Delta bus is latched off.
3. Recovery resumes only after a go/no-go review.

## 6. Notes for Console Operators

- Telemetry anomalies during this procedure are *expected*; the Flight
  Director AI may flag them — confirm each flag against this runbook before
  acknowledging.
- Never run `DELTA-*` commands during a `LINK-DOWN` incident.

---
*End of DR-SUBSYSTEM-DELTA. Revision 2C. Fictional training material only.*
