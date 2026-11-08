import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:remote_pc_app/data/remote_api_service.dart';
import 'package:remote_pc_app/main.dart';
import 'package:remote_pc_app/ui/glass_widgets.dart';
import 'package:remote_pc_app/view_models/remote_view_model.dart';

void main() {
  testWidgets(
      'Renders Crimson-Black iOS Glass UI, switches tabs, and executes Qwen AI command',
      (WidgetTester tester) async {
    const channel = MethodChannel('com.remotepc.app/native');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    String? sentVoiceText;
    final mockClient = MockClient((request) async {
      if (request.url.path == '/status') {
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'status': 'ok',
            'hostname': 'GAMING-PC',
            'volume': 65,
            'mute': false,
            'brightness': 80,
            'cpu': 12.0,
            'ram': 44.0,
            'ai': {
              'ready': true,
              'state': 'ready',
              'short_name': 'Qwen 1.5B',
            },
          })),
          200,
        );
      }
      if (request.url.path == '/voice') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        sentVoiceText = body['text'] as String?;
        return http.Response.bytes(
          utf8.encode(jsonEncode({
            'status': 'ok',
            'command': 'Get-PSDrive C',
            'stdout': 'Свободно: 99.8 ГБ',
            'stderr': '',
            'feedback': 'Проверил диск C',
            'latency_ms': 950,
          })),
          200,
        );
      }
      if (request.url.path == '/ai/history') {
        return http.Response.bytes(
          utf8.encode(jsonEncode({'status': 'ok', 'history': []})),
          200,
        );
      }
      return http.Response.bytes(
        utf8.encode(jsonEncode({'status': 'ok'})),
        200,
      );
    });

    final api = RemoteApiService(client: mockClient, host: '192.168.0.103');
    final vm = RemoteViewModel(api: api);
    addTearDown(vm.dispose);
    await vm.initialize(enablePolling: false);
    await vm.refreshStatus();

    await tester.pumpWidget(RemotePcApp(viewModel: vm));
    await tester.pump();

    expect(find.text('GAMING-PC'), findsOneWidget);
    expect(find.byType(CrimsonMicOrb), findsOneWidget);
    expect(find.byType(IosLiquidGlassDock), findsOneWidget);

    // Trigger a Qwen AI quick chip
    await tester.ensureVisible(find.text('Место на диске C'));
    await tester.tap(find.text('Место на диске C'));
    await tester.pumpAndSettle();

    expect(sentVoiceText, 'сколько свободного места на диске C');
    expect(find.textContaining('PS> Get-PSDrive C'), findsOneWidget);
    expect(find.textContaining('Свободно: 99.8 ГБ'), findsOneWidget);

    // Navigate across dock tabs (Trackpad -> Media -> PC)
    await tester.tap(find.text('Тачпад'));
    await tester.pumpAndSettle();
    expect(find.text('TRACKPAD'), findsOneWidget);

    await tester.tap(find.text('Медиа'));
    await tester.pumpAndSettle();
    expect(find.text('YOUTUBE'), findsOneWidget);

    await tester.tap(find.text('ПК'));
    await tester.pumpAndSettle();
    expect(find.text('ПРЯМАЯ КОМАНДА POWERSHELL'), findsOneWidget);

    // Verify compact 340dp mobile viewport renders all tabs with zero overflow
    tester.view.physicalSize = const Size(340, 740);
    await tester.pumpAndSettle();
    for (final tabName in ['Qwen AI', 'Тачпад', 'Медиа', 'ПК']) {
      await tester.tap(find.text(tabName));
      await tester.pumpAndSettle();
    }
  });

  test(
      'Handles empty voice input, host:port edge cases, offline errors, and move coalescing',
      () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('com.remotepc.app/native');
    String? savedPref;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'savePref') {
        savedPref = (call.arguments as Map)['value'] as String?;
      }
      if (call.method == 'getPref') {
        return savedPref;
      }
      return null;
    });

    int voiceCalls = 0;
    final sentMoves = <Map<String, dynamic>>[];
    bool failRequests = false;

    final mockClient = MockClient((request) async {
      if (failRequests) {
        throw Exception('Network unreachable');
      }
      if (request.url.path == '/status') {
        return http.Response(
          jsonEncode({'status': 'ok', 'hostname': 'TEST-HOST'}),
          200,
        );
      }
      if (request.url.path == '/voice') {
        voiceCalls++;
        return http.Response(jsonEncode({'status': 'ok', 'feedback': 'OK'}), 200);
      }
      if (request.url.path == '/cmd') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['cmd'] == 'move') {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          sentMoves.add(body);
        }
        return http.Response(jsonEncode({'status': 'ok'}), 200);
      }
      return http.Response(jsonEncode({'status': 'ok', 'history': []}), 200);
    });

    final api = RemoteApiService(client: mockClient, host: '192.168.0.10');
    final vm = RemoteViewModel(api: api);
    await vm.initialize(enablePolling: false);

    // 1. Empty / whitespace voice input should not hit backend
    await vm.executeVoiceOrAi('    ');
    expect(voiceCalls, 0);

    // 2. Host + port parsing with URL scheme, trailing slash, and invalid port boundary
    await vm.updateHostManual('http://10.0.0.42:5055/index.html');
    expect(api.host, '10.0.0.42');
    expect(api.port, 5055);
    expect(savedPref, '10.0.0.42:5055');
    expect(vm.connected, isTrue);

    // Invalid port (>65535) and empty host (':99999') keep last valid host & port
    await vm.updateHostManual(':99999');
    expect(api.host, '10.0.0.42');
    expect(api.port, 5055);

    // 3. Offline error path gracefully sets feedback without throwing
    failRequests = true;
    await vm.executeVoiceOrAi('открой проводник');
    expect(vm.isBusyAi, isFalse);
    expect(vm.lastFeedback, contains('Нет связи с ПК'));
    await vm.refreshStatus();
    expect(vm.connected, isFalse);

    // 4. Coalesced pointer moves combine rapid deltas while 1 request is in-flight
    failRequests = false;
    api.queuePointerMove(5.0, -3.0, 1.0);
    api.queuePointerMove(2.0, -1.0, 1.0);
    api.queuePointerMove(3.0, -4.0, 1.0);
    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(sentMoves.length, 2);
    expect(sentMoves[0]['dx'], 5.0);
    expect(sentMoves[1]['dx'], 5.0);
    expect(sentMoves[1]['dy'], -5.0);

    vm.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets(
      'Hands-Free stops and preserves hint on permission error (9), but auto-restarts on silence (7)',
      (WidgetTester tester) async {
    const channel = MethodChannel('com.remotepc.app/native');
    int startListeningCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'startListening') {
        startListeningCalls++;
        return {'started': true};
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final mockClient = MockClient(
      (_) async => http.Response(jsonEncode({'status': 'ok', 'history': []}), 200),
    );
    final vm = RemoteViewModel(
      api: RemoteApiService(client: mockClient, host: '192.168.0.10'),
    );
    addTearDown(vm.dispose);
    await vm.initialize(enablePolling: false);

    // Enable Hands-Free -> 1st startListening call
    await vm.toggleHandsFree();
    expect(vm.handsFree, isTrue);
    expect(startListeningCalls, 1);

    // Transient silence error (code 7 = ERROR_NO_MATCH) should keep Hands-Free on and restart after 500ms
    const codec = StandardMethodCodec();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'com.remotepc.app/native',
      codec.encodeMethodCall(const MethodCall('onSpeechError', 7)),
      (_) {},
    );
    expect(vm.handsFree, isTrue);
    await tester.pump(const Duration(milliseconds: 600));
    expect(startListeningCalls, 2);

    // Fatal permission denial (code 9 = ERROR_INSUFFICIENT_PERMISSIONS) must disable Hands-Free,
    // preserve the permission hint, and NOT trigger an infinite startListening loop!
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'com.remotepc.app/native',
      codec.encodeMethodCall(const MethodCall('onSpeechError', 9)),
      (_) {},
    );
    expect(vm.handsFree, isFalse);
    expect(vm.statusHint, 'Разрешите доступ к микрофону');
    await tester.pump(const Duration(seconds: 2));
    expect(startListeningCalls, 2);
    expect(vm.statusHint, 'Разрешите доступ к микрофону');
  });

  testWidgets(
      'Two-finger smooth scroll does NOT fire spurious right-click; two-finger tap DOES right-click; soft keyboard hides dock & offline YouTube is caught',
      (WidgetTester tester) async {
    const channel = MethodChannel('com.remotepc.app/native');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    tester.view.physicalSize = const Size(412, 892);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
    });

    final sentCmds = <Map<String, dynamic>>[];
    bool failYt = false;
    final mockClient = MockClient((request) async {
      if (request.url.path == '/cmd') {
        sentCmds.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(jsonEncode({'status': 'ok'}), 200);
      }
      if (request.url.path == '/yt_search' && failYt) {
        throw Exception('SocketException: PC unreachable');
      }
      return http.Response(jsonEncode({'status': 'ok', 'history': []}), 200);
    });

    final vm = RemoteViewModel(
      api: RemoteApiService(client: mockClient, host: '192.168.0.10'),
    );
    addTearDown(vm.dispose);
    await vm.initialize(enablePolling: false);

    await tester.pumpWidget(RemotePcApp(viewModel: vm));
    await tester.pump();

    // 1. Switch to Trackpad tab
    await tester.tap(find.text('Тачпад'));
    await tester.pumpAndSettle();

    final padCenter = tester.getCenter(find.text('TRACKPAD'));

    // Smooth 2-finger scroll in small 2.8px per-frame increments (< 3.5px) within 150ms:
    final g1 = await tester.startGesture(padCenter - const Offset(20, 0));
    final g2 = await tester.startGesture(padCenter + const Offset(20, 0));
    for (int i = 0; i < 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 35)),
      );
      await g1.moveBy(const Offset(0, 2.8));
      await g2.moveBy(const Offset(0, 2.8));
      await tester.pump(const Duration(milliseconds: 35));
    }
    await g1.up();
    await g2.up();
    await tester.pump();

    expect(
      sentCmds.any((c) => c['cmd'] == 'scroll'),
      isTrue,
      reason: 'Two-finger drag must send scroll commands',
    );
    expect(
      sentCmds.any((c) => c['cmd'] == 'click' && c['btn'] == 'right'),
      isFalse,
      reason: 'Two-finger scroll must NEVER trigger spurious right-click on lift',
    );

    // Stationary 2-finger tap SHOULD still send right-click
    sentCmds.clear();
    final t1 = await tester.startGesture(padCenter - const Offset(20, 0));
    final t2 = await tester.startGesture(padCenter + const Offset(20, 0));
    await tester.pump(const Duration(milliseconds: 40));
    await t1.up();
    await t2.up();
    await tester.pump();
    expect(
      sentCmds.any((c) => c['cmd'] == 'click' && c['btn'] == 'right'),
      isTrue,
      reason: 'Stationary 2-finger tap must trigger right-click',
    );

    // 2. Offline YouTube search in Media tab must be caught gracefully (no unhandled async error)
    failYt = true;
    await tester.tap(find.text('Медиа'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Найти и сразу включить видео...'),
      'lofi beats',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(vm.toastMessage, contains('Нет связи с ПК'));
    await tester.pump(const Duration(milliseconds: 2300));

    // 3. Soft keyboard inset (300dp) on PC tab hides dock and keeps PowerShell TextField scrollable
    await tester.tap(find.text('ПК'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(
      left: 0,
      top: 0,
      right: 0,
      bottom: 300,
    );
    await tester.pumpAndSettle();
    final psField = find.widgetWithText(TextField, 'ipconfig | findstr IPv4');
    await tester.ensureVisible(psField);
    await tester.tap(psField);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}


