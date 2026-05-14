import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Android foreground service wrapper for keeping voice mode alive
/// while app is in background.
class VoiceForegroundService {
  static const int _serviceId = 7710;
  static bool _initialized = false;

  static void ensureInitialized() {
    if (!Platform.isAndroid || _initialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'voice_listen_channel',
        channelName: 'Voice Listening',
        channelDescription:
            'Keeps voice listening active while app is in background',
        onlyAlertOnce: true,
        playSound: false,
        showWhen: true,
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(10000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _initialized = true;
  }

  static Future<bool> start() async {
    if (!Platform.isAndroid) return false;
    ensureInitialized();
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Voice listening active',
        notificationText: 'Super user mode running in background',
      );
      return true;
    }
    await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      notificationTitle: 'Voice listening active',
      notificationText: 'Super user mode running in background',
      callback: _voiceForegroundStartCallback,
    );
    return FlutterForegroundTask.isRunningService;
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}

@pragma('vm:entry-point')
void _voiceForegroundStartCallback() {
  FlutterForegroundTask.setTaskHandler(_VoiceForegroundTaskHandler());
}

class _VoiceForegroundTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {
    FlutterForegroundTask.updateService(
      notificationTitle: 'Voice listening active',
      notificationText: 'Super user mode running in background',
    );
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onReceiveData(Object data) {}

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp('/');
  }

  @override
  void onNotificationDismissed() {}
}
