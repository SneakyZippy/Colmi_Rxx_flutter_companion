# 💍 Colmi Ring Command Status

## ✅ Verified Working
These commands behave exactly as expected.

| Feature | Command (HEX) | Description | Notes |
| :--- | :--- | :--- | :--- |
| **Reboot** | `08` | **System Reboot** | 🛑 **Best Kill Switch**. Stops all lights/sensors immediately. |
| **Heart Rate** | `69 01 01` | **Start HR** | Starts Green Light. |
| **Raw Data** | `A1 04` | **Enable Raw** | Starts streaming (Green+Red+Accel). |
| **Raw Data** | `A1 02` | **Disable Raw** | Stops streaming data packets. |

---

## ⚠️ Ambiguous / Triggers
These commands were thought to be "Stop" but appear to **Start** or **Re-trigger** the sensors.

| Feature | Command (HEX) | Description | Issue |
| :--- | :--- | :--- | :--- |
| **Stop HR** | `69 01 00` | **Stop HR??** | 🚨 **TRIGGERS GREEN LIGHT**. Likely "Start with param 0". |
| **Stop SpO2** | `69 03 00` | **Stop SpO2??** | 🚨 **TRIGGERS RED LIGHT**. Returns `6C` (Running). |
| **Stop SpO2** | `69 03 FF` | **Stop SpO2??** | Failed. |

## 🛑 Limitations
*   **Active Measurements**: Once a measurement starts (Green or Red light), it **CANNOT** be interrupted by software commands. It must finish its cycle (approx 45s).
*   **Reboot**: The only way to immediately kill a running light is the **Reboot (0x08)** command.

## 🛠️ Passive Disables (Force Stop)
We are now relying on these to stop the lights without re-triggering them.

| Feature | Command (HEX) | Description | Expected Behavior |
| :--- | :--- | :--- | :--- |
| **Heart Rate** | `16 02 00` | Disable HR Monitor | Stops periodic Green Light checks. |
| **SpO2** | `2C 02 00` | Disable SpO2 Monitor | Stops periodic Red Light checks. |
| **Stress** | `36 02 00` | Disable Stress Monitor | Disable periodic Stress checks. |

## 📝 Summary
*   **0x69 commands** seem to **ALWAYS START** the sensor. Do not use them for stopping.
*   **Force Stop Strategy**: Only send `0x16`, `0x2C`, `0x36`, and `0xA1` disables. If that fails, use **Reboot (0x08)**.
