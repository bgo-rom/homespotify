import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_shapes.dart';
import '../library_filters.dart';

/// Menu de tri de la bibliothèque (AppBar). Le choix vit dans
/// [librarySortProvider] et reste actif toute la session.
class LibrarySortMenu extends ConsumerWidget {
  const LibrarySortMenu({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final current = ref.watch(librarySortProvider);

    return PopupMenuButton<LibrarySort>(
      tooltip: 'Trier',
      icon: Icon(Icons.sort_rounded, color: colors.textPrimary),
      color: colors.surfaceRaised,
      shape: RoundedRectangleBorder(borderRadius: AppRadius.cardRadius),
      onSelected: (value) => ref.read(librarySortProvider.notifier).set(value),
      itemBuilder: (context) => [
        for (final sort in LibrarySort.values)
          PopupMenuItem<LibrarySort>(
            value: sort,
            child: Row(
              children: [
                Icon(
                  Icons.check_rounded,
                  size: 18,
                  color: sort == current ? colors.accent : Colors.transparent,
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    sort.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: sort == current
                          ? colors.textPrimary
                          : colors.textSecondary,
                      fontWeight: sort == current
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
