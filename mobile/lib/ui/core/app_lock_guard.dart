/// Coordinates temporary suppression of background screen-lock when the app
/// intentionally hands off control to an Android system activity (camera,
/// gallery picker, ML Kit document scanner, share sheet, print dialog,
/// WhatsApp/browser intent, or in-app biometric confirmation).
///
/// Includes a brief post-return handoff window cleared automatically once the
/// host Activity finishes resuming, preventing Samsung/Android camera-return
/// lifecycle races from locking the user out immediately after taking a photo.
class AppLockGuard {
  AppLockGuard._();

  static int _suppressDepth = 0;
  static bool _awaitingResumeAfterExternal = false;
  static DateTime? _handoffExpiresAt;

  static bool get isSuppressed {
    if (_suppressDepth > 0) return true;
    if (_awaitingResumeAfterExternal) {
      final exp = _handoffExpiresAt;
      if (exp != null && DateTime.now().isBefore(exp)) {
        return true;
      }
      _awaitingResumeAfterExternal = false;
      _handoffExpiresAt = null;
    }
    return false;
  }

  /// Called by `AuthGate` when `AppLifecycleState.resumed` arrives so normal
  /// background locking re-arms immediately after returning from the external
  /// camera/picker activity.
  static void notifyAppResumed() {
    if (_suppressDepth == 0) {
      _awaitingResumeAfterExternal = false;
      _handoffExpiresAt = null;
    }
  }

  static Future<T> runWithoutRelock<T>(Future<T> Function() action) async {
    _suppressDepth++;
    _awaitingResumeAfterExternal = false;
    _handoffExpiresAt = null;
    try {
      return await action();
    } finally {
      if (_suppressDepth > 0) {
        _suppressDepth--;
      }
      if (_suppressDepth == 0) {
        _awaitingResumeAfterExternal = true;
        _handoffExpiresAt = DateTime.now().add(const Duration(seconds: 4));
      }
    }
  }
}
