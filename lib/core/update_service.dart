import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';
import 'version.dart';

/// Thông tin bản cập nhật mới nhất từ GitHub Releases.
class AppUpdate {
  final String version;
  final String downloadUrl;
  final String changelog;

  const AppUpdate({
    required this.version,
    required this.downloadUrl,
    required this.changelog,
  });
}

/// Service kiểm tra + tải + cài đặt bản cập nhật từ GitHub Releases.
class UpdateService {
  static const _githubOwner = 'phamhieu0802';
  static const _githubRepo = 'ManagerMoblie';

  /// Check GitHub Releases bản mới nhất.
  /// Trả về `null` nếu không có bản mới hơn hoặc lỗi.
  static Future<AppUpdate?> checkForUpdate() async {
    try {
      final url = Uri.parse(
        'https://api.github.com/repos/$_githubOwner/$_githubRepo/releases/latest',
      );
      final resp = await http.get(url).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;

      final json = jsonDecode(resp.body) as Map<String, dynamic>?;
      if (json == null) return null;

      final tagName = (json['tag_name'] ?? '').toString().trim();
      if (tagName.isEmpty) return null;

      // Tag format: "v2.2.0" hoặc "2.2.0"
      final latestVersion = tagName.replaceFirst(RegExp(r'^v'), '');
      if (compareVersions(latestVersion, currentAppVersion) <= 0) return null;

      // Tìm asset .exe trong release
      final assets = json['assets'] as List<dynamic>? ?? [];
      String? exeUrl;
      for (final asset in assets) {
        final name = (asset['name'] ?? '').toString();
        if (name.toLowerCase().endsWith('.exe')) {
          exeUrl = asset['browser_download_url'] as String?;
          break;
        }
      }
      if (exeUrl == null || exeUrl.isEmpty) return null;

      final changelog = (json['body'] ?? '').toString();

      return AppUpdate(
        version: latestVersion,
        downloadUrl: exeUrl,
        changelog: changelog,
      );
    } catch (e) {
      AppLogger.instance.warning('Update check lỗi', category: 'update', data: {'error': '$e'});
      return null;
    }
  }

  /// Download file từ [url] về temp folder.
  /// Trả về File đã download, hoặc null nếu lỗi.
  /// [onProgress] callback(progress 0.0 - 1.0).
  static Future<File?> downloadUpdate(
    String url, {
    void Function(double progress)? onProgress,
  }) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      final resp = await client.send(request).timeout(const Duration(minutes: 5));
      if (resp.statusCode != 200) return null;

      final contentLength = resp.contentLength ?? 0;
      final tempDir = await getTemporaryDirectory();
      final fileName = url.split('/').last;
      final file = File('${tempDir.path}/$fileName');

      final sink = file.openWrite();
      var received = 0;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (contentLength > 0) {
          onProgress?.call(received / contentLength);
        }
      }
      await sink.flush();
      await sink.close();

      if (received <= 0) return null;
      return file;
    } catch (e) {
      AppLogger.instance.warning('Download update lỗi', category: 'update', data: {'error': '$e'});
      return null;
    } finally {
      client.close();
    }
  }

  /// Chạy installer silent và thoát app.
  /// Inno Setup hỗ trợ `/SILENT` và `/NORESTART`.
  static Future<void> installAndRestart(String installerPath) async {
    try {
      await Process.start(installerPath, [
        '/SILENT',
        '/NORESTART',
        '/SUPPRESSMSGBOXES',
      ]);
      await Future.delayed(const Duration(seconds: 1));
      exit(0);
    } catch (e) {
      AppLogger.instance.error('Cài update lỗi', category: 'update', error: e);
    }
  }
}
