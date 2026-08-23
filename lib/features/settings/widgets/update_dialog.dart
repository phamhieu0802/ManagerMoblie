import 'package:flutter/material.dart';

import '../../../core/update_service.dart';
import '../../../core/version.dart';
import '../../../core/app_toast.dart';

/// Hiển thị dialog có bản cập nhật mới và cho phép tải + cài đặt.
void showUpdateDialog(BuildContext context, AppUpdate update) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _UpdateDialogContent(update: update),
  );
}

class _UpdateDialogContent extends StatefulWidget {
  final AppUpdate update;
  const _UpdateDialogContent({required this.update});

  @override
  State<_UpdateDialogContent> createState() => _UpdateDialogContentState();
}

class _UpdateDialogContentState extends State<_UpdateDialogContent> {
  double _progress = 0;
  bool _downloading = false;
  bool _downloaded = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(children: [
        const Icon(Icons.system_update, color: Colors.blue, size: 24),
        const SizedBox(width: 8),
        Expanded(child: Text('Cập nhật v${widget.update.version}',
            style: const TextStyle(fontSize: 16))),
      ]),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Phiên bản hiện tại: v$currentAppVersion'),
            const SizedBox(height: 4),
            Text('Phiên bản mới: v${widget.update.version}',
                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
            if (widget.update.changelog.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Nội dung cập nhật:',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(widget.update.changelog,
                    style: const TextStyle(fontSize: 12), maxLines: 8,
                    overflow: TextOverflow.ellipsis),
              ),
            ],
            if (_downloading) ...[
              const SizedBox(height: 16),
              LinearProgressIndicator(value: _progress > 0 ? _progress : null),
              const SizedBox(height: 4),
              Text(_progress > 0
                  ? 'Đang tải... ${(_progress * 100).toInt()}%'
                  : 'Đang tải...',
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ],
            if (_downloaded) ...[
              const SizedBox(height: 12),
              const Row(children: [
                Icon(Icons.check_circle, color: Colors.green, size: 16),
                SizedBox(width: 4),
                Text('Đã tải xong. Sẵn sàng cài đặt.', style: TextStyle(fontSize: 12, color: Colors.green)),
              ]),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        if (!_downloading && !_downloaded)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Bỏ qua'),
          ),
        if (!_downloading && !_downloaded)
          TextButton(
            onPressed: () {
              // Đóng dialog, lần sau mở app sẽ check lại
              Navigator.pop(context);
            },
            child: const Text('Nhắc sau'),
          ),
        if (!_downloading && !_downloaded)
          FilledButton.icon(
            onPressed: _download,
            icon: const Icon(Icons.download, size: 16),
            label: const Text('Cập nhật ngay'),
          ),
        if (_downloaded)
          FilledButton.icon(
            onPressed: _install,
            icon: const Icon(Icons.install_desktop, size: 16),
            label: const Text('Cài đặt & khởi động lại'),
          ),
      ],
    );
  }

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _progress = 0;
      _error = null;
    });

    final file = await UpdateService.downloadUpdate(
      widget.update.downloadUrl,
      onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      },
    );

    if (!mounted) return;

    if (file != null && await file.exists()) {
      setState(() {
        _downloading = false;
        _downloaded = true;
        _progress = 1;
      });
      _installerPath = file.path;
    } else {
      setState(() {
        _downloading = false;
        _error = 'Tải file thất bại. Kiểm tra kết nối mạng và thử lại.';
      });
    }
  }

  String? _installerPath;

  void _install() {
    if (_installerPath == null) return;
    UpdateService.installAndRestart(_installerPath!);
  }
}
