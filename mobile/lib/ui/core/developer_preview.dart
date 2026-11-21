import 'package:flutter/foundation.dart';

import '../../data/services/remote_update_service.dart';

/// Controls developer-only preview access for redesigned UI themes/widgets and
/// isolated preview OTA manifest routing before broad rollout to Veronica & staff.
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

/// Live toggle so the developer (`onderegerald@gmail.com`) can flip between the
/// Redesigned v2 UI and Classic UI on-device while non-developer accounts always
/// stay on the approved Classic UI.
class DeveloperPreviewController extends ChangeNotifier {
  bool _redesignedUiEnabled = true;

  bool get redesignedUiEnabled => _redesignedUiEnabled;

  bool isRedesignedUiActiveFor(String? email) =>
      DeveloperPreviewConfig.isDeveloperEmail(email) && _redesignedUiEnabled;

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
