import 'dart:async';
import 'package:flutter/foundation.dart';
import '../data/remote_api_service.dart';

class RemoteViewModel extends ChangeNotifier {
  final RemoteApiService api;

  bool connected = false;
  bool discovering = false;
  String hostname = 'Remote PC';
  int volume = 70;
  bool muted = false;
  int brightness = 80;
  double cpu = 0;
  double ram = 0;
  bool aiReady = false;
  String aiState = 'idle';
  String aiModel = 'Qwen 1.5B';

  // Voice & Qwen Computer Use state
  bool isListening = false;
  bool isBusyAi = false;
  bool handsFree = false;
  bool forceAiMode = false;
  String statusHint = 'Нажмите и скажите задачу для ПК';
  String transcript = 'Готов к выполнению голосовых и терминальных команд';
  String lastCommand = '';
  String lastOutput = '';
  String lastFeedback = '';
  int? lastLatencyMs;
  List<HistoryItem> history = const [];

  // Trackpad state
  double sensitivity = 1.35;
  bool scrollInverted = false;
  bool dragLocked = false;

  // Transient Dynamic Island toast
  String? toastMessage;

  Timer? _statusTimer;
  Timer? _volDebounce;
  Timer? _brightDebounce;
  Timer? _handsFreeTimer;
  Timer? _toastTimer;
  String _partialSpeech = '';
  bool _disposed = false;

  RemoteViewModel({required this.api});

