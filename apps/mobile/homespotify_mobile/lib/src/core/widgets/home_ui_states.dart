import 'package:flutter/material.dart';

import '../theme/home_design.dart';

class HomeEmptyState extends StatelessWidget {
  const HomeEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(HomeDesign.space32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 58, color: Colors.white24),
              const SizedBox(height: HomeDesign.space16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: HomeDesign.space8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: HomeDesign.space20),
                FilledButton.icon(
                  onPressed: onAction,
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(actionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class HomeErrorState extends StatelessWidget {
  const HomeErrorState({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return HomeEmptyState(
      icon: Icons.cloud_off_rounded,
      title: 'Impossible de charger la bibliothèque',
      message: message,
      actionLabel: 'Réessayer',
      onAction: onRetry,
    );
  }
}

/// Skeleton statique et peu coûteux : aucun ticker permanent.
class HomeLoadingSkeleton extends StatelessWidget {
  const HomeLoadingSkeleton({super.key, this.rows = 6});

  final int rows;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      key: const ValueKey('home-loading-skeleton'),
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: rows,
      itemBuilder: (context, index) => const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: _SkeletonRow(),
      ),
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: HomeDesign.surfaceRaised,
            borderRadius: BorderRadius.circular(HomeDesign.radiusSmall),
          ),
        ),
        const SizedBox(width: HomeDesign.space12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 13,
                width: 190,
                decoration: BoxDecoration(
                  color: HomeDesign.surfaceRaised,
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              const SizedBox(height: HomeDesign.space8),
              Container(
                height: 11,
                width: 130,
                decoration: BoxDecoration(
                  color: HomeDesign.surface,
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
