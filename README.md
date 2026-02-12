Colmi R12 Smart Ring Companion

This is an unofficial, open-source companion app for the Colmi R12 Smart Ring (and other rings using the "Yawell" protocol like the R02 and R10).

The official apps can be a bit bloated, so I built this with Flutter to be a lightweight alternative that focuses on data privacy and raw protocol access.
✨ What it does

    Easy Pairing: Scans specifically for R12/R02/Rxx rings so you aren't digging through a list of your neighbor's TVs.

    Live Stats: Real-time tracking for Heart Rate, SpO2, HRV, and Stress.

    Data Sync: Pulls your historical logs (Sleep, Steps, HR) directly from the ring's flash memory.

    Dev Tools: Includes a built-in HEX console. If you're into reverse-engineering, you can watch the raw packets move in real-time.

    Cross-Platform: Built for Android, and compatible with iOS.

📥 Quick Start (APK)

If you just want to try it out without building from source:
👉 Download the latest APK from pCloud
📸 App Preview
Dashboard	Settings	History
<img src="screenshots/Dashboard.png" width="300" />	<img src="screenshots/Settings.png" width="300" />	<img src="screenshots/HistoryHR.png" width="300" />
🛠 Tech Stuff

    Framework: Flutter / Dart

    Bluetooth: flutter_blue_plus

    State: Provider

    Protocol: Custom implementation of the Yawell UART protocol (BlueX chipset).

🚀 Setting up the Dev Environment
Prerequisites

    Flutter SDK (3.0+)

    A physical device (Bluetooth won't work on an emulator!)

Build Instructions

    Clone & Enter:
    Bash

    git clone https://github.com/SneakyZippy/colmi_r12_flutter_companion.git
    cd colmi_r12_flutter_companion

    Get Packages:
    Bash

    flutter pub get

    Run it:
    Bash

    flutter run

⚠️ Notes on Permissions

    Android: Needs Android 12+. Make sure BLUETOOTH_SCAN and BLUETOOTH_CONNECT are in your manifest. You also need Location Services ON for Bluetooth scanning to actually find devices.

    iOS: Ensure your Info.plist has the NSBluetoothAlwaysUsageDescription key.

🤝 Credits & Acknowledgements

This wouldn't exist without the community's work on reverse-engineering these rings:

    tahnok/colmi_r02_client - Essential docs on packet structure and checksums.

    CitizenOneX/colmi_r06_fbp - Helped with Dart stream handling.

    Gadgetbridge - The GOAT for command references.

Disclaimer: This is a hobby project. It’s not affiliated with Colmi or Yawell. Use it at your own risk, and don't rely on it for medical decisions!
