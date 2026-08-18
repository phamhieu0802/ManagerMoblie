import 'package:flutter/material.dart';
import '../core/theme/app_theme.dart';

class StatusChip extends StatelessWidget {
  final String status;
  final bool dense;
  const StatusChip({super.key, required this.status, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final color = StatusColors.map[status] ?? Colors.grey;
    final label = StatusColors.label[status] ?? status;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 12, vertical: dense ? 3 : 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: dense ? 11 : 13),
      ),
    );
  }
}
