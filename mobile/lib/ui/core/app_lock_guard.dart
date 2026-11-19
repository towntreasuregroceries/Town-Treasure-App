/// Coordinates temporary suppression of background screen-lock when the app
/// intentionally hands off control to an Android system activity (camera,
/// gallery picker, share sheet, print dialog, WhatsApp/browser intent, or
/// in-app biometric confirmation).
class AppLockGuard {
  AppLockGuard._();

  static int _suppressDepth = 0;

  static bool get isSuppressed => _suppressDepth > 0;

  static Future<T> runWithoutRelock<T>(Future<T> Function() action) async {
    _suppressDepth++;
    try {
      return await action();
    } finally {
      if (_suppressDepth > 0) {
        _suppressDepth--;
      }
    }
  }
}