  void showToast(String message) {
    final clean = message.trim();
    if (clean.isEmpty || _disposed) return;
    toastMessage = clean;
    notifyListeners();
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(milliseconds: 2200), () {
      if (_disposed) return;
      toastMessage = null;
      notifyListeners();
    });
  }

  Future<void> initialize({bool enablePolling = true}) async {
    api.setNativeSpeechCallbacks(
      onReady: () {
        if (_disposed) return;
        isListening = true;
        _partialSpeech = '';
        statusHint = 'Слушаю команду...';
        notifyListeners();
      },
      onPartial: (partial) {
        if (_disposed) return;
        _partialSpeech = partial;
        transcript = '«$partial»';
        notifyListeners();
      },
      onResult: (finalText) {
        if (_disposed) return;
        isListening = false;
        _partialSpeech = '';
        final clean = finalText.trim();
        if (clean.isNotEmpty) {
          transcript = '«$clean»';
          unawaited(executeVoiceOrAi(clean));
        }
        _scheduleHandsFreeRestartIfNeeded();
        notifyListeners();
      },
      onError: (code) {
        if (_disposed) return;
        isListening = false;
        if (_partialSpeech.trim().isNotEmpty) {
          final fallback = _partialSpeech.trim();
          _partialSpeech = '';
          unawaited(executeVoiceOrAi(fallback));
          _scheduleHandsFreeRestartIfNeeded();
          notifyListeners();
          return;
        }

        // Transient silence/no-match/busy codes may continue in Hands-Free mode
        if (code == 6 || code == 7) {
          if (handsFree) {
            _scheduleHandsFreeRestartIfNeeded(delayMs: 500);
          } else {
            statusHint = 'Речь не распознана — нажмите и повторите';
          }
          notifyListeners();
          return;
        }
        if (code == 8) {
          if (handsFree) {
            _scheduleHandsFreeRestartIfNeeded(delayMs: 1200);
          } else {
            statusHint = 'Нажмите и скажите задачу для ПК';
          }
          notifyListeners();
          return;
        }

        // Fatal / permission / canceled / network / missing-engine errors:
        // disable Hands-Free and preserve the error hint without looping!
        handsFree = false;
        _handsFreeTimer?.cancel();
        if (code == 9) {
          statusHint = 'Разрешите доступ к микрофону';
        } else if (code == -1) {
          statusHint = 'Движок речи не найден — введите задачу текстом';
        } else if (code == -2) {
          statusHint = 'Нажмите и скажите задачу для ПК';
        } else if (code == 1 || code == 2) {
          statusHint = 'Нет сети для распознавания речи';
        } else if (code == 3) {
          statusHint = 'Ошибка микрофона устройства';
        } else {
          statusHint = 'Микрофон недоступен — введите задачу текстом';
        }
        notifyListeners();
      },
      onEnd: () {
        if (_disposed) return;
        if (isListening) {
          isListening = false;
          statusHint = 'Распознаю речь...';
          notifyListeners();
        }
      },
    );

    final saved = await api.loadSavedHost();
    if (saved != null && saved.trim().isNotEmpty) {
      _applyHostPortString(saved.trim());
    }

    if (enablePolling) {
      await refreshStatusOrDiscover();
      unawaited(refreshHistory());
      _statusTimer = Timer.periodic(
        const Duration(seconds: 4),
        (_) => refreshStatus(),
      );
    }
  }

  void _applyHostPortString(String input) {
    var clean = input.trim();
    clean = clean.replaceAll('http://', '').replaceAll('https://', '');
    if (clean.contains('/')) {
      clean = clean.split('/').first;
    }
    if (clean.contains(':')) {
      final parts = clean.split(':');
      final h = parts[0].trim();
      if (h.isNotEmpty) {
        api.host = h;
      }
      final p = int.tryParse(parts[1].trim());
      if (p != null && p > 0 && p <= 65535) {
        api.port = p;
      }
    } else if (clean.isNotEmpty) {
      api.host = clean;
    }
  }

  void _scheduleHandsFreeRestartIfNeeded({int delayMs = 500}) {
    _handsFreeTimer?.cancel();
    if (!handsFree) {
      statusHint = 'Нажмите и скажите задачу для ПК';
      return;
    }
    statusHint = 'Hands-Free активен...';
    _handsFreeTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!_disposed && handsFree && !isListening && !isBusyAi) {
        api.startNativeListening();
      }
    });
  }

  Future<void> refreshStatusOrDiscover() async {
    try {
      final st = await api.fetchStatus(timeout: const Duration(milliseconds: 900));
      _applyStatus(st);
    } catch (_) {
      connected = false;
      if (!_disposed) notifyListeners();
      await scanNetworkForPc();
    }
  }

  Future<void> refreshStatus() async {
    try {
      final st = await api.fetchStatus();
      _applyStatus(st);
    } catch (_) {
      if (connected) {
        connected = false;
        if (!_disposed) notifyListeners();
      }
    }
  }

  void _applyStatus(PcStatus st) {
    if (_disposed) return;
    connected = true;
    hostname = st.hostname;
    volume = st.volume;
    muted = st.mute;
    brightness = st.brightness;
    cpu = st.cpu;
    ram = st.ram;
    aiReady = st.aiReady;
    aiState = st.aiState;
    aiModel = st.aiModel;
    notifyListeners();
  }

  Future<bool> scanNetworkForPc() async {
    if (discovering) return false;
    discovering = true;
    if (!_disposed) notifyListeners();
    try {
      final found = await api.autoDiscoverPc();
      if (found != null) {
        await refreshStatus();
        await refreshHistory();
        return true;
      }
      return false;
    } finally {
      discovering = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<bool> updateHostManual(String rawInput) async {
    _applyHostPortString(rawInput);
    await api.saveHost('${api.host}:${api.port}');
    await refreshStatus();
    if (connected) {
      await refreshHistory();
    }
    showToast(
      connected
          ? 'Подключено к $hostname'
          : 'ПК не отвечает (${api.host}:${api.port})',
    );
    return connected;
  }

  Future<void> toggleMic() async {
    await api.vibrate(14);
    if (isListening) {
      handsFree = false;
      _handsFreeTimer?.cancel();
      isListening = false;
      statusHint = 'Нажмите и скажите задачу для ПК';
      notifyListeners();
      await api.stopNativeListening();
    } else {
      await api.startNativeListening();
    }
  }

  Future<void> toggleHandsFree() async {
    await api.vibrate(10);
    handsFree = !handsFree;
    if (!handsFree) {
      _handsFreeTimer?.cancel();
      statusHint = 'Нажмите и скажите задачу для ПК';
    } else {
      statusHint = 'Hands-Free активен...';
    }
    notifyListeners();
    if (handsFree && !isListening) {
      await api.startNativeListening();
    } else if (!handsFree && isListening) {
      await api.stopNativeListening();
    }
  }

  Future<void> toggleForceAiMode() async {
    await api.vibrate(10);
    forceAiMode = !forceAiMode;
    showToast(
      forceAiMode
          ? 'Все команды идут через Qwen PowerShell'
          : 'Умный режим: быстрые действия + Qwen AI',
    );
    notifyListeners();
  }

  Future<void> executeVoiceOrAi(String text) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    await api.vibrate(14);
    transcript = '«$clean»';
    isBusyAi = true;
    lastFeedback = 'Qwen AI анализирует и выполняет...';
    notifyListeners();

    try {
      final res = await api.sendVoiceOrAiCommand(clean, forceAi: forceAiMode);
      lastCommand = res.command;
      lastOutput = [res.stdout, res.stderr]
          .where((s) => s.trim().isNotEmpty)
          .join('\n')
          .trim();
      lastFeedback = res.feedback;
      lastLatencyMs = res.latencyMs;
      showToast(res.feedback);
      await api.vibrate(res.ok ? 20 : 35);
      await refreshHistory();
    } catch (_) {
      lastFeedback = 'Нет связи с ПК (${api.host}:${api.port})';
      showToast('Нет связи с ПК');
    } finally {
      isBusyAi = false;
      if (handsFree && !isListening) {
        _scheduleHandsFreeRestartIfNeeded(delayMs: 350);
      }
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> playYoutube(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) return;
    await api.vibrate(12);
    showToast('Ищу на YouTube: $clean');
    try {
      final fb = await api.searchAndPlayYoutube(clean);
      showToast(fb);
    } catch (_) {
      showToast('Нет связи с ПК (${api.host}:${api.port})');
    }
  }

  Future<String> runDirectPowerShell(String command) async {
    await api.vibrate(12);
    try {
      final res = await api.sendDirectPowerShell(command);
      await refreshHistory();
      showToast(res.ok ? 'PowerShell выполнен' : 'Ошибка команды');
      final out = [res.stdout, res.stderr]
          .where((s) => s.trim().isNotEmpty)
          .join('\n')
          .trim();
      return out.isNotEmpty ? out : res.feedback;
    } catch (_) {
      showToast('Ошибка соединения с ПК');
      return 'Ошибка соединения с ПК';
    }
  }

  Future<void> refreshHistory() async {
    history = await api.fetchHistory();
    if (!_disposed) notifyListeners();
  }

  Future<void> clearHistory() async {
    await api.clearHistory();
    history = const [];
    if (!_disposed) notifyListeners();
  }

  Future<void> sendQuickCmd(Map<String, dynamic> payload) async {
    await api.vibrate(8);
    await api.sendCmd(payload);
  }

  void setVolumeSlider(double val) {
    volume = val.round();
    notifyListeners();
    _volDebounce?.cancel();
    _volDebounce = Timer(const Duration(milliseconds: 40), () {
      api.sendCmd({'cmd': 'volume_set', 'val': volume});
    });
  }

  void setBrightnessSlider(double val) {
    brightness = val.round();
    notifyListeners();
    _brightDebounce?.cancel();
    _brightDebounce = Timer(const Duration(milliseconds: 65), () {
      api.sendCmd({'cmd': 'sys', 'act': 'bright', 'val': brightness});
    });
  }

  Future<void> toggleDragLock() async {
    await api.vibrate(14);
    dragLocked = !dragLocked;
    notifyListeners();
    await api.sendCmd({
      'cmd': dragLocked ? 'mouse_down' : 'mouse_up',
      'btn': 'left',
    });
  }

  void setSensitivity(double val) {
    api.vibrate(8);
    sensitivity = val;
    notifyListeners();
  }

  void toggleScrollInverted() {
    api.vibrate(8);
    scrollInverted = !scrollInverted;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _statusTimer?.cancel();
    _volDebounce?.cancel();
    _brightDebounce?.cancel();
    _handsFreeTimer?.cancel();
    _toastTimer?.cancel();
    super.dispose();
  }
}
