// Copyright 2025 Traintime PDA authors.
// SPDX-License-Identifier: MPL-2.0

// MethodChannel bridge exposing Android Live Update capabilities to Dart.
//
// The Dart side owns the timetable and the translations, so it pushes fully localized reminder
// specs down and turns the structured publish result back into localized text. This bridge only
// reports availability, manages the alarm plan, and relays "the notification was tapped" back up.

package io.github.benderblog.traintime_pda.liveupdate

import android.content.Context
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

class LiveUpdateBridge(context: Context) : MethodChannel.MethodCallHandler {
    private val appContext = context.applicationContext

    private var channel: MethodChannel? = null

    /**
     * Set when a Live Update launched or resumed the app. Kept as a flag as well as a callback so
     * the event survives a cold start, where Dart has no handler registered yet.
     */
    private val openPending = AtomicBoolean(false)

    fun attach(messenger: BinaryMessenger) {
        val created = MethodChannel(messenger, CHANNEL_NAME)
        created.setMethodCallHandler(this)
        channel = created
    }

    /**
     * Records that the user opened the app from a Live Update and nudges a running Dart isolate.
     * Dropping the nudge is safe: [openPending] still holds the event until Dart asks for it.
     */
    fun markOpened() {
        openPending.set(true)
        channel?.invokeMethod(METHOD_ON_OPENED, null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        runCatching {
            when (call.method) {
                METHOD_GET_AVAILABILITY -> result.success(
                    mapOf(
                        KEY_AVAILABILITY to LiveUpdatePublisher.availability(appContext).name,
                        KEY_SDK_INT to Build.VERSION.SDK_INT,
                    )
                )

                METHOD_SCHEDULE -> {
                    val arguments = call.arguments
                    val specs = if (arguments is List<*>) {
                        arguments.mapNotNull { specFrom(it) }
                    } else {
                        emptyList()
                    }
                    result.success(CourseLiveUpdateScheduler.schedule(appContext, specs))
                }

                METHOD_CANCEL_ALL ->
                    result.success(CourseLiveUpdateScheduler.cancelAll(appContext))

                METHOD_PENDING_COUNT ->
                    result.success(CourseLiveUpdateScheduler.pendingCount(appContext))

                METHOD_PUBLISH_TEST -> {
                    val spec = specFrom(call.arguments)
                    if (spec == null) {
                        result.error(ERROR_CODE, "Invalid Live Update payload", null)
                    } else {
                        publishAndReply(spec, result)
                    }
                }

                METHOD_OPEN_SETTINGS ->
                    result.success(
                        LiveUpdatePublisher.openPromotedNotificationSettings(appContext)
                    )

                METHOD_CONSUME_OPEN -> result.success(openPending.getAndSet(false))

                else -> result.notImplemented()
            }
        }.onFailure { error ->
            Log.e(TAG, "Live Update call ${call.method} failed", error)
            result.error(ERROR_CODE, error.message ?: error.toString(), null)
        }
    }

    /**
     * Replies with a structured result rather than a sentence, so Dart can render it in the user's
     * language: whether the notification was posted, whether the system considers it shaped for
     * promotion, and whether the user allows promoted notifications at all.
     */
    private fun publishAndReply(spec: CourseLiveUpdateSpec, result: MethodChannel.Result) {
        // The publisher reports back exactly once, but guard anyway so a late reply can never follow
        // a synchronous one.
        val replied = AtomicBoolean(false)
        LiveUpdatePublisher.publish(appContext, spec) { outcome ->
            if (replied.compareAndSet(false, true)) {
                result.success(
                    mapOf(
                        KEY_POSTED to outcome.posted,
                        KEY_PROMOTABLE to outcome.promotable,
                        KEY_AVAILABILITY to outcome.availability.name,
                        KEY_FAILURE to outcome.failure,
                    )
                )
            }
        }
    }

    private fun specFrom(raw: Any?): CourseLiveUpdateSpec? {
        val map = raw as? Map<*, *> ?: return null
        val id = (map[KEY_ID] as? Number)?.toInt() ?: return null
        val triggerAt = (map[KEY_TRIGGER_AT] as? Number)?.toLong() ?: return null
        val startAt = (map[KEY_START_AT] as? Number)?.toLong() ?: return null
        if (id < 0 || triggerAt <= 0L || startAt <= triggerAt) return null

        return CourseLiveUpdateSpec(
            id = id,
            title = map[KEY_TITLE] as? String ?: return null,
            subtitle = map[KEY_SUBTITLE] as? String ?: "",
            extraText = map[KEY_EXTRA_TEXT] as? String ?: "",
            digitText = map[KEY_DIGIT_TEXT] as? String ?: "",
            triggerAtMillis = triggerAt,
            startAtMillis = startAt,
            accentColor = (map[KEY_ACCENT_COLOR] as? Number)?.toInt()
                ?: CourseLiveUpdateSpec.DEFAULT_ACCENT_COLOR,
            weekIndex = (map[KEY_WEEK_INDEX] as? Number)?.toInt() ?: 0,
        )
    }

    companion object {
        private const val TAG = "XDYouLiveUpdate"

        const val CHANNEL_NAME = "io.github.benderblog.traintime_pda/live_update"
        const val METHOD_ON_OPENED = "onLiveUpdateOpened"

        private const val ERROR_CODE = "live_update_error"

        private const val KEY_AVAILABILITY = "availability"
        private const val KEY_SDK_INT = "sdkInt"
        private const val KEY_POSTED = "posted"
        private const val KEY_PROMOTABLE = "promotable"
        private const val KEY_FAILURE = "failure"

        private const val METHOD_GET_AVAILABILITY = "getAvailability"
        private const val METHOD_SCHEDULE = "scheduleReminders"
        private const val METHOD_CANCEL_ALL = "cancelAllReminders"
        private const val METHOD_PENDING_COUNT = "pendingReminderCount"
        private const val METHOD_PUBLISH_TEST = "publishTestReminder"
        private const val METHOD_OPEN_SETTINGS = "openLiveUpdateSettings"
        private const val METHOD_CONSUME_OPEN = "consumePendingOpen"

        private const val KEY_ID = "id"
        private const val KEY_TITLE = "title"
        private const val KEY_SUBTITLE = "subtitle"
        private const val KEY_EXTRA_TEXT = "extraText"
        private const val KEY_DIGIT_TEXT = "digitText"
        private const val KEY_TRIGGER_AT = "triggerAtMillis"
        private const val KEY_START_AT = "startAtMillis"
        private const val KEY_ACCENT_COLOR = "accentColor"
        private const val KEY_WEEK_INDEX = "weekIndex"
    }
}
