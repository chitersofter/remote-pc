import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class PcStatus {
  final String hostname;
  final int volume;
  final bool mute;
  final int brightness;
  final double cpu;
  final double ram;
  final bool aiReady;
  final String aiState;
  final String aiModel;

  const PcStatus({
    required this.hostname,
    required this.volume,
    required this.mute,
    required this.brightness,
    required this.cpu,
    required this.ram,
    required this.aiReady,
    required this.aiState,
    required this.aiModel,
  });

  factory PcStatus.fromJson(Map<String, dynamic> json) {
    final ai = (json['ai'] as Map<String, dynamic>?) ?? const {};
    return PcStatus(
      hostname: (json['hostname'] as String?) ?? 'Remote PC',
      volume: (json['volume'] as num?)?.toInt() ?? 50,
      mute: (json['mute'] as bool?) ?? false,
      brightness: (json['brightness'] as num?)?.toInt() ?? 50,
      cpu: (json['cpu'] as num?)?.toDouble() ?? 0.0,
      ram: (json['ram'] as num?)?.toDouble() ?? 0.0,
      aiReady: (ai['ready'] as bool?) ?? false,
      aiState: (ai['state'] as String?) ?? 'idle',
      aiModel: (ai['short_name'] as String?) ?? 'Qwen 1.5B',
    );
  }
}

class AiExecutionResult {
  final bool ok;
  final String command;
  final String stdout;
  final String stderr;
  final String feedback;
  final int latencyMs;

  const AiExecutionResult({
    required this.ok,
    required this.command,
    required this.stdout,
    required this.stderr,
    required this.feedback,
    required this.latencyMs,
  });

  factory AiExecutionResult.fromJson(Map<String, dynamic> json) {
    return AiExecutionResult(
      ok: json['status'] == 'ok' && (json['ok'] as bool? ?? true),
      command: (json['command'] as String?) ?? '',
      stdout: (json['stdout'] as String?) ?? '',
      stderr: (json['stderr'] as String?) ?? '',
      feedback: (json['feedback'] as String?) ??
          (json['message'] as String?) ??
          'Готово',
      latencyMs: (json['latency_ms'] as num?)?.toInt() ?? 0,
    );
  }
}

class HistoryItem {
  final String prompt;
  final String command;
  final String timestamp;
  final String feedback;

  const HistoryItem({
    required this.prompt,
    required this.command,
    required this.timestamp,
    required this.feedback,
  });

  factory HistoryItem.fromJson(Map<String, dynamic> json) {
    return HistoryItem(
      prompt: (json['prompt'] as String?) ?? '',
      command: (json['command'] as String?) ?? '',
      timestamp: (json['timestamp'] as String?) ?? '',
      feedback: (json['feedback'] as String?) ?? '',
    );
  }
}

class RemoteApiService {
  static const MethodChannel _nativeChannel =
      MethodChannel('com.remotepc.app/native');

  final http.Client _client;
  String host;
  int port;

  // Coalesced pointer deltas for zero-lag Wi-Fi cursor tracking
  double _pendingDx = 0;
  double _pendingDy = 0;
  bool _moveInFlight = false;

  RemoteApiService({
    http.Client? client,
    this.host = '192.168.0.103',
    this.port = 5000,
  }) : _client = client ?? http.Client();

  String get baseUrl => 'http://$host:$port';

