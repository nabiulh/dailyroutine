import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:uuid/uuid.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.instance.initialize();
  runApp(const TutorFlowApp());
}

// ---------------------------------------------------------------------------
// DATA MODEL
// ---------------------------------------------------------------------------

class BatchRoutine {
  final String id;
  final String name;
  final String subjectOrDetails;
  final int dayOfWeek; // 1 = Monday ... 7 = Sunday
  final int startHour;
  final int startMinute;
  final int endHour;
  final int endMinute;
  final int colorValue;

  const BatchRoutine({
    required this.id,
    required this.name,
    required this.subjectOrDetails,
    required this.dayOfWeek,
    required this.startHour,
    required this.startMinute,
    required this.endHour,
    required this.endMinute,
    required this.colorValue,
  });

  TimeOfDay get startTime => TimeOfDay(hour: startHour, minute: startMinute);
  TimeOfDay get endTime => TimeOfDay(hour: endHour, minute: endMinute);

  int get startMinutesOfDay => startHour * 60 + startMinute;
  int get endMinutesOfDay => endHour * 60 + endMinute;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'subjectOrDetails': subjectOrDetails,
        'dayOfWeek': dayOfWeek,
        'startHour': startHour,
        'startMinute': startMinute,
        'endHour': endHour,
        'endMinute': endMinute,
        'colorValue': colorValue,
      };

  factory BatchRoutine.fromJson(Map<String, dynamic> map) => BatchRoutine(
        id: map['id'] as String? ?? const Uuid().v4(),
        name: map['name'] as String? ?? 'Unnamed Batch',
        subjectOrDetails: map['subjectOrDetails'] as String? ?? '',
        dayOfWeek: (map['dayOfWeek'] as num?)?.toInt() ?? 1,
        startHour: (map['startHour'] as num?)?.toInt() ?? 9,
        startMinute: (map['startMinute'] as num?)?.toInt() ?? 0,
        endHour: (map['endHour'] as num?)?.toInt() ?? 10,
        endMinute: (map['endMinute'] as num?)?.toInt() ?? 0,
        colorValue: (map['colorValue'] as num?)?.toInt() ?? 0xFF4F46E5,
      );

  BatchRoutine copyWith({
    String? id,
    String? name,
    String? subjectOrDetails,
    int? dayOfWeek,
    int? startHour,
    int? startMinute,
    int? endHour,
    int? endMinute,
    int? colorValue,
  }) {
    return BatchRoutine(
      id: id ?? this.id,
      name: name ?? this.name,
      subjectOrDetails: subjectOrDetails ?? this.subjectOrDetails,
      dayOfWeek: dayOfWeek ?? this.dayOfWeek,
      startHour: startHour ?? this.startHour,
      startMinute: startMinute ?? this.startMinute,
      endHour: endHour ?? this.endHour,
      endMinute: endMinute ?? this.endMinute,
      colorValue: colorValue ?? this.colorValue,
    );
  }
}

