# 💍 Colmi Ring R02 - Protocol Reference & Knowledge Base

**Last Updated:** 2025-12-11
**Status:** Working

---

## 1. ✅ Verified Commands (Control)

| Feature | Action | HEX Command | Behavior / Notes |
| :--- | :--- | :--- | :--- |
| **Heart Rate** | **Auto Mode** | `16 02 01` | Enable Automatic Monitoring. |
| **Heart Rate** | **Manual Mode** | `16 02 00` | Disable Automatic / Stop Manual. |
| **SpO2** | **Auto Mode** | `2C 02 01` | Enable Automatic Monitoring. |
| **SpO2** | **Manual Mode** | `2C 02 00` | Disable Automatic / Stop Manual. |
| **Stress** | **Start** | `36 02 01` | **GOLDEN.** Start Measurement. |
| **Stress** | **Stop** | `36 02 00` | **GOLDEN.** Stop Measurement. |
| **Raw PPG** | **Stream** | `69 08` | Real-time PPG Waveform Stream. |
| **Unknown** | **Sensor** | `37 ...` | Likely Blood Pressure or Temp. |
| **Unknown** | **Sensor** | `39 ...` | Likely Blood Pressure or Temp. |

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

## 4. 💻 Implemented Commands (Found in Codebase)

These commands appear to be implemented and working in the current Flutter project.

| Feature | Action | HEX Command | Behavior / Notes |
| :--- | :--- | :--- | :--- |
| **Battery** | **Get Level** | `03` | Response at `data[1]`. |
| **Steps** | **Sync History** | `43 ...` | Complex 20-byte payload. |
| **Heart Rate** | **Sync History** | `15 ...` | Timestamp-based history sync. |
| **SpO2** | **Sync History** | `16 ...` | Timestamp-based history sync. |
| **System** | **Set Time** | `01 ...` | Time synchronization. |

---

## 5. 🔍 Observed in Logs (Needs Verification)

These commands were found in the provided `btsnoop_hci.log` files.

| Feature | Command | Notes |
| :--- | :--- | :--- |
| **State Sync** | `3B 01 ...` | **CONFIRMED.** Returns `3B 01 01 00 01`. Likely heartbeat or app-active signal. |
| **Unknown** | `02 ...` | `02 04`, `02 05`, `02 06`. Returns `02 00`. |
| **Handshake?** | `50 55 AA...` | Response `69 0C 01...`. Potential unlock/bond. |
| **Settings?** | `48 00...` | Response contains `C8` (200). |
| **Unknown** | `05 ...` | Complex sequence `05 04...`. |

---

## 6. 🔮 Future Roadmap (Unimplemented)

These commands were observed in logs but not yet built.

| Feature | Command (Decimal) | Hex Est. | Description |
| :--- | :--- | :--- | :--- |
| **Sleep Data** | `41067` | `A0 6B ...` | Syncs sleep history. |
| **Activity** | `41081` | `A0 79 ...` | Syncs daily steps/cal scores. |
| **Battery** | `?` | `?` | Need to find the "Get Battery" command. |
