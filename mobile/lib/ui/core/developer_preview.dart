import 'package:flutter/foundation.dart';

import '../../data/services/remote_update_service.dart';

/// Controls developer-only preview OTA manifest routing (`dev-update.json`) and
/// exposes the live Executive Dashboard UI toggle (`UI v2` default for all
/// owners, with optional Classic UI comparison fallback for the developer).
class DeveloperPreviewConfig {
  DeveloperPreviewConfig._();

  static const String developerEmail = 'onderegerald@gmail.com';
  static const String devManifestUrl =
      'https://towntreasuregroceries.github.io/Town-Treasure-App/dev-update.json';
  static const String prodOwnerManifestUrl =
      RemoteUpdateService.defaultOwnerManifestUrl;

  static bool isDeveloperEmail(String? email) =>
      (email ?? '').trim().toLowerCase() == developerEmail;

  /// Routes the default owner update channel to `dev-update.json` ONLY when
  /// signed in as `onderegerald@gmail.com`. Custom test URLs are preserved.
  static String resolveManifestUrl(String? email, String configuredUrl) {
    final trimmed = configuredUrl.trim();
    if (isDeveloperEmail(email) &&
        (trimmed == prodOwnerManifestUrl ||
            trimmed ==
                'https://towntreasuregroceries.github.io/Town-Treasure-App/app-update.json')) {
      return devManifestUrl;
    }
    return configuredUrl;
  }
}

/// Official Executive Dashboard controller (`UI v2` enabled by default for all
/// owner accounts, with a developer fallback toggle to compare Classic UI).
class DeveloperPreviewController extends ChangeNotifier {
  bool _redesignedUiEnabled = true;

  bool get redesignedUiEnabled => _redesignedUiEnabled;

  bool isRedesignedUiActiveFor(String? email) => _redesignedUiEnabled;

  void setRedesignedUiEnabled(bool enabled) {
    if (_redesignedUiEnabled == enabled) return;
    _redesignedUiEnabled = enabled;
    notifyListeners();
  }

  void toggleRedesignedUi() {
    _redesignedUiEnabled = !_redesignedUiEnabled;
    notifyListeners();
  }
}
