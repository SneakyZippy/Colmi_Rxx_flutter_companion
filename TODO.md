# 🗺️ Project Roadmap & TODOs

## 🚨 High Priority (Critical)
- [ ] **Data Reset Bug:** Fix issue where Steps and HR data resets incorrectly after midnight (00:00) or when staying up late.
- [ ] **History Sync:** Implement logic to download saved sleep/heart rate data from the ring's flash memory.
- [ ] **Local Database:** Set up `hive` or `sqflite` to persist downloaded data so it remains available after closing the app.
- [ ] **SpO2 Monitoring:** Add support for live blood oxygen data parsing and visualization.

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