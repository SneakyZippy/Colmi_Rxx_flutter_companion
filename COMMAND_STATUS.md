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
| **Config** | **Init** | `39 05` | Sent during pairing/binding. |
| **Binding** | **Request** | `48 00` | Bind Request/Check. Response `48 00 01` = Bound. |

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

## 4. 🧩 Verified Gadgetbridge Protocol Details

Based on `ColmiR0xConstants.java` and `ColmiR0xPacketHandler.java`:

### Control Commands
| Command | Name | Sub-Ops / Payload | Notes |
| :--- | :--- | :--- | :--- |
| **0x01** | Set Time | `YY MM DD HH MM SS` | `YY` is offset from 2000. |
| **0x03** | Get Battery | `03` | Response: `03 [Level] [ChargingState]` |
| **0x04** | Set Phone Name | `04 02 0A [NameBytes...]` | Used for initialization. |
| **0x0A** | User Settings | `0A 02 [Prefs...]` | Gender, Age, Height, Weight, BP, HR Alarm. |
| **0x08** | Power Off | `08 01` | Shuts down the ring. |
| **0x21** | Set Goals | `Step(4) Cal(4) Dist(4) Sport(2) Sleep(2)` | Little Endian integers. |
| **0x50** | Find Device | `50 55 AA` | Vibrates/Flashes ring. |

### Auto-Monitoring / Config (0x16, 0x2C, 0x36)
Structure: `[Cmd] [Op] [Enable] [Interval?]`
*   **Op Codes:** `0x01` (Read?), `0x02` (Write).
*   **Enable:** `0x00` (Disable), `0x01` (Enable).
*   **0x16 (HR):** Payload includes Interval (mins).
*   **0x2C (SpO2)** & **0x36 (Stress):** Simple Enable/Disable.

### Data Sync Commands
| Command | Data Type | Sub-Type | Notes |
| :--- | :--- | :--- | :--- |
| **0x43** | Activity History | - | **VERIFIED.** Samples every 15 mins. Byte 4 is `QuarterOfDay` index (0-95). |
| **0x37** | Stress History | - | **VERIFIED.** **NOT Set Time.** Returns history. **Quirk:** Packet 1 starts at Index 3, others at Index 2. |
| **0x15** | HR History | - | **VERIFIED.** Returns HR samples. |
| **0xBC** | Big Data V2 | `0x27` (Sleep) | Sleep Stages (Light/Deep/Awake). |
| **0xBC** | Big Data V2 | `0x2A` (SpO2) | **VERIFIED.** SpO2 History samples. |

### Notifications (0x73)
Server-initiated updates arriving on Notify Characteristic.
*   `73 01`: New HR Data Available.
*   `73 03`: New SpO2 Data Available.
*   `73 04`: New Steps Data Available.
*   `73 0C`: Battery Level Update.
*   `73 12`: Live Activity Update.

---

## 5. 🔮 Missing/Unknown
*   **0x48**: Explicitly **absent** from Gadgetbridge constants. Likely a factory/debug command or deprecated.
*   **0x2F**: `CMD_PACKET_SIZE`? Unclear usage.
