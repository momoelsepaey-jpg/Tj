import 'dart:math';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

// ---------- منطق الفترة الصامتة ----------
bool inQuietPeriod(DateTime now, int startMin, int endMin) {
  if (startMin == endMin) return false;
  final n = now.hour * 60 + now.minute;
  if (startMin < endMin) return n >= startMin && n < endMin;
  return n >= startMin || n < endMin; // الفترة تعبر منتصف الليل
}

// ---------- مهمة الخلفية ----------
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(ReminderHandler());
}

class ReminderHandler extends TaskHandler {
  final AudioPlayer _player = AudioPlayer();
  final Random _rnd = Random();

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    final quietOn =
        await FlutterForegroundTask.getData<bool>(key: 'quietOn') ?? false;
    final s = await FlutterForegroundTask.getData<int>(key: 'quietStart') ?? 0;
    final e = await FlutterForegroundTask.getData<int>(key: 'quietEnd') ?? 0;
    if (quietOn && inQuietPeriod(DateTime.now(), s, e)) return;

    final list =
        (await FlutterForegroundTask.getData<String>(key: 'sounds') ?? '')
            .split('|')
            .where((x) => x.isNotEmpty)
            .toList();
    if (list.isEmpty) return;

    final path = list[_rnd.nextInt(list.length)].replaceFirst('assets/', '');
    await _player.stop();
    await _player.play(AssetSource(path));
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    await _player.dispose();
  }
}

// ---------- التطبيق ----------
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  runApp(const DhikrApp());
}

class DhikrApp extends StatelessWidget {
  const DhikrApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'منبه الذاكرين',
      locale: const Locale('ar'),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF1B7F5C),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _minutes = TextEditingController(text: '15');
  bool _running = false;
  bool _quietOn = true;
  bool _loaded = false;
  TimeOfDay _qs = const TimeOfDay(hour: 23, minute: 0);
  TimeOfDay _qe = const TimeOfDay(hour: 5, minute: 0);

  @override
  void initState() {
    super.initState();
    _load();
  }

  int _toMin(TimeOfDay t) => t.hour * 60 + t.minute;
  TimeOfDay _fromMin(int m) => TimeOfDay(hour: m ~/ 60, minute: m % 60);

  void _initService(int minutes) {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'dhikr_channel',
        channelName: 'منبه الذاكرين',
        channelDescription: 'التذكير الصوتي يعمل في الخلفية',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(minutes * 60 * 1000),
        autoRunOnBoot: true,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  Future<void> _load() async {
    final m = await FlutterForegroundTask.getData<int>(key: 'minutes') ?? 15;
    final qo = await FlutterForegroundTask.getData<bool>(key: 'quietOn') ?? true;
    final qs = await FlutterForegroundTask.getData<int>(key: 'quietStart');
    final qe = await FlutterForegroundTask.getData<int>(key: 'quietEnd');
    _initService(m);
    final running = await FlutterForegroundTask.isRunningService;
    if (!mounted) return;
    setState(() {
      _minutes.text = '$m';
      _quietOn = qo;
      if (qs != null) _qs = _fromMin(qs);
      if (qe != null) _qe = _fromMin(qe);
      _running = running;
      _loaded = true;
    });
  }

  int? _validMinutes() {
    final m = int.tryParse(_minutes.text.trim());
    return (m == null || m < 1) ? null : m;
  }

  Future<void> _saveSettings() async {
    final m = _validMinutes();
    if (m != null) {
      await FlutterForegroundTask.saveData(key: 'minutes', value: m);
    }
    await FlutterForegroundTask.saveData(key: 'quietOn', value: _quietOn);
    await FlutterForegroundTask.saveData(key: 'quietStart', value: _toMin(_qs));
    await FlutterForegroundTask.saveData(key: 'quietEnd', value: _toMin(_qe));
  }

  void _msg(String t) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(t)));

  Future<void> _start() async {
    final m = _validMinutes();
    if (m == null) {
      _msg('اكتب عدد الدقائق بالأرقام (1 أو أكثر)');
      return;
    }
    if (await FlutterForegroundTask.checkNotificationPermission() !=
        NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }

    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final sounds = manifest
        .listAssets()
        .where((a) =>
            a.startsWith('assets/sounds/') &&
            RegExp(r'\.(wav|mp3|ogg|m4a)$').hasMatch(a))
        .toList()
      ..sort();
    if (sounds.isEmpty) {
      _msg('لا توجد ملفات صوتية داخل assets/sounds');
      return;
    }
    await FlutterForegroundTask.saveData(key: 'sounds', value: sounds.join('|'));
    await _saveSettings();
    _initService(m);

    await FlutterForegroundTask.startService(
      serviceId: 300,
      notificationTitle: 'منبه الذاكرين يعمل',
      notificationText: 'تذكير كل $m دقيقة',
      callback: startCallback,
    );
    if (mounted) setState(() => _running = true);
  }

  Future<void> _stop() async {
    await FlutterForegroundTask.stopService();
    if (mounted) setState(() => _running = false);
  }

  // تطبيق أي تعديل أثناء التشغيل: إعادة تشغيل الخدمة بالإعدادات الجديدة
  Future<void> _applyChange() async {
    await _saveSettings();
    if (_running) {
      await _stop();
      await _start();
    }
  }

  Future<void> _pick(bool start) async {
    final t = await showTimePicker(
        context: context, initialTime: start ? _qs : _qe);
    if (t == null) return;
    setState(() => start ? _qs = t : _qe = t);
    await _applyChange();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('منبه الذاكرين'), centerTitle: true),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        // زر التفعيل / التعطيل
        Card(
          color: _running ? cs.primaryContainer : cs.surfaceContainerHighest,
          child: SwitchListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            title: Text(_running ? 'التذكير مفعّل' : 'التذكير معطّل',
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            subtitle: Text(_running ? 'اضغط للتعطيل' : 'اضغط للتفعيل'),
            value: _running,
            onChanged: (v) => v ? _start() : _stop(),
          ),
        ),
        const SizedBox(height: 16),
        // الفاصل الزمني
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('الفاصل بين كل ذكر وآخر',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              TextField(
                controller: _minutes,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                    border: OutlineInputBorder(), suffixText: 'دقيقة'),
                onSubmitted: (_) => _applyChange(),
                onTapOutside: (_) {
                  FocusScope.of(context).unfocus();
                  _applyChange();
                },
              ),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        // الفترة التي يتوقف فيها التذكير
        Card(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(children: [
              SwitchListTile(
                title: const Text('فترة إيقاف التذكير',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                subtitle: const Text('لا يُشغَّل أي ذكر خلال هذه الفترة'),
                value: _quietOn,
                onChanged: (v) async {
                  setState(() => _quietOn = v);
                  await _applyChange();
                },
              ),
              if (_quietOn)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Row(children: [
                    Expanded(
                        child: OutlinedButton(
                            onPressed: () => _pick(true),
                            child: Text('من ${_qs.format(context)}'))),
                    const SizedBox(width: 12),
                    Expanded(
                        child: OutlinedButton(
                            onPressed: () => _pick(false),
                            child: Text('إلى ${_qe.format(context)}'))),
                  ]),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'بعض الأجهزة (شاومي، هواوي، أوبو...) تحتاج تفعيل "التشغيل التلقائي" وإيقاف توفير البطارية للتطبيق حتى يعمل في الخلفية.',
          style: TextStyle(color: cs.outline, fontSize: 12),
        ),
      ]),
    );
  }
}
