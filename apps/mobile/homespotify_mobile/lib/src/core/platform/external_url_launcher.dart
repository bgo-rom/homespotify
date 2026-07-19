import 'package:flutter/services.dart';

class ExternalUrlLauncher {
  const ExternalUrlLauncher();

  static const MethodChannel _channel = MethodChannel(
    'com.homespotify/external_url',
  );

  Future<bool> open(String value) async {
    final uri = Uri.tryParse(value);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return false;
    }
    return await _channel.invokeMethod<bool>('open', {'url': uri.toString()}) ??
        false;
  }
}
