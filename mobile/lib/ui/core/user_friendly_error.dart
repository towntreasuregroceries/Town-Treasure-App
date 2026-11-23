import 'package:flutter/services.dart';

/// Converts technical Dart/Flutter/HTTP/Supabase exceptions into calm,
/// plain-language messages suitable for end users.
class UserFriendlyError {
  UserFriendlyError._();

  static String format(
    Object error, {
    String fallback = 'Something went wrong. Please try again.',
  }) {
    if (error is PlatformException) {
      final code = error.code.trim();
      final codeLower = code.toLowerCase();
      final rawMsg = (error.message ?? '').trim();
      final msgLower = rawMsg.toLowerCase();

      if (codeLower.contains('camera') ||
          codeLower.contains('permission') ||
          codeLower.contains('denied') ||
          msgLower.contains('camera') ||
          msgLower.contains('permission')) {
        return 'Permission is needed to access this feature. Please allow access in your phone settings and try again.';
      }
      if (codeLower == 'busy' || codeLower == 'already_active') {
        return 'The file picker is already open or finishing a previous request. Please try again.';
      }
      if (codeLower == 'invalid_image') {
        return 'That photo could not be read. Please choose a JPG or PNG image or take a new photo.';
      }
      if (codeLower == 'exception encountered') {
        return 'Your phone secure key store was reset after an update. Re-enter your account password to restore your encryption key and try again.';
      }
      if ((codeLower == 'doc_read_error' ||
              codeLower == 'pdf_render_error' ||
              codeLower == 'picker_error') &&
          rawMsg.isNotEmpty &&
          !rawMsg.contains('\n') &&
          !msgLower.contains('exception')) {
        return rawMsg;
      }
      if (code.isNotEmpty) {
        return 'Could not complete that action ($code). Please try again.';
      }
      return fallback;
    }

    var msg = error.toString().trim();
    if (msg.isEmpty) return fallback;

    for (final prefix in const [
      'ApkVerificationException:',
      'VaultSyncException:',
      'AuthApiException:',
      'AuthException:',
      'Bad state:',
      'Invalid argument(s):',
      'Exception:',
      'ClientException:',
      'SocketException:',
      'HandshakeException:',
    ]) {
      if (msg.startsWith(prefix)) {
        msg = msg.substring(prefix.length).trim();
      }
    }

    final lower = msg.toLowerCase();

    if (lower.contains('socketexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('connection refused') ||
        lower.contains('network is unreachable') ||
        lower.contains('software caused connection abort') ||
        lower.contains('connection timed out') ||
        lower.contains('timed out')) {
      return 'No internet connection or the server took too long to respond. Please check your connection and try again.';
    }

    if (lower.contains('status 404') || lower.contains('status 444')) {
      return 'The update file could not be found on the server yet. Please try again later or ask support for the latest installer.';
    }

    if (lower.contains('status 429') || lower.contains('too many requests')) {
      return 'Too many requests right now. Please wait a minute and try again.';
    }

    if (lower.contains('status 500') ||
        lower.contains('status 502') ||
        lower.contains('status 503') ||
        lower.contains('status 504')) {
      return 'The server is temporarily busy. Please try again in a moment.';
    }

    if (lower.contains('null object reference') ||
        lower.contains('getclass()')) {
      return 'The on-device text scanner had a problem reading that photo. Please try a clearer, well-lit photo.';
    }

    if (lower.contains('platformexception(')) {
      if (lower.contains('camera') || lower.contains('permission')) {
        return 'Permission is needed to access this feature. Please allow access in your phone settings and try again.';
      }
      return fallback;
    }

    if (lower.contains('formatexception') ||
        lower.contains('unexpected character')) {
      return 'The server returned an unexpected response. Please try again shortly.';
    }

    if (msg.startsWith('Manifest request failed') ||
        msg.startsWith('Manifest JSON must be')) {
      return 'Could not check for updates right now. Please try again later.';
    }

    if (msg.startsWith('APK download failed')) {
      return 'Could not download the app update. Please check your connection and try again.';
    }

    if (msg.startsWith('APK SHA-256 mismatch') ||
        msg.startsWith('APK failed pre-install')) {
      return 'The downloaded update did not pass safety verification and was removed. Please try downloading again.';
    }

    return msg;
  }
}
