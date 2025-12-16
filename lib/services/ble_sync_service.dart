import 'dart:async';
import 'package:flutter/foundation.dart';
import 'ble_command_service.dart';

class BleSyncService {
  final BleCommandService _commandService;
  final bool Function() _isConnected;
  final void Function(String) _log;
  final DateTime Function() _getSelectedDate;

  // Smart Sync State
  DateTime? _lastSyncTime;
  Timer? _periodicSyncTimer;
  final Duration _syncInterval = const Duration(minutes: 60);
  final Duration _minSyncDelay = const Duration(minutes: 15);

  BleSyncService(
    this._commandService, {
    required bool Function() isConnected,
    required void Function(String) log,
    required DateTime Function() getSelectedDate,
  })  : _isConnected = isConnected,
        _log = log,
        _getSelectedDate = getSelectedDate;

  /// Triggers a sync if conditions are met (Interval elapsed or manual override)
  /// [force] : By-pass throttle logic (e.g. Pull-to-Refresh)
  Future<void> triggerSmartSync({bool force = false}) async {
    if (!_isConnected()) {
      debugPrint("Smart Sync Ignored: Disconnected");
      return;
    }

    final now = DateTime.now();
    if (!force && _lastSyncTime != null) {
      final elapsed = now.difference(_lastSyncTime!);
      if (elapsed < _minSyncDelay) {
        debugPrint(
            "Smart Sync Throttled: Last sync was ${elapsed.inMinutes} mins ago (Min: ${_minSyncDelay.inMinutes})");
        return;
      }
    }

    debugPrint("Triggering Smart Sync...");
    await startFullSyncSequence();
    _lastSyncTime = DateTime.now();
  }

  void startPeriodicSyncTimer() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = Timer.periodic(_syncInterval, (timer) {
      debugPrint("Periodic Sync Triggered");
      triggerSmartSync();
    });
  }

  void stopPeriodicSyncTimer() {
    _periodicSyncTimer?.cancel();
    _periodicSyncTimer = null;
  }

  Future<void> startFullSyncSequence() async {
    if (!_isConnected()) return;

    try {
      final selectedDate = _getSelectedDate();
      final now = DateTime.now();
      final difference = now.difference(selectedDate).inDays;
      int offset = difference < 0 ? 0 : difference;

      debugPrint(
          "Requesting Steps for Offset: $offset (${selectedDate.toString()})");

      await _commandService.fetchActivityHistory();

      // Explicitly chain other syncs
      await Future.delayed(const Duration(seconds: 2));
      await _commandService.fetchHeartRateHistory();

      await Future.delayed(const Duration(seconds: 2));
      await _commandService.fetchSpo2History();
      await Future.delayed(const Duration(seconds: 4));

      await _commandService.fetchStressHistory();
      await Future.delayed(const Duration(seconds: 2));

      await _commandService.fetchSleepHistory();
      await Future.delayed(const Duration(seconds: 4));

      await syncHrvHistory();

      _log("Full Sync Completed");
    } catch (e) {
      debugPrint("Error syncing history: $e");
    }
  }

  Future<void> syncHeartRateHistory() async {
    if (!_isConnected()) return;
    try {
      await _commandService.fetchHeartRateHistory();
    } catch (e) {
      debugPrint("Error syncing HR history: $e");
    }
  }

  Future<void> syncSpo2History() async {
    if (!_isConnected()) return;
    try {
      await _commandService.fetchSpo2History();
    } catch (e) {
      debugPrint("Error syncing SpO2 history: $e");
    }
  }

  Future<void> syncStressHistory() async {
    if (!_isConnected()) return;
    try {
      await _commandService.fetchStressHistory();
    } catch (e) {
      debugPrint("Error syncing Stress history: $e");
    }
  }

  Future<void> syncSleepHistory() async {
    if (!_isConnected()) return;
    try {
      await _commandService.fetchSleepHistory();
    } catch (e) {
      debugPrint("Error syncing Sleep history: $e");
    }
  }

  Future<void> syncStepsHistory() async {
    if (!_isConnected()) return;
    try {
      await _commandService.fetchActivityHistory();
    } catch (e) {
      debugPrint("Error syncing Steps history: $e");
    }
  }

  Future<void> syncHrvHistory() async {
    if (!_isConnected()) return;
    try {
      debugPrint("Requesting HRV History (0x39 Experimental)...");
      await _commandService.fetchHrvHistory();
    } catch (e) {
      debugPrint("Error syncing HRV history: $e");
    }
  }

  void dispose() {
    _periodicSyncTimer?.cancel();
  }
}