  void setNativeSpeechCallbacks({
    required void Function() onReady,
    required void Function(String partial) onPartial,
    required void Function(String finalResult) onResult,
    required void Function(int errorCode) onError,
    required void Function() onEnd,
  }) {
    _nativeChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onSpeechReady':
          onReady();
          break;
        case 'onSpeechPartial':
          final text = (call.arguments as String?) ?? '';
          onPartial(text);
          break;
        case 'onSpeechResult':
          final text = (call.arguments as String?) ?? '';
          onResult(text);
          break;
        case 'onSpeechError':
          final err = (call.arguments as num?)?.toInt() ?? -1;
          onError(err);
          break;
        case 'onSpeechEnd':
          onEnd();
          break;
      }
    });
  }

  Future<void> startNativeListening({String lang = 'ru-RU'}) async {
    try {
      await _nativeChannel.invokeMethod('startListening', {'lang': lang});
    } catch (_) {}
  }

  Future<void> stopNativeListening() async {
    try {
      await _nativeChannel.invokeMethod('stopListening');
    } catch (_) {}
  }

  Future<void> vibrate([int ms = 10]) async {
    try {
      await _nativeChannel.invokeMethod('vibrate', {'ms': ms});
    } catch (_) {
      HapticFeedback.selectionClick();
    }
  }

  Future<String?> loadSavedHost() async {
    try {
      return await _nativeChannel
          .invokeMethod<String>('getPref', {'key': 'saved_host'});
    } catch (_) {
      return null;
    }
  }

  Future<void> saveHost(String newHost) async {
    try {
      await _nativeChannel
          .invokeMethod('savePref', {'key': 'saved_host', 'value': newHost});
    } catch (_) {}
  }

  Future<List<String>> _getLocalSubnets() async {
    try {
      final list =
          await _nativeChannel.invokeListMethod<String>('getLocalSubnets');
      return list ?? const [];
    } catch (_) {
      return const [];
    }
  }

  Future<PcStatus> fetchStatus({Duration timeout = const Duration(seconds: 2)}) async {
    final resp = await _client
        .get(Uri.parse('$baseUrl/status'))
        .timeout(timeout);
    if (resp.statusCode == 200) {
      final map = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      return PcStatus.fromJson(map);
    }
    throw Exception('HTTP ${resp.statusCode}');
  }

  Future<String?> autoDiscoverPc() async {
    // 1. Check current/saved host first
    if (await _probeIp(host)) {
      return host;
    }

    // 2. Check phone's active Wi-Fi subnets + common home subnets
    final subnets = <String>{
      ...(await _getLocalSubnets()),
      '192.168.0',
      '192.168.1',
      '192.168.31',
      '172.20.10',
    }.toList();

    for (final prefix in subnets) {
      // Sweep in batches of 32 concurrent lightweight probes
      for (int start = 1; start <= 254; start += 32) {
        final end = (start + 31 > 254) ? 254 : start + 31;
        final futures = <Future<String?>>[];
        for (int i = start; i <= end; i++) {
          final candidate = '$prefix.$i';
          futures.add(_probeIp(candidate).then((ok) => ok ? candidate : null));
        }
        final results = await Future.wait(futures);
        for (final match in results) {
          if (match != null) {
            host = match;
            await saveHost(match);
            return match;
          }
        }
      }
    }
    return null;
  }

  Future<bool> _probeIp(String ip) async {
    try {
      final r = await _client
          .get(Uri.parse('http://$ip:$port/status'))
          .timeout(const Duration(milliseconds: 420));
      if (r.statusCode == 200 && r.body.contains('"hostname"')) {
        return true;
      }
    } catch (_) {}
    return false;
  }

  Future<AiExecutionResult> sendVoiceOrAiCommand(
    String text, {
    required bool forceAi,
  }) async {
    final resp = await _client
        .post(
          Uri.parse('$baseUrl/voice'),
          headers: const {'Content-Type': 'application/json; charset=UTF-8'},
          body: jsonEncode({'text': text, 'force_ai': forceAi}),
        )
        .timeout(const Duration(seconds: 32));
    final map = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return AiExecutionResult.fromJson(map);
  }

  Future<AiExecutionResult> sendDirectPowerShell(String command) async {
    final resp = await _client
        .post(
          Uri.parse('$baseUrl/shell'),
          headers: const {'Content-Type': 'application/json; charset=UTF-8'},
          body: jsonEncode({'command': command}),
        )
        .timeout(const Duration(seconds: 16));
    final map = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return AiExecutionResult(
      ok: map['ok'] == true || map['status'] == 'ok',
      command: command,
      stdout: (map['stdout'] as String?) ?? '',
      stderr: (map['stderr'] as String?) ?? '',
      feedback: map['ok'] == true ? 'PowerShell выполнен' : 'Ошибка выполнения',
      latencyMs: 0,
    );
  }

  Future<String> searchAndPlayYoutube(String query) async {
    final resp = await _client
        .post(
          Uri.parse('$baseUrl/yt_search'),
          headers: const {'Content-Type': 'application/json; charset=UTF-8'},
          body: jsonEncode({'query': query}),
        )
        .timeout(const Duration(seconds: 12));
    final map = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
    return (map['feedback'] as String?) ?? 'Видео запущено';
  }

  Future<List<HistoryItem>> fetchHistory() async {
    try {
      final resp = await _client
          .get(Uri.parse('$baseUrl/ai/history'))
          .timeout(const Duration(seconds: 3));
      if (resp.statusCode == 200) {
        final map =
            jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
        final rawList = (map['history'] as List<dynamic>?) ?? const [];
        return rawList
            .whereType<Map<String, dynamic>>()
            .map(HistoryItem.fromJson)
            .toList();
      }
    } catch (_) {}
    return const [];
  }

  Future<void> clearHistory() async {
    try {
      await _client.post(Uri.parse('$baseUrl/ai/clear'));
    } catch (_) {}
  }

  Future<void> sendCmd(Map<String, dynamic> payload) async {
    try {
      await _client
          .post(
            Uri.parse('$baseUrl/cmd'),
            headers: const {'Content-Type': 'application/json; charset=UTF-8'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  void queuePointerMove(double dx, double dy, double sensitivity) {
    _pendingDx += dx;
    _pendingDy += dy;
    _flushPointerMove(sensitivity);
  }

  Future<void> _flushPointerMove(double sensitivity) async {
    if (_moveInFlight ||
        (_pendingDx.abs() < 0.25 && _pendingDy.abs() < 0.25)) {
      return;
    }
    _moveInFlight = true;
    final dx = _pendingDx;
    final dy = _pendingDy;
    _pendingDx = 0;
    _pendingDy = 0;
    try {
      await _client
          .post(
            Uri.parse('$baseUrl/cmd'),
            headers: const {'Content-Type': 'application/json; charset=UTF-8'},
            body: jsonEncode({
              'cmd': 'move',
              'dx': dx,
              'dy': dy,
              'sens': sensitivity,
            }),
          )
          .timeout(const Duration(milliseconds: 900));
    } catch (_) {
    } finally {
      _moveInFlight = false;
      if (_pendingDx.abs() >= 0.25 || _pendingDy.abs() >= 0.25) {
        unawaited(_flushPointerMove(sensitivity));
      }
    }
  }
}
