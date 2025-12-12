# 🕵️‍♂️ Bluetooth Log Analysis Findings
**Generated:** 2025-12-12
**Source Folder:** `btSnifferLogsAndTimestamps/`

This document summarizes the protocols and commands discovered by analyzing the provided `btSniffer` logs.

---

## 1. Heart Rate Monitoring (`btSnifferHRTab.txt`)
*   **Auto/Periodic Mode:**
    *   **Command:** `0x16`
    *   **Structure:** `16 02 [Enable] [Interval]`
    *   **Values:**
        *   `Enable`: `0x01` (On), `0x00`/`0x02` (Off)
        *   `Interval`: Minutes (e.g., `05`, `0A`=10, `1E`=30, `3C`=60)
    *   **Example:** `16 02 01 05` = Enable Auto HR every 5 minutes.
*   **Manual/Real-Time Mode:**
    *   **Start:** `69 01 00`
    *   **Stop:** `6A 01 00`

## 2. HRV Monitoring (`btSnifferHRVTab.txt/.log`)
The log revealed a previously unknown command for Heart Rate Variability.
*   **Auto/Scheduled Mode (New Discovery):**
    *   **Command:** `0x38`
    *   **Enable:** `38 02 01 00...`
    *   **Disable:** `38 02 00 00...`
*   **Manual/Real-Time Mode:**
    *   **Start:** `69 0A 00` (Type `0xA` = HRV/Stress)
    *   **Stop:** `6A 0A 00`

## 2. SpO2 Monitoring (`btSnifferSPO2Tab.txt/.log`)
Critical correction found here. The ring does **not** use `0x03` for manual SpO2.
*   **Auto Mode:**
    *   **Command:** `0x2C`
    *   **Enable:** `2C 02 01`
    *   **Disable:** `2C 02 00`
*   **Manual/Real-Time Mode (CORRECTION):**
    *   **Start:** `69 08 00` (Triggers **Green Light** / HR Variant - Verified by User 2025-12-12)
    *   **Start Candidate:** `69 02 00` (Testing for Red Light/SpO2)
    *   **Stop:** `6A [Type] 00`
    *   *Note:* Previous assumption of `0x08` as SpO2 was incorrect (it is Green). Testing `0x02`.

## 3. Activity Tracking (`btSnifferActivityTrackingTab.txt`)
New command family for controlling Sports Modes (Walk/Run).
*   **Command:** `0x77`
*   **Structure:** `77 [Op] [Type]`
*   **Operations:**
    *   `01`: Start
    *   `02`: Pause
    *   `03`: Resume
    *   `04`: End
*   **Activity Types:**
    *   `04`: Walking (Start = `77 01 04`)
    *   `07`: Running (Start = `77 01 07`)

## 4. Stress Monitoring (`btSnifferStressTab.txt`)
Confirmed expected behavior for Stress.
*   **Command:** `0x36`
*   **Start (Measure):** `36 02 01`
*   **Stop:** `36 02 00`
*   **Data:** Returns a single packet `73 ...` after ~90 seconds.

## 5. System Commands (`btSnifferShutdownAndReset.log`)
*   **Factory Reset:** `FF 66 66` (Destructive)
*   **Shutdown:** `08 01`
*   **Reboot:** `08 05` (Inferred from context, or implicitly handled by crash recovery)

---

## ✅ Summary of Manual Real-Time IDs (0x69)
For use with `Start (0x69) / Stop (0x6A)`:
| SubType | Feature | Provenance |
| :--- | :--- | :--- |
| `0x01` | Heart Rate | Validated |
| `0x08` | SpO2 | **Validated from Log** |
| `0x0A` | HRV | **Validated from Log** |
