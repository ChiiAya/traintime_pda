// Copyright 2025 Traintime PDA authors.
// SPDX-License-Identifier: MPL-2.0

// One scheduled pre-class Live Update.
//
// Computed on the Dart side (which owns the timetable and the translations) and handed to the
// native alarm scheduler. All user-visible strings arrive already localized; this layer only decides
// how the data is laid out in the notification.

package io.github.benderblog.traintime_pda.liveupdate

import org.json.JSONObject

/**
 * A pre-class reminder that should be posted as an Android 16 Live Update.
 *
 * [id] doubles as the notification id, the `AlarmManager` request code and the `PendingIntent`
 * request code. A distinct notification id per reminder is deliberate: Android's guidance is to
 * never repost a Live Update the user dismissed, and separate ids make each reminder independent.
 */
data class CourseLiveUpdateSpec(
    val id: Int,
    /** Course name. Becomes `contentTitle`, which promotion requires. */
    val title: String,
    /** Start time plus room, e.g. `08:30 · A-101`. */
    val subtitle: String,
    /** Teacher, shown as the notification subtext. May be empty. */
    val extraText: String,
    /** Short start time such as `08:30`. Kept for parity with the timetable's own labelling. */
    val digitText: String,
    /** When the reminder fires — the start of the progress journey. */
    val triggerAtMillis: Long,
    /** When the class starts — the end of the journey, and the countdown target. */
    val startAtMillis: Long,
    /** ARGB accent used for the progress track and the milestone. */
    val accentColor: Int,
    val weekIndex: Int,
) {
    /**
     * When the progress bar should be advanced once, or null when the wait is too short to be worth
     * a second wake-up. The system renders the countdown chip itself, but the progress bar is a
     * snapshot, so one mid-window refresh is what makes it visibly a live update.
     */
    val refreshAtMillis: Long?
        get() {
            val window = startAtMillis - triggerAtMillis
            if (window < MIN_REFRESH_WINDOW_MILLIS) return null
            return triggerAtMillis + window / 2
        }

    fun toJson(): JSONObject = JSONObject()
        .put(KEY_ID, id)
        .put(KEY_TITLE, title)
        .put(KEY_SUBTITLE, subtitle)
        .put(KEY_EXTRA_TEXT, extraText)
        .put(KEY_DIGIT_TEXT, digitText)
        .put(KEY_TRIGGER_AT, triggerAtMillis)
        .put(KEY_START_AT, startAtMillis)
        .put(KEY_ACCENT_COLOR, accentColor)
        .put(KEY_WEEK_INDEX, weekIndex)

    companion object {
        /** Below this the reminder window is too short for an intermediate refresh to mean much. */
        private const val MIN_REFRESH_WINDOW_MILLIS = 8 * 60 * 1_000L

        private const val KEY_ID = "id"
        private const val KEY_TITLE = "title"
        private const val KEY_SUBTITLE = "subtitle"
        private const val KEY_EXTRA_TEXT = "extraText"
        private const val KEY_DIGIT_TEXT = "digitText"
        private const val KEY_TRIGGER_AT = "triggerAtMillis"
        private const val KEY_START_AT = "startAtMillis"
        private const val KEY_ACCENT_COLOR = "accentColor"
        private const val KEY_WEEK_INDEX = "weekIndex"

        /** Upstream-free default accent, used when the caller supplies nothing. */
        val DEFAULT_ACCENT_COLOR: Int = 0xFF1976D2.toInt()

        fun fromJson(json: JSONObject): CourseLiveUpdateSpec? {
            val id = json.optInt(KEY_ID, -1)
            val triggerAt = json.optLong(KEY_TRIGGER_AT, -1L)
            val startAt = json.optLong(KEY_START_AT, -1L)
            if (id < 0 || triggerAt <= 0L || startAt <= triggerAt) return null
            return CourseLiveUpdateSpec(
                id = id,
                title = json.optString(KEY_TITLE),
                subtitle = json.optString(KEY_SUBTITLE),
                extraText = json.optString(KEY_EXTRA_TEXT),
                digitText = json.optString(KEY_DIGIT_TEXT),
                triggerAtMillis = triggerAt,
                startAtMillis = startAt,
                accentColor = json.optInt(KEY_ACCENT_COLOR, DEFAULT_ACCENT_COLOR),
                weekIndex = json.optInt(KEY_WEEK_INDEX, 0),
            )
        }
    }
}
