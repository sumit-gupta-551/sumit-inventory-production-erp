import 'package:shared_preferences/shared_preferences.dart';

class SyncHelper {
  static const String _legacyLastAttendanceSyncKey = 'last_attendance_sync';
  static const String _lastAttendanceSyncProductionIdKey =
      'last_attendance_sync_prod_id';

  /// Returns last synced production entry id for attendance auto-sync.
  /// Handles migration from legacy timestamp-based key.
  static Future<int?> getLastAttendanceSync() async {
    final prefs = await SharedPreferences.getInstance();

    final id = prefs.getInt(_lastAttendanceSyncProductionIdKey);
    if (id != null) return id;

    final legacy = prefs.getInt(_legacyLastAttendanceSyncKey);
    if (legacy == null) return null;

    // Legacy values were epoch milliseconds (~1.7e12), not production ids.
    if (legacy > 2000000000) {
      await prefs.remove(_legacyLastAttendanceSyncKey);
      return null;
    }

    return legacy;
  }

  static Future<void> setLastAttendanceSync(int productionEntryId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastAttendanceSyncProductionIdKey, productionEntryId);
  }
}
