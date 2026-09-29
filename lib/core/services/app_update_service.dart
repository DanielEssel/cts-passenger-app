import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class AppUpdateInfo {
  final bool updateRequired;
  final String title;
  final String message;
  final String storeUrl;

  const AppUpdateInfo({
    required this.updateRequired,
    required this.title,
    required this.message,
    required this.storeUrl,
  });
}

class AppUpdateService {
  const AppUpdateService._();

  static Future<AppUpdateInfo> check() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final currentVersion = packageInfo.version;

    try {
      final snap = await FirebaseFirestore.instance
          .collection('app_config')
          .doc('mobile')
          .get();

      if (!snap.exists) {
        return _notRequired();
      }

      final data = snap.data()!;
      final minimumVersion =
          data['passengerMinimumVersion'] as String? ?? currentVersion;

      final storeUrl = data['passengerStoreUrl'] as String? ?? '';

      return AppUpdateInfo(
        updateRequired: _isVersionLower(
          currentVersion,
          minimumVersion,
        ),
        title: data['updateTitle'] as String? ?? 'Update required',
        message: data['updateMessage'] as String? ??
            'A newer version of CTSGo is required to continue.',
        storeUrl: storeUrl,
      );
    } catch (_) {
      // Do not prevent app startup if the configuration cannot be
      // reached. The existing application flow remains available.
      return _notRequired();
    }
  }

  static AppUpdateInfo _notRequired() {
    return const AppUpdateInfo(
      updateRequired: false,
      title: '',
      message: '',
      storeUrl: '',
    );
  }

  static bool _isVersionLower(String current, String minimum) {
    final currentParts = _parse(current);
    final minimumParts = _parse(minimum);

    for (var i = 0; i < 3; i++) {
      if (currentParts[i] < minimumParts[i]) return true;
      if (currentParts[i] > minimumParts[i]) return false;
    }

    return false;
  }

  static List<int> _parse(String version) {
    final parts = version.split('.');

    return List.generate(
      3,
      (index) => index < parts.length
          ? int.tryParse(parts[index].replaceAll(RegExp(r'[^0-9]'), '')) ?? 0
          : 0,
    );
  }

  static Future<bool> openStore(String url) async {
    if (url.isEmpty) return false;

    final uri = Uri.tryParse(url);
    if (uri == null) return false;

    return launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
  }
}
