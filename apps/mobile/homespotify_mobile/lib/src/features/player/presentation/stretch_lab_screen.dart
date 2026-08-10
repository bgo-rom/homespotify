import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/logging/app_logger.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/widgets/clay_header.dart';
import '../../../core/widgets/soft_surface.dart';
import '../audio/audio_diagnostics.dart';
import '../audio/homespotify_audio_handler.dart';

/// Écran développeur discret : comparaison A/B des configurations du moteur
/// HomeSpotify Stretch sur la même piste, à la même position et au même
/// volume. Aucun lien depuis l'interface normale ; accès par appui long sur
/// le panneau « Mode audio » de la feuille de vitesse.
///
/// L'application d'une configuration force un seek sur place : c'est la seule
/// frontière PCM où une géométrie STFT différente peut être appliquée sans
/// corrompre le flux en cours.
class StretchLabScreen extends ConsumerStatefulWidget {
  const StretchLabScreen({super.key, this.channel});

  /// Canal injectable pour les tests.
  final MethodChannel? channel;

  @override
  ConsumerState<StretchLabScreen> createState() => _StretchLabScreenState();
}

class _LabOverride {
  const _LabOverride(this.value, this.label, this.description);

  final int value;
  final String label;
  final String description;
}

const _overrides = <_LabOverride>[
  _LabOverride(
    -1,
    'AUTO (production)',
    'MUSICAL 120 ms / 30 ms — presetDefault',
  ),
  _LabOverride(
    0,
    'TRANSPARENT',
    'presetCheaper 100 ms / 40 ms — ancienne config <±5 %',
  ),
  _LabOverride(1, 'MUSICAL', 'presetDefault 120 ms / 30 ms'),
  _LabOverride(
    2,
    'EXTREME_HQ',
    '120 ms / 20 ms — recouvrement 6x (candidat HQ)',
  ),
  _LabOverride(3, 'MEDIA3 (Sonic)', 'Fallback compatible, pour référence A/B'),
];

class _StretchLabScreenState extends ConsumerState<StretchLabScreen> {
  static const _defaultChannel = MethodChannel(
    'com.homespotify/stretch_engine',
  );

  Timer? _refreshTimer;
  Map<Object?, Object?>? _status;
  Map<String, Object?>? _nativeMetrics;
  int _selectedOverride = -1;
  bool _applying = false;
  String? _error;

