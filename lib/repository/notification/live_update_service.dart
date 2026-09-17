// Copyright 2025 Traintime PDA authors.
// SPDX-License-Identifier: MPL-2.0

// Android 16 Live Update integration for pre-class reminders.
//
// A Live Update is a standard Android notification that the system promotes to a more prominent
// surface: the top of the notification shade, the lock screen, and a chip in the status bar. It
// requires a notification style of Standard/BigText/Call/Progress/Metric, the
// POST_PROMOTED_NOTIFICATIONS manifest permission and an explicit promotion request.
//
// flutter_local_notifications cannot express `Notification.ProgressStyle` or
// `setRequestPromotedOngoing`, so reminders that should be Live Updates are handed to the Android
// side, which schedules them with AlarmManager and posts them from a BroadcastReceiver.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:watermeter/repository/logger.dart';

/// Whether this device and user can actually show a Live Update.
enum LiveUpdateAvailability {
  /// Android 16+ and the user allows promoted notifications for XDYou.
  ready,

  /// Below Android 16: `ProgressStyle` does not exist.
  platformUnsupported,

  /// Android 16+, but the user turned Live Updates off for XDYou in system settings.
  userDisabled;

  bool get canPost => this == LiveUpdateAvailability.ready;
}

/// Platform support for Live Updates on this device.
class LiveUpdateStatus {
  const LiveUpdateStatus({
    required this.availability,
    this.sdkInt = 0,
  });

  final LiveUpdateAvailability availability;

  /// `Build.VERSION.SDK_INT`; 36 is Android 16.
  final int sdkInt;

  /// Lowest API level that has Live Updates at all.
  static const int liveUpdateApi = 36;

  bool get canPost => availability.canPost;

  static const LiveUpdateStatus unsupported = LiveUpdateStatus(
    availability: LiveUpdateAvailability.platformUnsupported,
  );
}

/// One pre-class reminder to publish as a Live Update.
///
/// All text is already localized by the caller.
class LiveUpdateReminder {
  const LiveUpdateReminder({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.extraText,
    required this.digitText,
    required this.triggerAt,
    required this.startAt,
    required this.accentColor,
    required this.weekIndex,
  });

  /// Stable id. Doubles as the notification id and the native alarm request code, so it must be
  /// unique per reminder and must stay the same across reschedules of the same occurrence.
  final int id;

  /// Course name — the notification title.
  final String title;

  /// Start time and room, e.g. `08:30 · A-101`.
  final String subtitle;

  /// Teacher, shown as subtext. May be empty.
  final String extraText;

  /// Short start time such as `08:30`.
  final String digitText;

  /// When the reminder fires — the start of the progress journey.
  final DateTime triggerAt;

  /// When the class starts — the countdown target and when the Live Update ends.
  final DateTime startAt;

  /// ARGB accent for the progress track.
  final int accentColor;

  final int weekIndex;

  Map<String, Object?> toMap() => <String, Object?>{
    'id': id,
    'title': title,
    'subtitle': subtitle,
    'extraText': extraText,
    'digitText': digitText,
    'triggerAtMillis': triggerAt.millisecondsSinceEpoch,
    'startAtMillis': startAt.millisecondsSinceEpoch,
    'accentColor': accentColor,
    'weekIndex': weekIndex,
  };
}

/// What actually happened when a test reminder was published.
///
/// The wording is composed on this side so the message can be translated; the native side only
/// reports facts.
class LiveUpdatePublishResult {
  const LiveUpdatePublishResult({
    required this.posted,
    required this.promotable,
    required this.availability,
    this.failure,
  });

  /// The notification was handed to the system.
  final bool posted;

  /// The system considers the notification shaped for promotion.
  final bool promotable;

  final LiveUpdateAvailability availability;

  /// Native error text, when posting threw.
  final String? failure;
}

/// Dart side of the `live_update` MethodChannel.
class LiveUpdateService {
  LiveUpdateService._();

  static final LiveUpdateService _instance = LiveUpdateService._();

  factory LiveUpdateService() => _instance;

  static const MethodChannel _channel = MethodChannel(
    'io.github.benderblog.traintime_pda/live_update',
  );

  /// Accent colours, picked deterministically per course name so a course keeps its colour between
  /// reschedules.
  static const List<int> _accentPalette = <int>[
    0xFF1976D2, // blue
    0xFF00897B, // teal
    0xFF6A1B9A, // purple
    0xFFD81B60, // pink
    0xFFEF6C00, // orange
    0xFF2E7D32, // green
    0xFF455A64, // blue grey
    0xFF5D4037, // brown
  ];

  LiveUpdateStatus? _cachedStatus;
  Future<void> Function()? _openedHandler;
  bool _methodHandlerInstalled = false;

