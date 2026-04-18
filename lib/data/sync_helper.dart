import 'package:shared_preferences/shared_preferences.dart';

class SyncHelper {
  static const String _lastAttendanceSyncKey = 'last_attendance_sync';

  static Future<int?> getLastAttendanceSync() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_lastAttendanceSyncKey);
  }

  static Future<void> setLastAttendanceSync(int timestamp) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastAttendanceSyncKey, timestamp);
  }
}
