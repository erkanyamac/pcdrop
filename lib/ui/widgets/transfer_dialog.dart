import 'package:flutter/material.dart';

import '../../models/transfer_session.dart';

class TransferDialog extends StatelessWidget {
  const TransferDialog({
    required this.session,
    required this.onApprove,
    required this.onReject,
    super.key,
  });

  final TransferSession session;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final totalBytes = session.files.fold<int>(
      0,
      (total, file) => total + file.size,
    );
    return AlertDialog(
      title: Text('${session.sender.alias} dosya göndermek istiyor'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${session.files.length} dosya • ${_formatBytes(totalBytes)}'),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: session.files.length,
                itemBuilder: (context, index) {
                  final file = session.files[index];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.insert_drive_file_outlined),
                    title: Text(file.fileName, overflow: TextOverflow.ellipsis),
                    subtitle: Text(_formatBytes(file.size)),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: onReject, child: const Text('Reddet')),
        FilledButton(onPressed: onApprove, child: const Text('Kabul Et')),
      ],
    );
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
