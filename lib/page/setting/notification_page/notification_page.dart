// Copyright 2025 Hazuki Keatsu and contributors
// Copyright 2025 Traintime PDA authors.
// SPDX-License-Identifier: MPL-2.0

// Course reminder notification settings page

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_i18n/flutter_i18n.dart';
import 'package:styled_widget/styled_widget.dart';
import 'package:watermeter/page/public_widget/re_x_card.dart';
import 'package:watermeter/page/public_widget/safe_scroll_padding.dart';
import 'package:watermeter/page/public_widget/toast.dart';
import 'package:watermeter/repository/notification/course_reminder_service.dart';
import 'package:watermeter/repository/notification/live_update_service.dart';

class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

const kDefaultMinutesBeforeOptions = [5, 10, 15, 20, 30];
const kDefaultDaysToScheduleOptions = [3, 7, 14, 30];

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  final _courseReminder = CourseReminderService();
  final _liveUpdate = LiveUpdateService();

  bool _isEnabled = false;
  bool _hasNotificationPermission = false;
  bool _hasExactAlarmPermission = false;
  int _minutesBefore = 5;
  int _daysToSchedule = 7;
  bool _isLoading = true;
  int _pendingCount = 0;
  bool _enableExperimentNotifications = false;

  /// Live Update state. `null` status means "not probed yet".
  bool _liveUpdateEnabled = false;
  LiveUpdateStatus? _liveUpdateStatus;
  int _liveUpdatePending = 0;
  bool _liveUpdateBusy = false;

  /// Fixed notification id for the settings-page test reminder, so repeated taps reuse one.
  static const int _liveUpdateTestId = 990001;

  @override
  void initState() {
    super.initState();
    // Load settings from service
    _isEnabled = _courseReminder.isEnabled;
    _liveUpdateEnabled = _courseReminder.isLiveUpdateEnabled;
    _enableExperimentNotifications =
        _courseReminder.enableExperimentNotifications;
    _minutesBefore = _courseReminder.minutesBefore;
    _daysToSchedule = _courseReminder.daysToSchedule;

    if (kDefaultMinutesBeforeOptions.contains(_minutesBefore) == false) {
      _minutesBefore = 5;
    }

    if (kDefaultDaysToScheduleOptions.contains(_daysToSchedule) == false) {
      _daysToSchedule = 7;
    }

    _loadSettings();
  }

  Future<void> _loadSettings() async {
    setState(() {
      _isLoading = true;
    });

    try {
      // Initiation
      await _courseReminder.initialize();

      // Check permission
      _hasNotificationPermission = await _courseReminder
          .checkNotificationPermission();
      _hasExactAlarmPermission = await _courseReminder
          .checkExactAlarmPermission();

      if (!_hasExactAlarmPermission || !_hasNotificationPermission) {
        _courseReminder.setEnabled(false);
        setState(() {
          _isEnabled = false;
        });
      }

      // Get the number of notifications to be sent
      _pendingCount = await _courseReminder
          .getPendingCourseNotificationsCount();

      // Super Island support and its native alarm plan. The status is re-probed rather than cached
      // because the user may have just changed the focus notification permission in system
      // settings; every call degrades to a safe default without the native bridge.
      _liveUpdateStatus = await _liveUpdate.status(refresh: true);
      _liveUpdatePending = await _liveUpdate.pendingReminderCount();
    } catch (e) {
      if (mounted) {
        showToast(
          context: context,
          msg: FlutterI18n.translate(
            context,
            'setting.notification_page.load_failed',
            translationParams: {'error': e.toString()},
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _requestPermission() async {
    final notificationPermissionGranted = await _courseReminder
        .requestNotificationPermission();
    final exactAlarmGranted = await _courseReminder
        .requestExactAlarmPermission();
    if (mounted) {
      setState(() {
        _hasNotificationPermission = notificationPermissionGranted;
        _hasExactAlarmPermission = exactAlarmGranted;
      });

      if (notificationPermissionGranted && exactAlarmGranted) {
        showToast(
          context: context,
          msg: FlutterI18n.translate(
            context,
            'setting.notification_page.permission_granted_msg',
          ),
        );
      } else {
        showToast(
          context: context,
          msg: FlutterI18n.translate(
            context,
            'setting.notification_page.permission_denied_msg',
          ),
        );
      }
    }
  }

  void _showNotificationSettingsGuide() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          FlutterI18n.translate(
            context,
            'setting.notification_page.settings_guide_title',
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              FlutterI18n.translate(
                context,
                'setting.notification_page.settings_guide_content_1',
              ),
            ),
            Divider(),
            Text(
              FlutterI18n.translate(
                context,
                'setting.notification_page.settings_guide_content_2',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(
              FlutterI18n.translate(
                context,
                'setting.notification_page.got_it',
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _courseReminder.openNotificationSettings();
            },
            child: Text(
              FlutterI18n.translate(
                context,
                'setting.notification_page.open_settings',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleNotification(bool value) async {
    if (value) {
      if (!_hasNotificationPermission) {
        await _requestPermission();
      }

      _showNotificationSettingsGuide();

      // Arrange notification
      setState(() {
        _isLoading = true;
      });

      try {
        if (!_courseReminder.hasSchedulableReminderSourceData) {
          if (mounted) {
            showToast(
              context: context,
              msg: FlutterI18n.translate(
                context,
                'setting.notification_page.no_classtable_data',
              ),
            );
          }
          return;
        }

        // Use service method to enable notifications
        await _courseReminder.setEnabled(true);

        _pendingCount = await _courseReminder
            .getPendingCourseNotificationsCount();

        if (mounted) {
          setState(() {
            _isEnabled = true;
          });
          showToast(
            context: context,
            msg: FlutterI18n.translate(
              context,
              'setting.notification_page.schedule_success',
              translationParams: {'count': _pendingCount.toString()},
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          showToast(
            context: context,
            msg: FlutterI18n.translate(
              context,
              'setting.notification_page.schedule_failed',
              translationParams: {'error': e.toString()},
            ),
          );
        }
      } finally {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      }
    } else {
      // Use service method to disable notifications
      await _courseReminder.setEnabled(false);

      if (mounted) {
        setState(() {
          _isEnabled = false;
          _pendingCount = 0;
        });
        showToast(
          context: context,
          msg: FlutterI18n.translate(
            context,
            'setting.notification_page.cancel_all_success',
          ),
        );
      }
    }
  }

  /// Helper method to update pending count and show success toast
  Future<void> _updatePendingCountAndNotify() async {
    _pendingCount = await _courseReminder.getPendingCourseNotificationsCount();
    if (mounted) {
      setState(() {});
      showToast(
        context: context,
        msg: FlutterI18n.translate(
          context,
          'setting.notification_page.reschedule_success',
          translationParams: {'count': _pendingCount.toString()},
        ),
      );
    }
  }

  Future<void> _changeMinutesBefore(int value) async {
    setState(() {
      _minutesBefore = value;
      _isLoading = true;
    });

    try {
      // Use service setter - it will automatically update notifications if enabled
      await _courseReminder.setMinutesBefore(value);

      // Update pending count and notify if enabled
      if (_isEnabled) {
        await _updatePendingCountAndNotify();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _changeDaysToSchedule(int value) async {
    setState(() {
      _daysToSchedule = value;
      _isLoading = true;
    });

    try {
      // Use service setter - it will automatically update notifications if enabled
      await _courseReminder.setDaysToSchedule(value);

      // Update pending count and notify if enabled
      if (_isEnabled) {
        await _updatePendingCountAndNotify();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _rescheduleNotifications() async {
    setState(() {
      _isLoading = true;
    });

    try {
      await _courseReminder.cancelAllCourseNotifications();
      await _courseReminder.scheduleNotificationsFromCourseData(
        daysToSchedule: _daysToSchedule,
        minutesBefore: _minutesBefore,
      );

      _pendingCount = await _courseReminder
          .getPendingCourseNotificationsCount();
      _liveUpdatePending = await _liveUpdate.pendingReminderCount();

      if (mounted) {
        showToast(
          context: context,
          msg: FlutterI18n.translate(
            context,
            'setting.notification_page.reschedule_success',
            translationParams: {'count': _pendingCount.toString()},
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showToast(
          context: context,
          msg: FlutterI18n.translate(
            context,
            'setting.notification_page.reschedule_failed',
            translationParams: {'error': e.toString()},
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _deleteAllSchedules() async {
    await _courseReminder.cancelAllCourseNotifications();
    // Island reminders live in a native alarm plan, so cancelAllCourseNotifications does not
    // reach them.
    await _liveUpdate.cancelAllReminders();

    if (mounted) {
      setState(() {
        _pendingCount = 0;
        _liveUpdatePending = 0;
      });
      showToast(
        context: context,
        msg: FlutterI18n.translate(
          context,
          'setting.notification_page.delete_all_success',
        ),
      );
    }
  }

  Widget _buildListSubtitle(String text) => Text(
    text,
    style: const TextStyle(fontWeight: FontWeight.bold),
  ).padding(bottom: 8).center();

  /// Human-readable availability for the Live Update card.
  String _liveUpdateStatusText(BuildContext context) {
    final status = _liveUpdateStatus;
    final String key;
    if (status == null) {
      key = 'live_update_status_loading';
    } else {
      key = switch (status.availability) {
        LiveUpdateAvailability.ready => 'live_update_status_ready',
        LiveUpdateAvailability.platformUnsupported =>
          'live_update_status_platform_unsupported',
        LiveUpdateAvailability.userDisabled =>
          'live_update_status_user_disabled',
      };
    }
    return FlutterI18n.translate(context, 'setting.notification_page.$key');
  }

  Future<void> _refreshLiveUpdateState() async {
    // Re-probe: the user may have changed the Live Update permission in system settings.
    final status = await _liveUpdate.status(refresh: true);
    final reminderCount = await _liveUpdate.pendingReminderCount();
    final pending = await _courseReminder.getPendingCourseNotificationsCount();
    if (!mounted) return;
    setState(() {
      _liveUpdateStatus = status;
      _liveUpdatePending = reminderCount;
      _pendingCount = pending;
    });
  }

  Future<void> _toggleLiveUpdate(bool value) async {
    setState(() {
      _liveUpdateEnabled = value;
      _liveUpdateBusy = true;
    });

    try {
      // Rebuilds the whole plan: courses either move to Live Updates or back to ordinary
      // notifications, so nothing stays scheduled on the channel that is no longer in use.
      await _courseReminder.setLiveUpdateEnabled(value);
      await _refreshLiveUpdateState();
    } catch (e) {
      if (mounted) {
        showToast(
          context: context,
          msg: FlutterI18n.translate(
            context,
            'setting.notification_page.live_update_load_failed',
            translationParams: {'error': e.toString()},
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _liveUpdateBusy = false;
        });
      }
    }
  }

  Future<void> _sendLiveUpdateTest() async {
    setState(() {
      _liveUpdateBusy = true;
    });

    try {
      // Text comes from the UI translations rather than the non-UI table, so the card matches the
      // language the settings page is currently showing.
      final result = await _liveUpdate.publishTestReminder(
        LiveUpdateReminder(
          id: _liveUpdateTestId,
          title: FlutterI18n.translate(
            context,
            'setting.notification_page.live_update_test_card_title',
          ),
          subtitle: FlutterI18n.translate(
            context,
            'setting.notification_page.live_update_test_card_subtitle',
          ),
          extraText: '',
          digitText: '',
          triggerAt: DateTime.now(),
          // A real reminder always has a class start after its trigger; the publisher rejects
          // anything else, so the test mirrors that shape.
          startAt: DateTime.now().add(const Duration(minutes: 10)),
          accentColor: LiveUpdateService.accentColorFor('live_update_test'),
          weekIndex: 0,
        ),
      );

      if (!mounted) return;
      showToast(context: context, msg: _describeLiveUpdateResult(result));
    } catch (e) {
      if (mounted) {
        showToast(
          context: context,
          msg: FlutterI18n.translate(
            context,
            'setting.notification_page.live_update_test_failed',
            translationParams: {'error': e.toString()},
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _liveUpdateBusy = false;
        });
      }
    }
  }

  /// Turns the structured native result into a sentence, so the wording stays translatable.
  ///
  /// Reporting *why* matters here: the system silently declines to promote a notification that does
  /// not meet its criteria, which is otherwise indistinguishable from the feature being broken.
  String _describeLiveUpdateResult(LiveUpdatePublishResult result) {
    final String key;
    if (!result.posted) {
      key = 'live_update_test_not_posted';
    } else if (result.availability != LiveUpdateAvailability.ready) {
      key = 'live_update_test_not_allowed';
    } else if (!result.promotable) {
      key = 'live_update_test_not_promotable';
    } else {
      key = 'live_update_test_sent';
    }
    return FlutterI18n.translate(
      context,
      'setting.notification_page.$key',
      translationParams: {'error': result.failure ?? ''},
    );
  }

  /// Opens the system screen that allows promoted notifications, falling back to the app's general
  /// notification settings when the platform exposes no such screen.
  Future<void> _openLiveUpdateSettings() async {
    if (await _liveUpdate.openLiveUpdateSettings()) return;
    await _courseReminder.openNotificationSettings();
  }

  Future<void> _clearLiveUpdates() async {
    await _liveUpdate.cancelAllReminders();
    if (mounted) {
      setState(() {
        _liveUpdatePending = 0;
        _pendingCount = 0;
      });
      showToast(
        context: context,
        msg: FlutterI18n.translate(
          context,
          'setting.notification_page.live_update_cleared',
        ),
      );
    }
  }

  /// The Live Update card. Android-only: the API needs Android 16.
  Widget _buildLiveUpdateCard(BuildContext context) {
    final LiveUpdateStatus? status = _liveUpdateStatus;
    final bool ready = status?.canPost ?? false;
    final bool needsPermission =
        status?.availability == LiveUpdateAvailability.userDisabled;

    return ReXCard(
      title: _buildListSubtitle(
        FlutterI18n.translate(
          context,
          'setting.notification_page.live_update_section',
        ),
      ),
      remaining: const [],
      bottomRow: Column(
        children: [
          ListTile(
            title: Text(
              FlutterI18n.translate(
                context,
                'setting.notification_page.live_update_enable',
              ),
            ),
            subtitle: Text(
              FlutterI18n.translate(
                context,
                'setting.notification_page.live_update_enable_hint',
              ),
            ),
            trailing: Switch(
              value: _liveUpdateEnabled,
              onChanged: _liveUpdateBusy || status == null
                  ? null
                  : _toggleLiveUpdate,
            ),
          ),
          const Divider(),
          ListTile(
            title: Text(
              FlutterI18n.translate(
                context,
                'setting.notification_page.live_update_status',
              ),
            ),
            subtitle: Text(_liveUpdateStatusText(context)),
            trailing: ready
                ? Icon(
                    Icons.check_circle,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : const Icon(Icons.info_outline),
          ),
          const Divider(),
          ListTile(
            title: Text(
              FlutterI18n.translate(
                context,
                'setting.notification_page.live_update_sdk',
                translationParams: {
                  'sdk': (status?.sdkInt ?? 0).toString(),
                  'required': LiveUpdateStatus.liveUpdateApi.toString(),
                },
              ),
            ),
          ),
          // The per-app "allow promoted notifications" switch is a separate gate from the OS
          // version, and it being off is the likeliest reason a capable phone shows a plain
          // notification. Surface it with a way to fix it rather than letting the feature look
          // broken.
          if (needsPermission) ...[
            const Divider(),
            ListTile(
              title: Text(
                FlutterI18n.translate(
                  context,
                  'setting.notification_page.live_update_promoted_permission',
                ),
              ),
              subtitle: Text(
                FlutterI18n.translate(
                  context,
                  'setting.notification_page.live_update_promoted_permission_hint',
                ),
              ),
              trailing: TextButton(
                onPressed: _liveUpdateBusy ? null : _openLiveUpdateSettings,
                child: Text(
                  FlutterI18n.translate(
                    context,
                    'setting.notification_page.live_update_promoted_permission_open',
                  ),
                ),
              ),
            ),
          ],
          if (_liveUpdateEnabled && ready) ...[
            const Divider(),
            ListTile(
              title: Text(
                FlutterI18n.translate(
                  context,
                  'setting.notification_page.live_update_pending',
                  translationParams: {
                    'count': _liveUpdatePending.toString(),
                  },
                ),
              ),
            ),
          ],
          const Divider(),
          ListTile(
            title: Text(
              FlutterI18n.translate(
                context,
                'setting.notification_page.live_update_test',
              ),
            ),
            subtitle: Text(
              FlutterI18n.translate(
                context,
                'setting.notification_page.live_update_test_hint',
              ),
            ),
            trailing: const Icon(Icons.send),
            onTap: _liveUpdateBusy ? null : _sendLiveUpdateTest,
          ),
          const Divider(),
          ListTile(
            title: Text(
              FlutterI18n.translate(
                context,
                'setting.notification_page.live_update_clear',
              ),
            ),
            trailing: Icon(
              Icons.delete_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            onTap: _liveUpdateBusy ? null : _clearLiveUpdates,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              FlutterI18n.translate(
                context,
                'setting.notification_page.live_update_takeover_hint',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          FlutterI18n.translate(context, 'setting.notification_page.title'),
        ),
        actions: [
          if (_isLoading)
            Container(
              margin: EdgeInsets.only(right: 16),
              width: 24,
              height: 24,
              child: Center(
                child: CircularProgressIndicator(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16).withSafeBottom(context),
        children: [
          // Function switch
          ReXCard(
            title: _buildListSubtitle(
              FlutterI18n.translate(
                context,
                'setting.notification_page.function_section',
              ),
            ),
            remaining: const [],
            bottomRow: Column(
              children: [
                ListTile(
                  title: Text(
                    FlutterI18n.translate(
                      context,
                      'setting.notification_page.enable_notification',
                    ),
                  ),
                  subtitle: Text(
                    _isEnabled
                        ? FlutterI18n.translate(
                            context,
                            'setting.notification_page.notification_scheduled',
                            translationParams: {
                              'count': _pendingCount.toString(),
                            },
                          )
                        : FlutterI18n.translate(
                            context,
                            'setting.notification_page.notification_disabled_hint',
                          ),
                  ),
                  trailing: Switch(
                    value: _isEnabled,
                    onChanged: _toggleNotification,
                  ),
                ),
                ListTile(
                  title: Text(
                    FlutterI18n.translate(
                      context,
                      'setting.notification_page.view_the_instructions',
                    ),
                  ),
                  subtitle: Text(
                    FlutterI18n.translate(
                      context,
                      'setting.notification_page.view_the_instructions_hint',
                    ),
                  ),
                  trailing: const Icon(Icons.navigate_next),
                  onTap: () => _showNotificationSettingsGuide(),
                ),
                if (_isEnabled)
                  ListTile(
                    title: Text(
                      FlutterI18n.translate(
                        context,
                        'setting.notification_page.update_schedule',
                      ),
                    ),
                    subtitle: Text(
                      FlutterI18n.translate(
                        context,
                        'setting.notification_page.update_schedule_hint',
                      ),
                    ),
                    trailing: const Icon(Icons.refresh),
                    onTap: _rescheduleNotifications,
                  ),
                if (_isEnabled && _pendingCount > 0)
                  ListTile(
                    title: Text(
                      FlutterI18n.translate(
                        context,
                        'setting.notification_page.delete_all_schedule',
                      ),
                    ),
                    subtitle: Text(
                      FlutterI18n.translate(
                        context,
                        'setting.notification_page.delete_all_schedule_hint',
                      ),
                    ),
                    trailing: Icon(
                      Icons.delete,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    onTap: _deleteAllSchedules,
                  ),
              ],
            ),
          ),

          // Reminder setting
          ReXCard(
            title: _buildListSubtitle(
              FlutterI18n.translate(
                context,
                'setting.notification_page.reminder_section',
              ),
            ),
            remaining: const [],
            bottomRow: Column(
              children: [
                ListTile(
                  title: Text(
                    FlutterI18n.translate(
                      context,
                      'setting.notification_page.experiment_reminder',
                    ),
                  ),
                  subtitle: Text(
                    FlutterI18n.translate(
                      context,
                      'setting.notification_page.experiment_reminder_hint',
                    ),
                  ),
                  trailing: Switch(
                    value: _enableExperimentNotifications,
                    onChanged: (value) async {
                      setState(() {
                        _enableExperimentNotifications = value;
                        _isLoading = true;
                      });

                      try {
                        // Use service setter - it will automatically update notifications if enabled
                        await _courseReminder.setEnableExperimentNotifications(
                          value,
                        );

                        // Update pending count and notify if enabled
                        if (_isEnabled) {
                          await _updatePendingCountAndNotify();
                        }
                      } finally {
                        if (mounted) {
                          setState(() {
                            _isLoading = false;
                          });
                        }
                      }
                    },
                  ),
                ),
                const Divider(),
                ListTile(
                  title: Text(
                    FlutterI18n.translate(
                      context,
                      'setting.notification_page.minutes_before',
                    ),
                  ),
                  subtitle: Text(
                    FlutterI18n.translate(
                      context,
                      'setting.notification_page.minutes_before_hint',
                    ),
                  ),
                  trailing: DropdownButton<int>(
                    value: _minutesBefore,
                    items: kDefaultMinutesBeforeOptions
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(
                              '$value ${FlutterI18n.translate(context, "setting.notification_page.minutes_unit")}',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        _changeMinutesBefore(value);
                      }
                    },
                  ),
                ),
                const Divider(),
                ListTile(
                  title: Text(
                    FlutterI18n.translate(
                      context,
                      'setting.notification_page.days_to_schedule',
                    ),
                  ),
                  subtitle: Text(
                    FlutterI18n.translate(
                      context,
                      'setting.notification_page.days_to_schedule_hint',
                    ),
                  ),
                  trailing: DropdownButton<int>(
                    value: _daysToSchedule,
                    items: kDefaultDaysToScheduleOptions
                        .map(
                          (value) => DropdownMenuItem(
                            value: value,
                            child: Text(
                              '$value ${FlutterI18n.translate(context, "setting.notification_page.days_unit")}',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        _changeDaysToSchedule(value);
                      }
                    },
                  ),
                ),
              ],
            ),
          ),

          // Android 16 Live Updates
          if (Platform.isAndroid) _buildLiveUpdateCard(context),

          // Permission state
          ReXCard(
            title: _buildListSubtitle(
              FlutterI18n.translate(
                context,
                'setting.notification_page.permission_section',
              ),
            ),
            remaining: const [],
            bottomRow: Column(
              children: [
                ListTile(
                  title: Text(
                    FlutterI18n.translate(
                      context,
                      'setting.notification_page.notification_permission',
                    ),
                  ),
                  subtitle: Text(
                    _hasNotificationPermission
                        ? FlutterI18n.translate(
                            context,
                            'setting.notification_page.permission_granted',
                          )
                        : FlutterI18n.translate(
                            context,
                            'setting.notification_page.permission_denied',
                          ),
                  ),
                  trailing: _hasNotificationPermission
                      ? Icon(
                          Icons.check_circle,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : TextButton(
                          onPressed: _requestPermission,
                          child: Text(
                            FlutterI18n.translate(
                              context,
                              'setting.notification_page.request_permission',
                            ),
                          ),
                        ),
                ),
                const Divider(),
                ListTile(
                  title: Text(
                    FlutterI18n.translate(
                      context,
                      'setting.notification_page.exact_alarm_permission',
                    ),
                  ),
                  subtitle: Text(
                    _hasExactAlarmPermission
                        ? FlutterI18n.translate(
                            context,
                            'setting.notification_page.permission_granted',
                          )
                        : FlutterI18n.translate(
                            context,
                            'setting.notification_page.permission_denied',
                          ),
                  ),
                  trailing: _hasExactAlarmPermission
                      ? Icon(
                          Icons.check_circle,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : TextButton(
                          onPressed: _requestPermission,
                          child: Text(
                            FlutterI18n.translate(
                              context,
                              'setting.notification_page.request_permission',
                            ),
                          ),
                        ),
                ),
                const Divider(),
                ListTile(
                  title: Text(
                    FlutterI18n.translate(
                      context,
                      'setting.notification_page.system_settings',
                    ),
                  ),
                  subtitle: Text(
                    FlutterI18n.translate(
                      context,
                      'setting.notification_page.system_settings_hint',
                    ),
                  ),
                  trailing: const Icon(Icons.settings),
                  onTap: () => _courseReminder.openNotificationSettings(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