  MethodChannel get _channel => widget.channel ?? _defaultChannel;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_refresh()),
    );
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final raw = await _channel.invokeMapMethod<Object?, Object?>('getStatus');
      if (!mounted || raw == null) return;
      Map<String, Object?>? native;
      final rawNative = raw['nativeMetrics'];
      if (rawNative is String && rawNative.isNotEmpty) {
        try {
          native = (jsonDecode(rawNative) as Map).cast<String, Object?>();
        } catch (_) {
          native = null;
        }
      }
      setState(() {
        _status = raw;
        _nativeMetrics = native;
        _error = null;
      });
    } on MissingPluginException {
      if (mounted) {
        setState(
          () => _error = 'Canal indisponible (plateforme non Android ?).',
        );
      }
    } on PlatformException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _apply() async {
    if (_applying) return;
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      final accepted = await _channel.invokeMethod<bool>(
        'setProfileOverride',
        <String, Object?>{'override': _selectedOverride},
      );
      if (accepted != true) {
        setState(
          () => _error =
              'Aucun lecteur actif : lancer une piste avec une vitesse ≠ 1.00x.',
        );
        return;
      }
      // Seek sur place : même piste, même position — seule frontière PCM où
      // la nouvelle géométrie peut s'appliquer proprement.
      final handler = ref.read(audioHandlerProvider);
      final position = handler.playbackState.value.position;
      await handler.seek(position);
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Configuration appliquée à la position courante.'),
          ),
        );
      }
    } catch (error, stackTrace) {
      logError(
        'application override stretch impossible',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) setState(() => _error = 'Application impossible.');
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final status = _status;
    final native = _nativeMetrics;
    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            ClayHeader(
              title: 'Stretch Lab',
              subtitle: 'Outil développeur — comparaison A/B du moteur audio',
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppLayout.gutter,
                  4,
                  AppLayout.gutter,
                  32,
                ),
                children: [
                  Text(
                    'Écran développeur. Comparer les configurations sur le '
                    'même passage : choisir, appliquer (seek sur place), '
                    'écouter, noter.',
                    style: TextStyle(color: colors.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  _section(colors, 'État du moteur', [
                    _row(colors, 'Mode', '${status?['engineMode'] ?? '—'}'),
                    _row(colors, 'Actif', '${status?['active'] ?? '—'}'),
                    _row(
                      colors,
                      'Ratio demandé / appliqué',
                      '${status?['requestedRatio'] ?? '—'} / '
                          '${status?['nativeAppliedRatio'] ?? '—'}',
                    ),
                    _row(colors, 'Profil (Java)', '${status?['profile'] ?? '—'}'),
                    _row(
                      colors,
                      'Profil natif actif',
                      '${native?['activeProfile'] ?? '—'}',
                    ),
                    _row(
                      colors,
                      'Changement de profil en attente',
                      '${native?['profileChangePending'] ?? '—'}',
                    ),
                    _row(
                      colors,
                      'Override',
                      _overrideLabel(status?['profileOverride']),
                    ),
                    _row(
                      colors,
                      'Latence',
                      '${(status?['latencyMs'] as num?)?.toStringAsFixed(0) ?? '—'} ms',
                    ),
                    _row(
                      colors,
                      'Frames PCM traitées',
                      '${status?['pcmFramesProcessed'] ?? '—'}',
                    ),
                    _row(
                      colors,
                      'DSP moyen / max',
                      '${(status?['averageDspMicros'] as num?)?.toStringAsFixed(0) ?? '—'} µs / '
                          '${status?['maxDspMicros'] ?? '—'} µs',
                    ),
                    _row(
                      colors,
                      'Underruns détectés',
                      '${status?['underrunCount'] ?? '—'}',
                    ),
                    _row(colors, 'Fallbacks', '${status?['fallbackCount'] ?? '—'}'),
                    _row(colors, 'Dernière erreur', '${status?['lastError'] ?? '—'}'),
                  ]),
                  const SizedBox(height: 16),
                  _section(colors, 'Configuration à comparer', [
                    RadioGroup<int>(
                      groupValue: _selectedOverride,
                      onChanged: (value) {
                        if (_applying || value == null) return;
                        setState(() => _selectedOverride = value);
                      },
                      child: Column(
                        children: [
                          for (final override in _overrides)
                            RadioListTile<int>(
                              key: ValueKey(
                                'stretch-lab-override-${override.value}',
                              ),
                              value: override.value,
                              activeColor: colors.accent,
                              title: Text(
                                override.label,
                                style: TextStyle(color: colors.textPrimary),
                              ),
                              subtitle: Text(
                                override.description,
                                style: TextStyle(
                                  color: colors.textSecondary,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      key: const ValueKey('stretch-lab-apply'),
                      onPressed: _applying ? null : _apply,
                      child: Text(
                        _applying
                            ? 'Application…'
                            : 'Appliquer à la position courante',
                      ),
                    ),
                  ]),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: colors.danger)),
                  ],
                  const SizedBox(height: 16),
                  _section(
                    colors,
                    'Fiche d\'écoute (comparer sur le même passage)',
                    [
                      _ChecklistItem('Naturel des voix (pas de timbre métallique)'),
                      _ChecklistItem(
                        'Netteté des consonnes (pas d\'attaques répétées)',
                      ),
                      _ChecklistItem('Batterie : kicks simples, cymbales nettes'),
                      _ChecklistItem('Basses stables (pas de tremolo)'),
                      _ChecklistItem('Image stéréo cohérente'),
                      _ChecklistItem('Artefacts : phasing, chorus, voix creuse'),
                      _ChecklistItem(
                        'Stabilité : coupures, clics, dérive de position',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Rappel : aucune métrique CPU ne remplace l\'écoute. '
                    'Comparer casque, haut-parleur et Bluetooth ; mêmes '
                    'passages vocaux à 0.80x, 1.20x et 1.30x.',
                    style: TextStyle(color: colors.textTertiary, fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  _section(colors, 'Journal audio (sessions longues)', [
                    Text(
                      AudioDiagnostics.enabled
                          ? 'Événements du lecteur (file, index, erreurs, '
                                'refresh). Aucun secret journalisé.'
                          : 'Journal inactif : build sans '
                                'HOMESPOTIFY_AUDIO_DIAGNOSTICS=true.',
                      style: TextStyle(color: colors.textSecondary, fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      constraints: const BoxConstraints(maxHeight: 240),
                      decoration: BoxDecoration(
                        color: colors.surfaceSunken,
                        borderRadius: AppRadius.cardRadius,
                      ),
                      padding: const EdgeInsets.all(8),
                      child: SingleChildScrollView(
                        reverse: true,
                        child: Text(
                          AudioDiagnostics.instance.snapshot().isEmpty
                              ? '(vide)'
                              : AudioDiagnostics.instance
                                    .snapshot()
                                    .reversed
                                    .take(60)
                                    .toList()
                                    .reversed
                                    .join('\n'),
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10,
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      key: const ValueKey('stretch-lab-copy-audio-journal'),
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: AudioDiagnostics.instance.export()),
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Journal audio copié (presse-papiers).',
                              ),
                            ),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy_all_rounded, size: 18),
                      label: const Text('Copier le journal complet'),
                    ),
                  ]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _overrideLabel(Object? value) {
    final ordinal = value is num ? value.toInt() : -1;
    return _overrides
        .firstWhere(
          (override) => override.value == ordinal,
          orElse: () => _overrides.first,
        )
        .label;
  }

  Widget _section(AppColors colors, String title, List<Widget> children) =>
      SoftCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: TextStyle(
                color: colors.accent,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      );

  Widget _row(AppColors colors, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(label, style: TextStyle(color: colors.textSecondary)),
        ),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: TextStyle(
              color: colors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}

class _ChecklistItem extends StatelessWidget {
  const _ChecklistItem(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(
            Icons.check_box_outline_blank,
            size: 16,
            color: colors.textTertiary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label, style: TextStyle(color: colors.textPrimary)),
          ),
        ],
      ),
    );
  }
}