  /// Deterministic accent colour for a course, so the notification matches between runs.
  static int accentColorFor(String seed) {
    // FNV-1a, mirroring the id hashing used for notifications.
    var hash = 0x811C9DC5;
    for (final int unit in seed.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return _accentPalette[hash % _accentPalette.length];
  }

  /// Reports whether this device can show a Live Update.
  ///
  /// Cached; pass `refresh: true` to re-query, which the settings page does because the user may
  /// have just changed the permission in system settings.
  Future<LiveUpdateStatus> status({bool refresh = false}) async {
    if (!refresh && _cachedStatus != null) return _cachedStatus!;

    if (!Platform.isAndroid) {
      return _cachedStatus = LiveUpdateStatus.unsupported;
    }

    try {
      final Map<Object?, Object?>? raw = await _channel
          .invokeMethod<Map<Object?, Object?>>('getAvailability');
      _cachedStatus = LiveUpdateStatus(
        availability: _parseAvailability(raw?['availability'] as String?),
        sdkInt: (raw?['sdkInt'] as num?)?.toInt() ?? 0,
      );
    } on MissingPluginException {
      log.warning('[LiveUpdateService] Native Live Update bridge is unavailable');
      _cachedStatus = LiveUpdateStatus.unsupported;
    } on PlatformException catch (e, stackTrace) {
      log.error(
        '[LiveUpdateService] Failed to query Live Update availability',
        e,
        stackTrace,
      );
      _cachedStatus = LiveUpdateStatus.unsupported;
    }

    log.info(
      '[LiveUpdateService] Live Update availability: '
      '${_cachedStatus!.availability.name} (API ${_cachedStatus!.sdkInt})',
    );
    return _cachedStatus!;
  }

  static LiveUpdateAvailability _parseAvailability(String? raw) =>
      switch (raw) {
        'READY' => LiveUpdateAvailability.ready,
        'USER_DISABLED' => LiveUpdateAvailability.userDisabled,
        _ => LiveUpdateAvailability.platformUnsupported,
      };

  /// Replaces the whole reminder plan. Returns how many reminders were armed.
  Future<int> scheduleReminders(List<LiveUpdateReminder> reminders) async {
    if (!Platform.isAndroid) return 0;
    try {
      final int? armed = await _channel.invokeMethod<int>(
        'scheduleReminders',
        reminders.map((r) => r.toMap()).toList(),
      );
      log.info(
        '[LiveUpdateService] Native side armed ${armed ?? 0} of ${reminders.length} reminders',
      );
      return armed ?? 0;
    } on PlatformException catch (e, stackTrace) {
      log.error(
        '[LiveUpdateService] Failed to schedule Live Update reminders',
        e,
        stackTrace,
      );
      return 0;
    } on MissingPluginException {
      return 0;
    }
  }

  /// Cancels every pending reminder and removes any that are on screen.
  Future<int> cancelAllReminders() async {
    if (!Platform.isAndroid) return 0;
    try {
      return await _channel.invokeMethod<int>('cancelAllReminders') ?? 0;
    } on PlatformException catch (e, stackTrace) {
      log.error(
        '[LiveUpdateService] Failed to cancel Live Update reminders',
        e,
        stackTrace,
      );
      return 0;
    } on MissingPluginException {
      return 0;
    }
  }

  /// Number of reminders still pending.
  Future<int> pendingReminderCount() async {
    if (!Platform.isAndroid) return 0;
    try {
      return await _channel.invokeMethod<int>('pendingReminderCount') ?? 0;
    } on PlatformException catch (e, stackTrace) {
      log.error(
        '[LiveUpdateService] Failed to read the pending reminder count',
        e,
        stackTrace,
      );
      return 0;
    } on MissingPluginException {
      return 0;
    }
  }

  /// Publishes [reminder] immediately, ignoring its trigger time. Used by the settings page so the
  /// user can confirm the system really promotes it.
  Future<LiveUpdatePublishResult> publishTestReminder(
    LiveUpdateReminder reminder,
  ) async {
    if (!Platform.isAndroid) {
      throw StateError('Live Updates are only available on Android');
    }
    final Map<Object?, Object?>? raw = await _channel
        .invokeMethod<Map<Object?, Object?>>(
          'publishTestReminder',
          reminder.toMap(),
        );
    return LiveUpdatePublishResult(
      posted: raw?['posted'] as bool? ?? false,
      promotable: raw?['promotable'] as bool? ?? false,
      availability: _parseAvailability(raw?['availability'] as String?),
      failure: raw?['failure'] as String?,
    );
  }

  /// Opens the per-app "allow promoted notifications" screen.
  ///
  /// Returns false when the platform has no such screen, so the caller can fall back to the app's
  /// ordinary notification settings.
  Future<bool> openLiveUpdateSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openLiveUpdateSettings') ?? false;
    } on PlatformException catch (e, stackTrace) {
      log.error(
        '[LiveUpdateService] Failed to open Live Update settings',
        e,
        stackTrace,
      );
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Registers the callback fired when the user taps a Live Update reminder.
  ///
  /// The native side tracks the event as a flag as well as a nudge, so an event arriving before this
  /// handler exists is not lost — see [consumePendingOpen].
  void onLiveUpdateOpened(Future<void> Function() handler) {
    _openedHandler = handler;
    if (_methodHandlerInstalled || !Platform.isAndroid) return;
    _methodHandlerInstalled = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'onLiveUpdateOpened') return null;
      await _openedHandler?.call();
      return null;
    });
  }

  /// Consumes a pending "opened from a Live Update" event, if any. Safe to call repeatedly; it
  /// returns true at most once per event.
  Future<bool> consumePendingOpen() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('consumePendingOpen') ?? false;
    } on PlatformException catch (e, stackTrace) {
      log.error(
        '[LiveUpdateService] Failed to consume the Live Update open event',
        e,
        stackTrace,
      );
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
