import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../../../../core/logging/app_logger.dart';

const Color _sheetBackground = Color(0xFF18181F);
const Color _accent = Color(0xFF1DB954);
const String _unknown = 'Inconnu';

Future<void> showFileDetailsSheet(
  BuildContext context, {
  required MediaItem mediaItem,
}) async {
  final details = _FileDetails.fromMediaItem(mediaItem);
  final missing = details.missingLabels;
  logUi(
    'ouverture détails fichier track=${mediaItem.id} '
    'format=${details.format} métadonnées_absentes='
    '${missing.isEmpty ? 'aucune' : missing.join(',')}',
  );

  try {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: _sheetBackground,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _FileDetailsSheet(details: details),
    );
  } catch (error, stackTrace) {
    logError(
      'erreur détails fichier track=${mediaItem.id}',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

class _FileDetailsSheet extends StatelessWidget {
  const _FileDetailsSheet({required this.details});

  final _FileDetails details;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: 0.78,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 18),
            const Row(
              children: [
                Icon(Icons.info_outline_rounded, color: _accent),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Détails du fichier',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView.separated(
                itemCount: details.rows.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, color: Colors.white10),
                itemBuilder: (context, index) {
                  final row = details.rows[index];
                  return _DetailRow(
                    key: ValueKey<String>('file-detail-${row.$1}'),
                    label: row.$1,
                    value: row.$2,
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.black,
                ),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Fermer'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 5,
            child: Text(
              value,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class _FileDetails {
  const _FileDetails({required this.rows, required this.missingLabels});

  final List<(String, String)> rows;
  final List<String> missingLabels;

  String get format => rows[3].$2;

  factory _FileDetails.fromMediaItem(MediaItem item) {
    final extras = item.extras ?? const <String, dynamic>{};
    final rows = <(String, String)>[
      ('Titre', _text(item.title)),
      ('Artiste', _text(item.artist)),
      ('Album', _text(item.album)),
      ('Format', _format(extras)),
      ('Durée', _duration(item.duration)),
      ('Fréquence d’échantillonnage', _sampleRate(extras['sampleRate'])),
      ('Profondeur en bits', _number(extras['bitDepth'], suffix: ' bits')),
      ('Nombre de canaux', _number(extras['channels'])),
      ('Débit audio', _bitrate(extras['bitrate'])),
      ('Taille du fichier', _fileSize(extras['fileSize'])),
      ('ID de la piste', _text(item.id)),
    ];
    return _FileDetails(
      rows: rows,
      missingLabels: [
        for (final row in rows)
          if (row.$2 == _unknown) row.$1,
      ],
    );
  }

  static String _text(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? _unknown : normalized;
  }

  static int? _positiveInt(Object? value) {
    if (value == null) return null;
    final number = value is num ? value.toInt() : int.tryParse('$value');
    return number != null && number > 0 ? number : null;
  }

  static String _number(Object? value, {String suffix = ''}) {
    final number = _positiveInt(value);
    return number == null ? _unknown : '$number$suffix';
  }

  static String _format(Map<String, dynamic> extras) {
    final explicit = extras['format'];
    if (explicit is String && explicit.trim().isNotEmpty) {
      return explicit.trim().toUpperCase();
    }
    final extension = (extras['extension'] as String?)?.toLowerCase();
    final mimeType = (extras['mimeType'] as String?)?.toLowerCase();
    if (extension == '.wav' || mimeType == 'audio/wav') return 'WAV';
    if (extension == '.flac' || mimeType == 'audio/flac') return 'FLAC';
    return _unknown;
  }

  static String _duration(Duration? value) {
    if (value == null || value < Duration.zero) return _unknown;
    final hours = value.inHours;
    final minutes = (value.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (value.inSeconds % 60).toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:$minutes:$seconds'
        : '${value.inMinutes}:$seconds';
  }

  static String _sampleRate(Object? value) {
    final hertz = _positiveInt(value);
    if (hertz == null) return _unknown;
    final khz = hertz / 1000;
    final decimals = hertz % 1000 == 0 ? 0 : 1;
    return '${khz.toStringAsFixed(decimals)} kHz';
  }

  static String _bitrate(Object? value) {
    final bitsPerSecond = _positiveInt(value);
    return bitsPerSecond == null
        ? _unknown
        : '${(bitsPerSecond / 1000).round()} kb/s';
  }

  static String _fileSize(Object? value) {
    final bytes = _positiveInt(value);
    if (bytes == null) return _unknown;
    const units = ['o', 'Ko', 'Mo', 'Go'];
    var size = bytes.toDouble();
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    final decimals = unit == 0 || size >= 100 ? 0 : 1;
    return '${size.toStringAsFixed(decimals)} ${units[unit]}';
  }
}