// ---------------------------------------------------------------------------
// NOTIFICATION SERVICE
// ---------------------------------------------------------------------------

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();

  Future<void> initialize() async {
    tz.initializeTimeZones();
    try {
      final dynamic locationName = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(locationName.toString()));
    } catch (_) {
      tz.setLocalLocation(tz.local);
    }

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _notifications.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
    );

    final androidPlugin = _notifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      await androidPlugin.requestNotificationsPermission();
      await androidPlugin.requestExactAlarmsPermission();
    }
  }

  Future<void> scheduleBatchReminders(List<BatchRoutine> routines) async {
    await _notifications.cancelAll();

    for (final routine in routines) {
      final notificationId = routine.id.hashCode.abs() % 100000;
      final scheduleDate = _nextInstanceOfDayAndTime(
        routine.dayOfWeek,
        routine.startHour,
        routine.startMinute - 15,
      );

      const androidDetails = AndroidNotificationDetails(
        'batch_reminders_channel',
        'Batch Reminders',
        channelDescription: 'Notifications sent 15 minutes before tutoring classes start.',
        importance: Importance.max,
        priority: Priority.high,
        showWhen: true,
      );

      const details = NotificationDetails(
        android: androidDetails,
        iOS: DarwinNotificationDetails(sound: 'default.caf'),
      );

      try {
        await _notifications.zonedSchedule(
          notificationId,
          'Class Starting Soon: ${routine.name}',
          '${routine.subjectOrDetails.isNotEmpty ? "${routine.subjectOrDetails} • " : ""}Starts at ${_formatTimeValues(routine.startHour, routine.startMinute)}',
          scheduleDate,
          details,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
        );
      } catch (_) {}
    }
  }

  tz.TZDateTime _nextInstanceOfDayAndTime(int targetDayOfWeek, int hour, int minute) {
    var computedHour = hour;
    var computedMinute = minute;

    if (computedMinute < 0) {
      computedMinute += 60;
      computedHour -= 1;
    }
    if (computedHour < 0) {
      computedHour += 24;
      targetDayOfWeek = targetDayOfWeek == 1 ? 7 : targetDayOfWeek - 1;
    }

    final now = tz.TZDateTime.now(tz.local);
    var scheduledDate = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      computedHour,
      computedMinute,
    );

    while (scheduledDate.weekday != targetDayOfWeek || scheduledDate.isBefore(now)) {
      scheduledDate = scheduledDate.add(const Duration(days: 1));
    }
    return scheduledDate;
  }
}

// ---------------------------------------------------------------------------
// APP ENTRY & THEME
// ---------------------------------------------------------------------------

class TutorFlowApp extends StatelessWidget {
  const TutorFlowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TutorFlow',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      home: const DashboardScreen(),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final baseColor = const Color(0xFF4F46E5);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme.fromSeed(
        seedColor: baseColor,
        brightness: brightness,
        primary: baseColor,
        surface: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
      ),
      scaffoldBackgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
      cardTheme: CardTheme(
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        color: isDark ? const Color(0xFF1E293B) : Colors.white,
      ),
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        backgroundColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
        surfaceTintColor: Colors.transparent,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// MAIN DASHBOARD SCREEN
