import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/soft_surface.dart';

/// Groupe sculpté Direction 33 des écrans Administration : libellé en accent,
/// carte unique. Remplace la carte Material contourée d'origine (fond uni +
/// bordure `Colors.white10`), commune aux 4 écrans OWNER.
class AdminSection extends StatelessWidget {
  const AdminSection({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                color: colors.accent,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),
          SoftCard(
            padding: const EdgeInsets.all(16),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}

/// Ligne libellé/valeur d'une [AdminSection] — infos techniques scannables.
class AdminInfoRow extends StatelessWidget {
  const AdminInfoRow({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
  });

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 5,
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: valueColor ?? colors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
