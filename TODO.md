# 🗺️ Project Roadmap & TODOs

## 🔭 Open Tasks (Immediate Next Steps)
- [ ] **Data Visualization:**
    - [ ] Real-time graph for Heart Rate (Live).
    - [ ] Real-time graph for SpO2 (Live).
    - [ ] Historical charts for all sensors. (spo2 not working)
- [ ] **Wear Detection:**
    - [ ] Refine "Wear Status" logic (currently based on simple PPG limits).
    - [ ] Investigate valid ranges for "Off Finger" vs "On Finger".
- [ ] **Gestures & Actions:**
    - [ ] Decode `0x2F` packets (Tap/Spin detection).
    - [ ] Implement "Music Control" or "Slide Control" using ring gestures.
- [ ] **Code Cleanup:**
    - [ ] Remove unused debug prints.
    - [ ] Organize `PacketFactory` and `BleService` into cleaner modules.

## 🚨 High Priority (Critical)
- [x] **Data Reset Bug:** Fix issue where Steps and HR data resets incorrectly after midnight (00:00) or when staying up late.
- [x] **History Sync:** Implement logic to download saved sleep/heart rate data from the ring's flash memory.
- [ ] **Local Database:** Set up `hive` or `sqflite` to persist downloaded data so it remains available after closing the app.
- [ ] **SpO2 Monitoring:** Basic measurement and history sync implemented. (Visualization pending).

## 🟠 Medium Priority
- [x] **Sync Time:** Add button to sync phone time to ring (Fixes display issues).
- [ ] **Settings Page:** Create a dedicated screen for app preferences and device management.
- [ ] **Auto-Reconnect:** Add logic to attempt reconnection if the ring disconnects unexpectedly (e.g., out of range).
- [ ] **Bluetooth State:** Show a "Please turn on Bluetooth" prompt if the phone's adapter is disabled.

## 🟢 Low Priority (Features & UI)
- [ ] **Step Goal:** Send packet to update the "Daily Step Goal" so the ring's progress circle matches the app.
- [ ] **User Profile:** Send height/weight/age packets (Required for accurate calorie calculations).
- [ ] **Splash Screen:** Add a branded launch screen for a professional look.
- [ ] **Error Handling:** Replace crashes or silent failures with friendly "Toast" error messages.
- [ ] **Find My Ring:** Implement the command to make the ring vibrate/flash.

## 🛠️ Code Quality & Maintenance
- [ ] **Refactor BleService:** Improve timeout handling if the ring doesn't respond to a command.
- [ ] **Linting:** Add `flutter_lints` rules to enforce clean code standards.
- [ ] **Dark/Light Mode:** Implement logic to respect the system theme.



## Not Sorted
- [ ] **Delete Stats function:** A way to delete stats for better debugging.
- [x] **Zoom Graph** Allow zooming in and out of the graph
- [x] **Graphs** Fix graphs
- [ ] **spO2** Add spO2 to the graphs
- [x] **Graphs** When switching to a graph it should only show timeframe from where the data is viable