// ---------------------------------------------------------------------------

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> with WidgetsBindingObserver {
  static const String _storageKey = 'tutorflow_batches_json_v1';
  List<BatchRoutine> _routines = [];
  int _selectedDay = DateTime.now().weekday;
  Timer? _ticker;
  DateTime _now = DateTime.now();

  final List<int> _palette = const [
    0xFF4F46E5, // Indigo
    0xFF0D9488, // Teal
    0xFFE11D48, // Rose
    0xFFD97706, // Amber
    0xFF7C3AED, // Violet
    0xFF0284C7, // Sky
    0xFF059669, // Emerald
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadRoutines();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _now = DateTime.now());
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(() => _now = DateTime.now());
    }
  }

  Future<void> _loadRoutines() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        setState(() {
          _routines = decoded.map((e) => BatchRoutine.fromJson(e as Map<String, dynamic>)).toList();
        });
        NotificationService.instance.scheduleBatchReminders(_routines);
        return;
      } catch (_) {}
    }
    _seedDefaultData();
  }

  void _seedDefaultData() {
    final initial = [
      BatchRoutine(
        id: const Uuid().v4(),
        name: 'Calculus & Vectors (Advanced)',
        subjectOrDetails: 'Room 302 • Chapter 4 Integrals',
        dayOfWeek: DateTime.now().weekday,
        startHour: _now.hour,
        startMinute: (_now.minute > 5 ? _now.minute - 5 : 0),
        endHour: (_now.hour + 1) % 24,
        endMinute: 30,
        colorValue: 0xFF4F46E5,
      ),
      BatchRoutine(
        id: const Uuid().v4(),
        name: 'Mechanics & Thermodynamics',
        subjectOrDetails: 'Online Lab • Batch Alpha',
        dayOfWeek: DateTime.now().weekday,
        startHour: (_now.hour + 2) % 24,
        startMinute: 0,
        endHour: (_now.hour + 3) % 24,
        endMinute: 15,
        colorValue: 0xFF0D9488,
      ),
    ];
    setState(() => _routines = initial);
    _saveRoutines();
  }

  Future<void> _saveRoutines() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_routines.map((e) => e.toJson()).toList());
    await prefs.setString(_storageKey, encoded);
    NotificationService.instance.scheduleBatchReminders(_routines);
  }

  void _addOrUpdateRoutine(BatchRoutine routine) {
    setState(() {
      final index = _routines.indexWhere((r) => r.id == routine.id);
      if (index >= 0) {
        _routines[index] = routine;
      } else {
        _routines.add(routine);
      }
    });
    _saveRoutines();
  }

  void _deleteRoutine(String id) {
    setState(() => _routines.removeWhere((r) => r.id == id));
    _saveRoutines();
  }

  Future<void> _exportData() async {
    final jsonString = const JsonEncoder.withIndent('  ').convert(_routines.map((e) => e.toJson()).toList());
    await Share.share(
      jsonString,
      subject: 'TutorFlow_Backup_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.json',
    );
  }

  Future<void> _importData() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json', 'txt'],
      );
      if (result == null || result.files.single.path == null) return;

      final file = File(result.files.single.path!);
      final content = await file.readAsString();
      final decoded = jsonDecode(content);

      if (decoded is List) {
        final imported = decoded.map((e) => BatchRoutine.fromJson(e as Map<String, dynamic>)).toList();
        setState(() => _routines = imported);
        await _saveRoutines();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Successfully imported ${imported.length} batches.')),
          );
        }
      } else {
        throw const FormatException('Invalid JSON payload structure');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import Failed: Invalid routine structure ($e)')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final todayRoutines = _routines.where((r) => r.dayOfWeek == _selectedDay).toList()
      ..sort((a, b) => a.startMinutesOfDay.compareTo(b.startMinutesOfDay));

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'TutorFlow',
          style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.5),
        ),
        actions: [
          IconButton(
            tooltip: 'Export Backup',
            icon: const Icon(Icons.file_upload_outlined),
            onPressed: _exportData,
          ),
          IconButton(
            tooltip: 'Import Backup',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: _importData,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: _buildDynamicDashboardCard(),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12.0),
              child: _buildDaySelector(),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
            sliver: todayRoutines.isEmpty
                ? SliverFillRemaining(
                    hasScrollBody: false,
                    child: _buildEmptyState(),
                  )
                : SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final routine = todayRoutines[index];
                        return _buildBatchCard(routine);
                      },
                      childCount: todayRoutines.length,
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: const Color(0xFF4F46E5),
        foregroundColor: Colors.white,
        elevation: 4,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add Batch', style: TextStyle(fontWeight: FontWeight.bold)),
        onPressed: () => _openRoutineFormSheet(context),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // DASHBOARD CARD
  // -------------------------------------------------------------------------

  Widget _buildDynamicDashboardCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final nowMinutes = _now.hour * 60 + _now.minute;

    final todayAll = _routines.where((r) => r.dayOfWeek == _now.weekday).toList()
      ..sort((a, b) => a.startMinutesOfDay.compareTo(b.startMinutesOfDay));

    final liveBatch = todayAll.where((r) => nowMinutes >= r.startMinutesOfDay && nowMinutes < r.endMinutesOfDay).firstOrNull;

    BatchRoutine? nextBatch;
    if (liveBatch == null) {
      nextBatch = todayAll.where((r) => r.startMinutesOfDay > nowMinutes).firstOrNull;
    }

    String countdownText = 'No more classes today';
    if (liveBatch != null) {
      final rem = liveBatch.endMinutesOfDay - nowMinutes;
      countdownText = 'Live class ends in ${rem}m';
    } else if (nextBatch != null) {
      final diff = nextBatch.startMinutesOfDay - nowMinutes;
      final hours = diff ~/ 60;
      final mins = diff % 60;
      countdownText = hours > 0 ? 'Next class in ${hours}h ${mins}m' : 'Next class in ${mins}m';
    }

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(
          colors: isDark
              ? [const Color(0xFF1E293B), const Color(0xFF0F172A)]
              : [const Color(0xFF4F46E5), const Color(0xFF3730A3)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF4F46E5).withOpacity(0.25),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                DateFormat('EEEE, MMM d').format(_now).toUpperCase(),
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  DateFormat('HH:mm:ss').format(_now),
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            liveBatch != null ? 'Active: ${liveBatch.name}' : 'Daily Schedule',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
            maxLines: 1,
            overflow: TextFilter.ellipsis,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(
                liveBatch != null ? Icons.sensors_rounded : Icons.schedule_rounded,
                color: liveBatch != null ? const Color(0xFF4ADE80) : Colors.white70,
                size: 16,
              ),
              const SizedBox(width: 6),
              Text(
                countdownText,
                style: TextStyle(
                  color: liveBatch != null ? const Color(0xFF4ADE80) : Colors.white70,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              const Spacer(),
              Text(
                '${todayAll.length} batches today',
                style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // DAY SELECTOR
  // -------------------------------------------------------------------------

  Widget _buildDaySelector() {
    final days = [
      {'val': 1, 'short': 'Mon', 'label': 'Monday'},
      {'val': 2, 'short': 'Tue', 'label': 'Tuesday'},
      {'val': 3, 'short': 'Wed', 'label': 'Wednesday'},
      {'val': 4, 'short': 'Thu', 'label': 'Thursday'},
      {'val': 5, 'short': 'Fri', 'label': 'Friday'},
      {'val': 6, 'short': 'Sat', 'label': 'Saturday'},
      {'val': 7, 'short': 'Sun', 'label': 'Sunday'},
    ];

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return SizedBox(
      height: 48,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: days.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final item = days[index];
          final dayVal = item['val'] as int;
          final isSelected = dayVal == _selectedDay;
          final isToday = dayVal == _now.weekday;

          return InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: () => setState(() => _selectedDay = dayVal),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFF4F46E5)
                    : isDark
                        ? const Color(0xFF1E293B)
                        : Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: isToday && !isSelected
                      ? const Color(0xFF4F46E5)
                      : Colors.transparent,
                  width: 1.5,
                ),
              ),
              child: Row(
                children: [
                  Text(
                    item['short'] as String,
                    style: TextStyle(
                      color: isSelected
                          ? Colors.white
                          : isDark
                              ? Colors.white70
                              : const Color(0xFF475569),
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                  if (isToday) ...[
                    const SizedBox(width: 4),
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isSelected ? Colors.white : const Color(0xFF4F46E5),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // -------------------------------------------------------------------------
  // BATCH CARD WITH LIVE PROGRESS
  // -------------------------------------------------------------------------

  Widget _buildBatchCard(BatchRoutine routine) {
    final isToday = routine.dayOfWeek == _now.weekday;
    final nowMinutes = _now.hour * 60 + _now.minute;
    final isLive = isToday && (nowMinutes >= routine.startMinutesOfDay && nowMinutes < routine.endMinutesOfDay);

    double progress = 0.0;
    if (isLive) {
      final total = routine.endMinutesOfDay - routine.startMinutesOfDay;
      final elapsed = (nowMinutes * 60 + _now.second) - (routine.startMinutesOfDay * 60);
      progress = (elapsed / (total * 60)).clamp(0.0, 1.0);
    }

    final cardColor = Color(routine.colorValue);

    return Dismissible(
      key: Key(routine.id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFEF4444),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Icon(Icons.delete_sweep_rounded, color: Colors.white, size: 28),
      ),
      confirmDismiss: (_) async {
        return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Delete Routine?'),
            content: Text('Are you sure you want to remove "${routine.name}"?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFFEF4444)),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
      },
      onDismissed: (_) => _deleteRoutine(routine.id),
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _openRoutineFormSheet(context, routine: routine),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: isLive ? Border.all(color: cardColor, width: 2) : null,
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 4,
                        height: 48,
                        decoration: BoxDecoration(
                          color: cardColor,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    routine.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                      fontSize: 16,
                                      letterSpacing: -0.3,
                                    ),
                                  ),
                                ),
                                if (isLive) const LiveBadge(),
                              ],
                            ),
                            if (routine.subjectOrDetails.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                routine.subjectOrDetails,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Icon(Icons.access_time_rounded, size: 14, color: cardColor),
                                const SizedBox(width: 6),
                                Text(
                                  '${_formatTime(routine.startTime)} – ${_formatTime(routine.endTime)}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                    color: cardColor,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  '(${routine.endMinutesOfDay - routine.startMinutesOfDay} mins)',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(context).colorScheme.outline,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (isLive)
                  ClipRRect(
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 4,
                      backgroundColor: cardColor.withOpacity(0.15),
                      valueColor: AlwaysStoppedAnimation<Color>(cardColor),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.event_available_rounded, size: 64, color: Theme.of(context).colorScheme.outline.withOpacity(0.4)),
          const SizedBox(height: 12),
          const Text(
            'No Batches Scheduled',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            'Tap the button below to add your first routine.',
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // BOTTOM SHEET FORM (ADD / EDIT)
  // -------------------------------------------------------------------------

  void _openRoutineFormSheet(BuildContext context, {BatchRoutine? routine}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).cardTheme.color,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => _RoutineFormSheet(
        routine: routine,
        selectedDay: _selectedDay,
        palette: _palette,
        onSave: (savedRoutine) {
          _addOrUpdateRoutine(savedRoutine);
          Navigator.pop(ctx);
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// LIVE BADGE WIDGET
// ---------------------------------------------------------------------------

class LiveBadge extends StatefulWidget {
  const LiveBadge({super.key});

  @override
  State<LiveBadge> createState() => _LiveBadgeState();
}

class _LiveBadgeState extends State<LiveBadge> with SingleTickerProviderStateMixin {
  late AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0xFFEF4444),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('● ', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
            Text(
              'LIVE NOW',
              style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 0.5),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// FORM BOTTOM SHEET
// ---------------------------------------------------------------------------

class _RoutineFormSheet extends StatefulWidget {
  final BatchRoutine? routine;
  final int selectedDay;
  final List<int> palette;
  final Function(BatchRoutine) onSave;

  const _RoutineFormSheet({
    this.routine,
    required this.selectedDay,
    required this.palette,
    required this.onSave,
  });

  @override
  State<_RoutineFormSheet> createState() => _RoutineFormSheetState();
}

class _RoutineFormSheetState extends State<_RoutineFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _detailsController;
  late int _dayOfWeek;
  late TimeOfDay _startTime;
  late TimeOfDay _endTime;
  late int _selectedColor;

  @override
  void initState() {
    super.initState();
    final r = widget.routine;
    _nameController = TextEditingController(text: r?.name ?? '');
    _detailsController = TextEditingController(text: r?.subjectOrDetails ?? '');
    _dayOfWeek = r?.dayOfWeek ?? widget.selectedDay;
    _startTime = r != null ? r.startTime : const TimeOfDay(hour: 10, minute: 0);
    _endTime = r != null ? r.endTime : const TimeOfDay(hour: 11, minute: 30);
    _selectedColor = r?.colorValue ?? widget.palette.first;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _detailsController.dispose();
    super.dispose();
  }

  Future<void> _pickTime(bool isStart) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: isStart ? _startTime : _endTime,
    );
    if (picked != null) {
      setState(() {
        if (isStart) {
          _startTime = picked;
        } else {
          _endTime = picked;
        }
      });
    }
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

    final startMinutes = _startTime.hour * 60 + _startTime.minute;
    final endMinutes = _endTime.hour * 60 + _endTime.minute;

    if (endMinutes <= startMinutes) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('End time must be strictly after start time.')),
      );
      return;
    }

    final newRoutine = BatchRoutine(
      id: widget.routine?.id ?? const Uuid().v4(),
      name: _nameController.text.trim(),
      subjectOrDetails: _detailsController.text.trim(),
      dayOfWeek: _dayOfWeek,
      startHour: _startTime.hour,
      startMinute: _startTime.minute,
      endHour: _endTime.hour,
      endMinute: _endTime.minute,
      colorValue: _selectedColor,
    );

    widget.onSave(newRoutine);
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.routine != null;
    final days = [
      {'val': 1, 'name': 'Mon'},
      {'val': 2, 'name': 'Tue'},
      {'val': 3, 'name': 'Wed'},
      {'val': 4, 'name': 'Thu'},
      {'val': 5, 'name': 'Fri'},
      {'val': 6, 'name': 'Sat'},
      {'val': 7, 'name': 'Sun'},
    ];

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isEdit ? 'Edit Batch Routine' : 'Create New Batch',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, letterSpacing: -0.5),
              ),
              const SizedBox(height: 18),
              TextFormField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: 'Batch / Course Name',
                  filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  prefixIcon: const Icon(Icons.school_outlined),
                ),
                validator: (val) => val == null || val.trim().isEmpty ? 'Please enter batch title' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _detailsController,
                decoration: InputDecoration(
                  labelText: 'Subject / Room / Topic',
                  filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  prefixIcon: const Icon(Icons.menu_book_outlined),
                ),
              ),
              const SizedBox(height: 18),
              const Text('Day of Week', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: days.map((d) {
                  final val = d['val'] as int;
                  final isSelected = val == _dayOfWeek;
                  return ChoiceChip(
                    label: Text(d['name'] as String),
                    selected: isSelected,
                    showCheckmark: false,
                    onSelected: (selected) {
                      if (selected) setState(() => _dayOfWeek = val);
                    },
                  );
                }).toList(),
              ),
              const SizedBox(height: 18),
              const Text('Time Window', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickTime(true),
                      icon: const Icon(Icons.login_rounded, size: 18),
                      label: Text('Start: ${_formatTime(_startTime)}'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _pickTime(false),
                      icon: const Icon(Icons.logout_rounded, size: 18),
                      label: Text('End: ${_formatTime(_endTime)}'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              const Text('Tag Color', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: widget.palette.map((colorHex) {
                  final isSelected = colorHex == _selectedColor;
                  return GestureDetector(
                    onTap: () => setState(() => _selectedColor = colorHex),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Color(colorHex),
                        shape: BoxShape.circle,
                        border: isSelected ? Border.all(color: Colors.white, width: 3) : null,
                        boxShadow: isSelected
                            ? [
                                BoxShadow(
                                  color: Color(colorHex).withOpacity(0.6),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                )
                              ]
                            : null,
                      ),
                      child: isSelected ? const Icon(Icons.check, color: Colors.white, size: 18) : null,
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF4F46E5),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _submit,
                  child: Text(
                    isEdit ? 'Update Routine' : 'Save Batch',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// FORMATTING HELPERS
// ---------------------------------------------------------------------------

String _formatTime(TimeOfDay time) {
  return _formatTimeValues(time.hour, time.minute);
}

String _formatTimeValues(int hour, int minute) {
  final now = DateTime.now();
  final dt = DateTime(now.year, now.month, now.day, hour, minute);
  return DateFormat('hh:mm a').format(dt);
}
