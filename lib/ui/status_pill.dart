import 'package:flutter/material.dart';

import 'design_tokens.dart';
import 'typography.dart';

/// A status indicator that pairs colour with an icon AND a text label, so no
/// state is ever conveyed by colour alone (accessibility requirement 4).
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.kind, this.label});

  final AppStatusKind kind;

  /// Optional override for the displayed text (defaults to the kind's label).
  final String? label;

  @override
  Widget build(BuildContext context) {
    final style = AppStatusStyle.of(kind);
    final text = label ?? style.label;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.spaceSm,
        vertical: AppTokens.spaceXxs,
      ),
      decoration: BoxDecoration(
        color: style.color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppTokens.radiusSm),
        border: Border.all(color: style.color.withValues(alpha: 0.55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(style.icon, size: 14, color: style.color),
          const SizedBox(width: AppTokens.spaceXs),
          Text(
            text,
            style: TextStyle(
              fontFamily: 'D2Coding',
              fontSize: AppTypography.sizeBody,
              color: style.color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
