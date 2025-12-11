# 💍 Colmi Ring R02 - Protocol Reference & Knowledge Base

**Last Updated:** 2025-12-11
**Status:** Working

---

## 1. ✅ Verified Commands (Control)

| Feature | Action | HEX Command | Behavior / Notes |
| :--- | :--- | :--- | :--- |
| **Heart Rate** | **Start** | `69 01 01` | Starts Green Light (Continuous). |
| **Heart Rate** | **Disable** | `16 02 00` | **USE TO STOP.** Kills the Green Light process. |
| **SpO2** | **Start** | `69 03 00` | Starts Red Light (Continuous). |
| **SpO2** | **Disable** | `2C 02 00` | **USE TO STOP.** Kills the Red Light process. |
| **Stress** | **Start** | `36 01` | Starts measurement. **NO VISIBLE LIGHT** (IR/Passive). |
| **Stress** | **Disable** | `36 02` | **USE TO STOP.** Kills the Stress process. |
| **Raw Data** | **Enable** | `A1 04` | Starts high-frequency Accel + PPG stream. |
| **Raw Data** | **Disable** | `A1 02` | Stops stream. |
| **System** | **Reboot** | `08` | **Nuclear Option.** Restarts ring. Useful if sensors freeze. |

> **⚠️ CRITICAL: DO NOT USE `0x69` TO STOP!**
> Sending `69 01 00` (Stop HR) or `69 03 00` (Stop SpO2) actually **RE-TRIGGERS** the measurement.
> *Always use the `Disable` commands (`16`, `2C`, `36`) to stop sensors.*

---

## 2. 📊 Data Parsing (RX)

| Feature | Packet Header | Value Byte | Expected Behavior |
| :--- | :--- | :--- | :--- |
| **Heart Rate** | `0x69` | `data[4]` | Arrives ~1/sec. Check Index 4. If 0, check Index 2. |
| **SpO2** | `0x2C`? | `data[?]` | *Needs verification.* Likely similar to HR. |
| **Stress** | `0x73` | `data[1]` | **DELAYED.** Arrives ~90 seconds after Start. Value at Index 1 (e.g., `0x12` = 18). |
| **Raw Accel** | `0xA1` | Multiple | High-speed stream. Needs specialized parsing. |

---

## 3. 🧠 Quirks & Lessons Learned

### The "90-Second Rule" (Stress)
*   **Symptom:** You press "Measure Stress", logs show "Success", but **nothing happens** for over a minute.
*   **Reality:** The ring captures HRV data silently (perhaps using invisible IR light) for ~90 seconds. It buffers the calculation and sends a **single** packet (`0x73`) at the end.
*   **Fix:** Don't time out early. Set safety timers to **120 seconds**.

### The "Ghost Start" (Heart Rate)
*   **Symptom:** You stop HR, but it immediately starts again (Green light flickers back on).
*   **Cause:** Using `0x69 [Type] 0x00` deals with "Real-Time Request" logic which the ring interprets as "Start".
*   **Fix:** Never use 0x69 to stop. Use **0x16** (Periodic Disable) instead.

### Background Interference
*   **Symptom:** Sensors fail to start (Light stays off) despite valid commands.
*   **Cause:** Another app (e.g., original "Da Fit" or "Colmi" app) running in background. Service: `NtQueueManager`.
*   **Fix:** Force Stop / Uninstall other ring apps. **Reboot Phone** to kill zombie BLE services.

### Hardware Freeze
*   **Symptom:** App sends Start, Ring ACKs, but **no light ever appears**.
*   **Cause:** Internal firmware state confusion.
*   **Fix:** Send **Reboot Command `0x08`** or place on charger to reset.

---

## 4. � Future Roadmap (Unimplemented)

These commands were observed in logs but not yet built.

| Feature | Command (Decimal) | Hex Est. | Description |
| :--- | :--- | :--- | :--- |
| **Sleep Data** | `41067` | `A0 6B ...` | Syncs sleep history. |
| **Activity** | `41081` | `A0 79 ...` | Syncs daily steps/cal scores. |
| **Battery** | `?` | `?` | Need to find the "Get Battery" command. |
