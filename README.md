# Colmi R12 Smart Ring Companion (Flutter)

An open-source, unofficial companion application for the **Colmi R12 Smart Ring** (and compatible "Yawell" protocol devices like R02, R10). Built with **Flutter** and **flutter_blue_plus**.

## 🚀 Features

*   **Device Scanning:** Filters specifically for R12/R02/Rxx/Ring devices.
*   **Live Monitoring:** Real-time Heart Rate, SpO2, HRV and Stress monitoring.
*   **Data Sync:** Granular synchronization of historic logs (Sleep, Steps, HR, HRV Stress) from the ring's flash memory.
*   **Protocol Debugging:** Built-in console to view raw HEX packets for reverse-engineering.
*   **Cross-Platform:** Runs on **Android** and **iOS**.

## 📥 Downloads

Get the latest APK here:
[Download from pCloud](https://e.pcloud.link/publink/show?code=kZ8P9aZgbt0ntiX9U76pWP4QRJwIbJkGHfX)

## 📸 Screenshots

| Home Screen | Live Monitor | History |
| :---: | :---: | :---: |
| ![Home](screenshots/home_placeholder.png) | ![Live](screenshots/live_placeholder.png) | ![History](screenshots/history_placeholder.png) |


## 🛠️ Tech Stack

* **Framework:** Flutter (Dart)
* **Bluetooth:** [`flutter_blue_plus`](https://pub.dev/packages/flutter_blue_plus)
* **State Management:** Provider
* **Protocol:** Custom implementation of the "Yawell" UART protocol (BlueX chipset).

## 📦 Getting Started

### Prerequisites
* Flutter SDK (3.0+)
* Android Studio / VS Code
* Physical Device (Simulators cannot use Bluetooth)

### Installation

1.  **Clone the repository:**
    ```bash
    git clone [https://github.com/SneakyZippy/colmi_r12_flutter_companion.git](https://github.com/SneakyZippy/colmi_r12_flutter_companion.git)
    cd colmi_r12_flutter_companion
    ```

2.  **Install dependencies:**
    ```bash
    flutter pub get
    ```

3.  **Run the app:**
    ```bash
    flutter run
    ```

## ⚠️ Important Configuration

### Android
This app uses permissions requiring Android 12+ configuration.
* Ensure your `AndroidManifest.xml` includes `BLUETOOTH_SCAN` (neverForLocation) and `BLUETOOTH_CONNECT`.
* Location services must be enabled on the phone for scanning to work.

### iOS
* Ensure `Info.plist` contains `NSBluetoothAlwaysUsageDescription`.

## 📚 Protocol & Acknowledgements

This project is a clean-room implementation based on the reverse-engineering work of the open-source community. Special thanks to:

* **[tahnok/colmi_r02_client](https://github.com/tahnok/colmi_r02_client):** For the Python documentation of the packet structure and checksum logic.
* **[CitizenOneX/colmi_r06_fbp](https://github.com/CitizenOneX/colmi_r06_fbp):** For insights into Dart stream handling for this chipset.
* **Gadgetbridge:** For valid command references.

## 🤝 Contributing

Contributions are welcome! If you find a new Command ID, please open an Issue or PR with the hex code.

## 📄 License

Distributed under the MIT License. See `LICENSE` for more information.

---
**Disclaimer:** This software is unofficial and not affiliated with Colmi or Yawell. Use at your own risk.
