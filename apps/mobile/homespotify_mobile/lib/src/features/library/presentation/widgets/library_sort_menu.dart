import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../library_filters.dart';

/// Menu de tri de la bibliothèque (AppBar). Le choix vit dans
/// [librarySortProvider] et reste actif toute la session.
class LibrarySortMenu extends ConsumerWidget {
  const LibrarySortMenu({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(librarySortProvider);

    return PopupMenuButton<LibrarySort>(
      tooltip: 'Trier',
      icon: const Icon(Icons.sort_rounded),
      color: const Color(0xFF23232B),
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
                  color: sort == current
                      ? const Color(0xFF1DB954)
                      : Colors.transparent,
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    sort.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: sort == current ? Colors.white : Colors.white70,
                      fontSize: 14,
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
