import 'dart:math' as math;
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data/remote_api_service.dart';
import 'ui/glass_widgets.dart';
import 'view_models/remote_view_model.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  final vm = RemoteViewModel(api: RemoteApiService());
  vm.initialize();
  runApp(RemotePcApp(viewModel: vm));
}

class RemotePcApp extends StatelessWidget {
  final RemoteViewModel viewModel;

  const RemotePcApp({super.key, required this.viewModel});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remote PC',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.bg,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.crimson,
          secondary: AppColors.crimson,
          surface: Color(0xFF121218),
        ),
        sliderTheme: SliderThemeData(
          activeTrackColor: AppColors.crimson,
          inactiveTrackColor: Colors.white.withOpacity(0.10),
          thumbColor: Colors.white,
          overlayColor: AppColors.crimson.withOpacity(0.18),
          trackHeight: 6,
        ),
      ),
      home: RemoteShellScreen(viewModel: viewModel),
    );
  }
}

class RemoteShellScreen extends StatefulWidget {
  final RemoteViewModel viewModel;

  const RemoteShellScreen({super.key, required this.viewModel});

  @override
  State<RemoteShellScreen> createState() => _RemoteShellScreenState();
}

class _RemoteShellScreenState extends State<RemoteShellScreen> {
  int _tabIndex = 0;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.viewModel,
      builder: (context, _) {
        final vm = widget.viewModel;
        final kbInset = MediaQuery.viewInsetsOf(context).bottom;
        final dockHidden = kbInset > 80;
        return Scaffold(
          resizeToAvoidBottomInset: false,
          body: AmbientCrimsonBackground(
            child: SafeArea(
              bottom: false,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 620),
                      child: Stack(
                        children: [
                          Column(
                            children: [
                              _TopStatusHeader(
                                vm: vm,
                                onTapConnect: () =>
                                    _openConnectionSheet(context, vm),
                              ),
                              Expanded(
                                child: IndexedStack(
                                  index: _tabIndex,
                                  children: [
                                    _VoiceAiTab(vm: vm),
                                    _TrackpadTab(vm: vm),
                                    _MediaTab(vm: vm),
                                    _SystemPcTab(
                                      vm: vm,
                                      onConfirmShutdown: () =>
                                          _openShutdownSheet(context, vm),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          Positioned(
                            left: 14,
                            right: 14,
                            bottom: math.max(
                              12,
                              MediaQuery.paddingOf(context).bottom + 8,
                            ),
                            child: IgnorePointer(
                              ignoring: dockHidden,
                              child: AnimatedOpacity(
                                duration: const Duration(milliseconds: 180),
                                opacity: dockHidden ? 0.0 : 1.0,
                                child: IosLiquidGlassDock(
                                  currentIndex: _tabIndex,
                                  onChanged: (idx) {
                                    vm.api.vibrate(8);
                                    FocusScope.of(context).unfocus();
                                    setState(() => _tabIndex = idx);
                                  },
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            top: 8,
                            left: 18,
                            right: 18,
                            child: Center(
                              child: DynamicIslandToast(
                                message: vm.toastMessage,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  void _openConnectionSheet(BuildContext context, RemoteViewModel vm) {
    final ctrl = TextEditingController(text: '${vm.api.host}:${vm.api.port}');
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 14,
            right: 14,
            bottom: MediaQuery.viewInsetsOf(ctx).bottom + 18,
          ),
          child: ListenableBuilder(
            listenable: vm,
            builder: (ctx, _) {
              return GlassCard(
                borderRadius: 28,
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Подключение к компьютеру',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      vm.connected
                          ? 'Подключено к ${vm.hostname} (${vm.api.host})'
                          : 'Убедитесь, что телефон и ПК в одной сети Wi-Fi',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: ctrl,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                      decoration: InputDecoration(
                        hintText: '192.168.0.103:5000',
                        hintStyle: const TextStyle(color: AppColors.textMuted),
                        filled: true,
                        fillColor: Colors.black.withOpacity(0.4),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide:
                              const BorderSide(color: AppColors.glassBorder),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide:
                              const BorderSide(color: AppColors.crimsonBorder),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: GlassButton(
                            label: vm.discovering ? 'Поиск ПК...' : 'Автопоиск Wi-Fi',
                            icon: CupertinoIcons.wifi,
                            active: true,
                            onTap: () async {
                              final ok = await vm.scanNetworkForPc();
                              if (ok && ctx.mounted) {
                                ctrl.text = '${vm.api.host}:${vm.api.port}';
                                Navigator.pop(ctx);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: GlassButton(
                            label: 'Подключить',
                            primary: true,
                            onTap: () async {
                              await vm.updateHostManual(ctrl.text);
                              if (ctx.mounted) Navigator.pop(ctx);
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  void _openShutdownSheet(BuildContext context, RemoteViewModel vm) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
          child: GlassCard(
            borderRadius: 28,
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Выключить компьютер?',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Windows завершит работу немедленно.',
                  style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: GlassButton(
                        label: 'Отмена',
                        onTap: () => Navigator.pop(ctx),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: GlassButton(
                        label: 'Выключить',
                        primary: true,
                        onTap: () {
                          Navigator.pop(ctx);
                          vm.sendQuickCmd({'cmd': 'sys', 'act': 'shut', 'val': 0});
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TopStatusHeader extends StatelessWidget {
  final RemoteViewModel vm;
  final VoidCallback onTapConnect;

  const _TopStatusHeader({required this.vm, required this.onTapConnect});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: onTapConnect,
              child: Row(
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: vm.connected
                          ? AppColors.crimson
                          : Colors.white.withOpacity(0.24),
                      boxShadow: vm.connected
                          ? const [
                              BoxShadow(
                                color: AppColors.crimson,
                                blurRadius: 8,
                              ),
                            ]
                          : null,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Flexible(
                    child: Text(
                      vm.connected ? vm.hostname : 'Поиск ПК (${vm.api.host})',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          GestureDetector(
            onTap: onTapConnect,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: vm.aiReady
                    ? AppColors.crimsonSoft
                    : Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: vm.aiReady
                      ? AppColors.crimsonBorder
                      : AppColors.glassBorder,
                ),
              ),
              child: Text(
                vm.aiReady ? '${vm.aiModel} • Ready' : vm.aiModel,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: vm.aiReady
                      ? const Color(0xFFFF8FA3)
                      : AppColors.textSecondary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: onTapConnect,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: AppColors.glassBorder),
              ),
              child: const Icon(
                CupertinoIcons.slider_horizontal_3,
                size: 15,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VoiceAiTab extends StatefulWidget {
  final RemoteViewModel vm;

  const _VoiceAiTab({required this.vm});

  @override
  State<_VoiceAiTab> createState() => _VoiceAiTabState();
}

class _VoiceAiTabState extends State<_VoiceAiTab> {
  final TextEditingController _promptCtrl = TextEditingController();

  static const _quickChips = [
    ('Топ процессов RAM', 'покажи топ 5 процессов по памяти', true),
    ('Место на диске C', 'сколько свободного места на диске C', true),
    ('Создать папку Проект', 'создай на рабочем столе папку Проект', true),
    ('Bluetooth', 'открой настройки блютуз', true),
    ('YouTube', 'ыключи ютуб', false),
    ('Листай вниз', 'пролестни вниз', false),
    ('Листай вверх', 'пролестни вверх', false),
    ('Включи lofi', 'включи lofi hip hop', false),
    ('Пауза', 'пауза', false),
    ('Рабочий стол', 'сверни все', false),
  ];

  @override
  void dispose() {
    _promptCtrl.dispose();
    super.dispose();
  }

  void _submitText() {
    final txt = _promptCtrl.text.trim();
    if (txt.isEmpty) return;
    _promptCtrl.clear();
    FocusScope.of(context).unfocus();
    widget.vm.executeVoiceOrAi(txt);
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(
        14,
        6,
        14,
        math.max(98.0, bottomInset + 24.0),
      ),
      children: [
        GlassCard(
          child: Column(
            children: [
              Text(
                vm.statusHint,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight:
                      vm.isListening ? FontWeight.w600 : FontWeight.w500,
                  color: vm.isListening
                      ? AppColors.crimson
                      : AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              CrimsonMicOrb(
                isListening: vm.isListening,
                isBusy: vm.isBusyAi,
                onTap: vm.toggleMic,
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  _ModeChip(
                    label: vm.forceAiMode
                        ? 'Qwen CLI: ВСЕГДА'
                        : 'Qwen CLI: УМНЫЙ',
                    active: vm.forceAiMode,
                    onTap: vm.toggleForceAiMode,
                  ),
                  _ModeChip(
                    label:
                        'Hands-Free: ${vm.handsFree ? "ВКЛ" : "ВЫКЛ"}',
                    active: vm.handsFree,
                    onTap: vm.toggleHandsFree,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _promptCtrl,
                      scrollPadding: const EdgeInsets.only(bottom: 120),
                      onSubmitted: (_) => _submitText(),
                      style:
                          const TextStyle(color: Colors.white, fontSize: 14.5),
                      decoration: InputDecoration(
                        hintText: 'Скажите или напишите задачу для ПК...',
                        hintStyle:
                            const TextStyle(color: AppColors.textMuted),
                        filled: true,
                        fillColor: Colors.black.withOpacity(0.38),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide:
                              const BorderSide(color: AppColors.glassBorder),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide:
                              const BorderSide(color: AppColors.crimsonBorder),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GlassButton(
                    label: '',
                    icon: CupertinoIcons.arrow_up,
                    primary: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 15,
                      vertical: 13,
                    ),
                    onTap: _submitText,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Computer Use Terminal Output Card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(13),
                decoration: BoxDecoration(
                  color: const Color.fromRGBO(5, 5, 8, 0.68),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.08),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Container(
                                width: 7,
                                height: 7,
                                decoration: const BoxDecoration(
                                  color: AppColors.crimson,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 6),
                              const Flexible(
                                child: Text(
                                  'Computer Use • PowerShell',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (vm.lastLatencyMs != null) ...[
                          const SizedBox(width: 8),
                          Text(
                            '${vm.lastLatencyMs} мс',
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 7),
                    Text(
                      vm.transcript,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    if (vm.lastCommand.isNotEmpty) ...[
                      const SizedBox(height: 7),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.crimson.withOpacity(0.09),
                          borderRadius: BorderRadius.circular(8),
                          border: const Border(
                            left: BorderSide(
                              color: AppColors.crimson,
                              width: 2.2,
                            ),
                          ),
                        ),
                        child: SelectableText(
                          'PS> ${vm.lastCommand}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11.5,
                            color: Color(0xFFFF758F),
                          ),
                        ),
                      ),
                    ],
                    if (vm.lastFeedback.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        vm.lastFeedback,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: Color(0xFFFDA4AF),
                        ),
                      ),
                    ],
                    if (vm.lastOutput.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 140),
                        child: SingleChildScrollView(
                          child: SelectableText(
                            vm.lastOutput,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: Colors.white.withOpacity(0.78),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'БЫСТРЫЕ КОМАНДЫ И QWEN AI',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 7,
                runSpacing: 7,
                children: _quickChips.map((chip) {
                  return GestureDetector(
                    onTap: () => vm.executeVoiceOrAi(chip.$2),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: chip.$3
                            ? AppColors.crimson.withOpacity(0.10)
                            : Colors.white.withOpacity(0.04),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: chip.$3
                              ? AppColors.crimson.withOpacity(0.32)
                              : AppColors.glassBorder,
                        ),
                      ),
                      child: Text(
                        chip.$1,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
        if (vm.history.isNotEmpty) ...[
          const SizedBox(height: 12),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: Text(
                        'ИСТОРИЯ COMPUTER USE',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.8,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: vm.clearHistory,
                      child: const Text(
                        'Очистить',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFFFF758F),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ...vm.history.take(5).map(
                      (item) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 5),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Text(
                                    item.prompt,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                ),
                                Text(
                                  item.timestamp,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: AppColors.textMuted,
                                  ),
                                ),
                              ],
                            ),
                            if (item.command.isNotEmpty)
                              Text(
                                '> ${item.command}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontSize: 11,
                                  color: Color(0xFFFF758F),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _ModeChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _ModeChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? AppColors.crimsonSoft
              : Colors.white.withOpacity(0.04),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: active ? AppColors.crimsonBorder : AppColors.glassBorder,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
            color: active ? Colors.white : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _TrackpadTab extends StatefulWidget {
  final RemoteViewModel vm;

  const _TrackpadTab({required this.vm});

  @override
  State<_TrackpadTab> createState() => _TrackpadTabState();
}

class _TrackpadTabState extends State<_TrackpadTab> {
  final Map<int, Offset> _pointers = {};
  Offset? _tapOrigin;
  Offset? _twoFingerStartCentroid;
  Offset? _lastTwoFingerCentroid;
  DateTime? _downTime;
  int _maxPointersInGesture = 0;
  bool _exceededTapSlop = false;
  int _lastScrollMs = 0;

  Offset _computeCentroid() {
    if (_pointers.isEmpty) return Offset.zero;
    double sx = 0;
    double sy = 0;
    for (final p in _pointers.values) {
      sx += p.dx;
      sy += p.dy;
    }
    return Offset(sx / _pointers.length, sy / _pointers.length);
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 94),
      child: Column(
        children: [
          GlassCard(
            borderRadius: 18,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [0.8, 1.35, 2.0, 2.8].map((s) {
                        final selected = (vm.sensitivity - s).abs() < 0.05;
                        return Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: GestureDetector(
                            onTap: () => vm.setSensitivity(s),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: selected
                                    ? AppColors.crimsonSoft
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(999),
                                border: Border.all(
                                  color: selected
                                      ? AppColors.crimsonBorder
                                      : Colors.transparent,
                                ),
                              ),
                              child: Text(
                                '${s}x',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: selected
                                      ? Colors.white
                                      : AppColors.textSecondary,
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: vm.toggleScrollInverted,
                  child: Text(
                    vm.scrollInverted ? 'Скролл: Инв ↕' : 'Скролл ↕',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: vm.scrollInverted
                          ? AppColors.crimson
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Expanded(
            child: GlassCard(
              padding: EdgeInsets.zero,
              child: Row(
                children: [
                  Expanded(
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (e) {
                        _pointers[e.pointer] = e.localPosition;
                        if (_pointers.length == 1 && _maxPointersInGesture == 0) {
                          _tapOrigin = e.localPosition;
                          _twoFingerStartCentroid = null;
                          _lastTwoFingerCentroid = null;
                          _downTime = DateTime.now();
                          _exceededTapSlop = false;
                        } else if (_pointers.length == 2) {
                          final c = _computeCentroid();
                          _twoFingerStartCentroid ??= c;
                          _lastTwoFingerCentroid = c;
                        } else if (_pointers.length > 2) {
                          _exceededTapSlop = true;
                        }
                        if (_pointers.length > _maxPointersInGesture) {
                          _maxPointersInGesture = _pointers.length;
                        }
                      },
                      onPointerMove: (e) {
                        final prev = _pointers[e.pointer];
                        _pointers[e.pointer] = e.localPosition;
                        if (prev == null) return;

                        if (_pointers.length == 1 && _maxPointersInGesture == 1) {
                          if (!_exceededTapSlop && _tapOrigin != null) {
                            if ((e.localPosition - _tapOrigin!).distance > 6.5) {
                              _exceededTapSlop = true;
                            }
                          }
                          if (_exceededTapSlop) {
                            final delta = e.localPosition - prev;
                            vm.api.queuePointerMove(
                              delta.dx * 1.5,
                              delta.dy * 1.5,
                              vm.sensitivity,
                            );
                          }
                        } else if (_pointers.length >= 2) {
                          final centroid = _computeCentroid();
                          if (!_exceededTapSlop &&
                              _twoFingerStartCentroid != null &&
                              (centroid - _twoFingerStartCentroid!).distance >
                                  6.5) {
                            _exceededTapSlop = true;
                          }
                          final prevCentroid = _lastTwoFingerCentroid ?? centroid;
                          final dy = centroid.dy - prevCentroid.dy;
                          final now = DateTime.now().millisecondsSinceEpoch;
                          if (now - _lastScrollMs > 28 && dy.abs() > 1.8) {
                            _exceededTapSlop = true;
                            final signed = vm.scrollInverted ? dy : -dy;
                            vm.api.sendCmd({
                              'cmd': 'scroll',
                              'dy': (signed * 10).round(),
                            });
                            _lastTwoFingerCentroid = centroid;
                            _lastScrollMs = now;
                          }
                        }
                      },
                      onPointerUp: (e) {
                        _pointers.remove(e.pointer);
                        if (_pointers.isEmpty) {
                          final elapsed = _downTime == null
                              ? 999
                              : DateTime.now()
                                  .difference(_downTime!)
                                  .inMilliseconds;
                          if (!_exceededTapSlop && elapsed < 280) {
                            if (_maxPointersInGesture == 1) {
                              vm.sendQuickCmd({'cmd': 'click', 'btn': 'left'});
                            } else if (_maxPointersInGesture == 2) {
                              vm.sendQuickCmd({'cmd': 'click', 'btn': 'right'});
                            }
                          }
                          _maxPointersInGesture = 0;
                          _twoFingerStartCentroid = null;
                          _lastTwoFingerCentroid = null;
                        }
                      },
                      onPointerCancel: (e) {
                        _pointers.remove(e.pointer);
                        if (_pointers.isEmpty) {
                          _maxPointersInGesture = 0;
                          _twoFingerStartCentroid = null;
                          _lastTwoFingerCentroid = null;
                        }
                      },
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'TRACKPAD',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 3,
                                color: Colors.white.withOpacity(0.14),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '1 палец — курсор • 2 пальца — скролл / ПКМ',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.white.withOpacity(0.18),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Dedicated Right-Edge Scroll Strip
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onVerticalDragUpdate: (d) {
                      final now = DateTime.now().millisecondsSinceEpoch;
                      if (now - _lastScrollMs > 28) {
                        final raw = -(d.primaryDelta ?? 0);
                        final signed = vm.scrollInverted ? -raw : raw;
                        final scrollDelta = (signed * 13).round();
                        if (scrollDelta.abs() > 3) {
                          vm.api.sendCmd({'cmd': 'scroll', 'dy': scrollDelta});
                          _lastScrollMs = now;
                        }
                      }
                    },
                    child: Container(
                      width: 44,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.025),
                        border: Border(
                          left: BorderSide(
                            color: Colors.white.withOpacity(0.07),
                          ),
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Icon(
                            CupertinoIcons.chevron_up,
                            size: 13,
                            color: AppColors.textMuted,
                          ),
                          Icon(
                            CupertinoIcons.arrow_up_arrow_down,
                            size: 13,
                            color: AppColors.textMuted,
                          ),
                          Icon(
                            CupertinoIcons.chevron_down,
                            size: 13,
                            color: AppColors.textMuted,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: GlassButton(
                  label: 'ЛКМ',
                  onTap: () => vm.sendQuickCmd({'cmd': 'click', 'btn': 'left'}),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: GlassButton(
                  label: 'СКМ',
                  onTap: () =>
                      vm.sendQuickCmd({'cmd': 'click', 'btn': 'middle'}),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: GlassButton(
                  label: 'ПКМ',
                  onTap: () =>
                      vm.sendQuickCmd({'cmd': 'click', 'btn': 'right'}),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: GlassButton(
                  label: '2×',
                  onTap: () =>
                      vm.sendQuickCmd({'cmd': 'click', 'double': true}),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: GlassButton(
                  label: vm.dragLocked ? 'Отп.' : 'Захват',
                  primary: vm.dragLocked,
                  onTap: vm.toggleDragLock,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MediaTab extends StatefulWidget {
  final RemoteViewModel vm;

  const _MediaTab({required this.vm});

  @override
  State<_MediaTab> createState() => _MediaTabState();
}

class _MediaTabState extends State<_MediaTab> {
  final TextEditingController _ytCtrl = TextEditingController();

  @override
  void dispose() {
    _ytCtrl.dispose();
    super.dispose();
  }

  void _playYt() {
    final q = _ytCtrl.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    widget.vm.playYoutube(q);
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(
        14,
        6,
        14,
        math.max(98.0, bottomInset + 24.0),
      ),
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'YOUTUBE',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ytCtrl,
                      onSubmitted: (_) => _playYt(),
                      style:
                          const TextStyle(color: Colors.white, fontSize: 14.5),
                      decoration: InputDecoration(
                        hintText: 'Найти и сразу включить видео...',
                        hintStyle:
                            const TextStyle(color: AppColors.textMuted),
                        filled: true,
                        fillColor: Colors.black.withOpacity(0.38),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide:
                              const BorderSide(color: AppColors.glassBorder),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide:
                              const BorderSide(color: AppColors.crimsonBorder),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GlassButton(
                    label: '',
                    icon: CupertinoIcons.play_fill,
                    primary: true,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 15,
                      vertical: 13,
                    ),
                    onTap: _playYt,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: GlassButton(
                      label: 'Главная YouTube',
                      onTap: () => vm.sendQuickCmd({
                        'cmd': 'open_url',
                        'url': 'https://www.youtube.com',
                      }),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: GlassButton(
                      label: 'Полный экран',
                      onTap: () =>
                          vm.sendQuickCmd({'cmd': 'media', 'action': 'f'}),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: GlassButton(
                      label: 'Листать вниз',
                      onTap: () => vm.sendQuickCmd({
                        'cmd': 'scroll',
                        'direction': 'down',
                      }),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: GlassButton(
                      label: 'Листать вверх',
                      onTap: () =>
                          vm.sendQuickCmd({'cmd': 'scroll', 'direction': 'up'}),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassCard(
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GlassButton(
                    label: '−5с',
                    onTap: () =>
                        vm.sendQuickCmd({'cmd': 'media', 'action': 'left'}),
                  ),
                  const SizedBox(width: 18),
                  GestureDetector(
                    onTap: () => vm.sendQuickCmd({
                      'cmd': 'media',
                      'action': 'playpause_yt',
                    }),
                    child: Container(
                      width: 68,
                      height: 68,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [AppColors.crimson, AppColors.crimsonDeep],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Color.fromRGBO(255, 45, 85, 0.38),
                            blurRadius: 22,
                            offset: Offset(0, 6),
                          ),
                        ],
                      ),
                      child: const Icon(
                        CupertinoIcons.playpause_fill,
                        color: Colors.white,
                        size: 26,
                      ),
                    ),
                  ),
                  const SizedBox(width: 18),
                  GlassButton(
                    label: '+5с',
                    onTap: () =>
                        vm.sendQuickCmd({'cmd': 'media', 'action': 'right'}),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: GlassButton(
                      label: '⏮',
                      onTap: () => vm.sendQuickCmd({
                        'cmd': 'media',
                        'action': 'prevtrack',
                      }),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: GlassButton(
                      label: '−10с',
                      onTap: () =>
                          vm.sendQuickCmd({'cmd': 'media', 'action': 'j'}),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: GlassButton(
                      label: '+10с',
                      onTap: () =>
                          vm.sendQuickCmd({'cmd': 'media', 'action': 'l'}),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: GlassButton(
                      label: '⏭',
                      onTap: () => vm.sendQuickCmd({
                        'cmd': 'media',
                        'action': 'nexttrack',
                      }),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: GlassButton(
                      label: 'Кинотеатр',
                      onTap: () => vm.sendQuickCmd({'cmd': 'key', 'key': 't'}),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: GlassButton(
                      label: 'Мини-окно',
                      onTap: () => vm.sendQuickCmd({'cmd': 'key', 'key': 'i'}),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: GlassButton(
                      label: vm.muted ? 'Unmute' : 'Mute',
                      active: vm.muted,
                      onTap: () => vm.sendQuickCmd({'cmd': 'volume_mute'}),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassCard(
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Громкость ПК',
                    style: TextStyle(fontSize: 13.5, color: Colors.white),
                  ),
                  Text(
                    '${vm.volume}%',
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFFF758F),
                    ),
                  ),
                ],
              ),
              Slider(
                value: vm.volume.toDouble().clamp(0, 100),
                min: 0,
                max: 100,
                onChanged: vm.setVolumeSlider,
              ),
              Row(
                children: [0, 35, 70, 100].map((v) {
                  return Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(right: v == 100 ? 0 : 7),
                      child: GlassButton(
                        label: '$v%',
                        onTap: () => vm.setVolumeSlider(v.toDouble()),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SystemPcTab extends StatefulWidget {
  final RemoteViewModel vm;
  final VoidCallback onConfirmShutdown;

  const _SystemPcTab({
    required this.vm,
    required this.onConfirmShutdown,
  });

  @override
  State<_SystemPcTab> createState() => _SystemPcTabState();
}

class _SystemPcTabState extends State<_SystemPcTab> {
  final TextEditingController _typeCtrl = TextEditingController();
  final TextEditingController _psCtrl = TextEditingController();
  String _psOutput = '';

  @override
  void dispose() {
    _typeCtrl.dispose();
    _psCtrl.dispose();
    super.dispose();
  }

  void _sendText(bool enter) {
    final txt = _typeCtrl.text;
    if (txt.isEmpty) return;
    _typeCtrl.clear();
    FocusScope.of(context).unfocus();
    widget.vm.sendQuickCmd({'cmd': 'type', 'text': txt, 'enter': enter});
  }

  Future<void> _sendPs() async {
    final cmd = _psCtrl.text.trim();
    if (cmd.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _psOutput = 'Выполнение...');
    final out = await widget.vm.runDirectPowerShell(cmd);
    if (mounted) {
      setState(() => _psOutput = out);
    }
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(
        14,
        6,
        14,
        math.max(98.0, bottomInset + 28.0),
      ),
      children: [
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'ВВОД ТЕКСТА И ГОРЯЧИЕ КЛАВИШИ',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _typeCtrl,
                scrollPadding: const EdgeInsets.only(bottom: 140),
                maxLines: 2,
                style: const TextStyle(color: Colors.white, fontSize: 14.5),
                decoration: InputDecoration(
                  hintText: 'Любой текст для мгновенной вставки на ПК...',
                  hintStyle: const TextStyle(color: AppColors.textMuted),
                  filled: true,
                  fillColor: Colors.black.withOpacity(0.38),
                  contentPadding: const EdgeInsets.all(12),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: AppColors.glassBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide:
                        const BorderSide(color: AppColors.crimsonBorder),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: GlassButton(
                      label: 'Вставить + Enter',
                      primary: true,
                      onTap: () => _sendText(true),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: GlassButton(
                      label: 'Вставить',
                      onTap: () => _sendText(false),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: GlassButton(
                      label: 'Enter',
                      onTap: () =>
                          vm.sendQuickCmd({'cmd': 'key', 'key': 'enter'}),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: GlassButton(
                      label: '⌫',
                      onTap: () =>
                          vm.sendQuickCmd({'cmd': 'key', 'key': 'backspace'}),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: GlassButton(
                      label: 'Esc',
                      onTap: () =>
                          vm.sendQuickCmd({'cmd': 'key', 'key': 'esc'}),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: GlassButton(
                      label: 'Alt+Tab',
                      onTap: () => vm.sendQuickCmd({
                        'cmd': 'hotkey',
                        'keys': ['alt', 'tab'],
                      }),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: GlassButton(
                      label: 'Win+D',
                      onTap: () => vm.sendQuickCmd({'cmd': 'minimize'}),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: GlassButton(
                      label: 'Ctrl+W',
                      onTap: () => vm.sendQuickCmd({
                        'cmd': 'hotkey',
                        'keys': ['ctrl', 'w'],
                      }),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: GlassButton(
                      label: 'Ctrl+T',
                      onTap: () => vm.sendQuickCmd({
                        'cmd': 'hotkey',
                        'keys': ['ctrl', 't'],
                      }),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: GlassButton(
                      label: 'Скрин',
                      onTap: () => vm.sendQuickCmd({
                        'cmd': 'hotkey',
                        'keys': ['win', 'shift', 's'],
                      }),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'ПРЯМАЯ КОМАНДА POWERSHELL',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _psCtrl,
                      scrollPadding: const EdgeInsets.only(bottom: 140),
                      onSubmitted: (_) => _sendPs(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontFamily: 'monospace',
                        fontSize: 13.5,
                      ),
                      decoration: InputDecoration(
                        hintText: 'ipconfig | findstr IPv4',
                        hintStyle: const TextStyle(color: AppColors.textMuted),
                        filled: true,
                        fillColor: Colors.black.withOpacity(0.38),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide:
                              const BorderSide(color: AppColors.glassBorder),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide:
                              const BorderSide(color: AppColors.crimsonBorder),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GlassButton(
                    label: 'PS>',
                    active: true,
                    onTap: _sendPs,
                  ),
                ],
              ),
              if (_psOutput.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SelectableText(
                    _psOutput,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: Color(0xFFFFB3C1),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassCard(
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Flexible(
                    child: Text(
                      'Яркость экрана',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'CPU ${vm.cpu.round()}% • RAM ${vm.ram.round()}% • ${vm.brightness}%',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFFF758F),
                      ),
                    ),
                  ),
                ],
              ),
              Slider(
                value: vm.brightness.toDouble().clamp(0, 100),
                min: 0,
                max: 100,
                onChanged: vm.setBrightnessSlider,
              ),
              Row(
                children: [
                  Expanded(
                    child: GlassButton(
                      label: 'Файлы',
                      onTap: () => vm.sendQuickCmd({
                        'cmd': 'open_app',
                        'name': 'explorer',
                      }),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: GlassButton(
                      label: 'Блокнот',
                      onTap: () => vm.sendQuickCmd({
                        'cmd': 'open_app',
                        'name': 'notepad',
                      }),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: GlassButton(
                      label: 'Кальк.',
                      onTap: () => vm.sendQuickCmd({
                        'cmd': 'open_app',
                        'name': 'calc',
                      }),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: GlassButton(
                      label: 'Задачи',
                      onTap: () => vm.sendQuickCmd({
                        'cmd': 'open_app',
                        'name': 'taskmgr',
                      }),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'ПИТАНИЕ',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.8,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: GlassButton(
                      label: '15м',
                      onTap: () => vm.sendQuickCmd({
                        'cmd': 'sys',
                        'act': 'shut',
                        'val': 900,
                      }),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: GlassButton(
                      label: '30м',
                      onTap: () => vm.sendQuickCmd({
                        'cmd': 'sys',
                        'act': 'shut',
                        'val': 1800,
                      }),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: GlassButton(
                      label: '1ч',
                      onTap: () => vm.sendQuickCmd({
                        'cmd': 'sys',
                        'act': 'shut',
                        'val': 3600,
                      }),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: GlassButton(
                      label: 'Отмена',
                      onTap: () =>
                          vm.sendQuickCmd({'cmd': 'sys', 'act': 'shut_cancel'}),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: GlassButton(
                      label: 'Блок',
                      onTap: () =>
                          vm.sendQuickCmd({'cmd': 'sys', 'act': 'lock'}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: GlassButton(
                      label: 'Сон',
                      onTap: () =>
                          vm.sendQuickCmd({'cmd': 'sys', 'act': 'sleep'}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: GlassButton(
                      label: 'Выкл ПК',
                      active: true,
                      onTap: widget.onConfirmShutdown,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
