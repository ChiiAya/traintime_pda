// Copyright 2025 Traintime PDA authors.
// SPDX-License-Identifier: MPL-2.0

// Posts pre-class reminders as Android 16 Live Updates (progress-centric promoted notifications).
//
// This replaces the earlier Xiaomi Super Island route. Everything here is stock Android: Xiaomi's
// Super Island needs per-app authorization from Xiaomi tied to the APK signing certificate, while
// Live Updates are gated only by the OS version and a user-controlled per-app setting.
//
// Eligibility, per https://developer.android.com/develop/ui/views/notifications/live-update:
//   * manifest permission android.permission.POST_PROMOTED_NOTIFICATIONS
//   * request promotion via EXTRA_REQUEST_PROMOTED_ONGOING. The platform
//     Notification.Builder#setRequestPromotedOngoing only became public API in API 37 and is a
//     *blocked hidden API* on API 36 — calling it there throws NoSuchMethodError — so the extra is
//     set directly. See EXTRA_REQUEST_PROMOTED_ONGOING below.
//   * FLAG_ONGOING_EVENT (setOngoing(true))
//   * a content title
//   * style is Standard/BigText/Call/Progress/Metric — ProgressStyle is used here
//   * no customContentView (no RemoteViews), not a group summary, not colorized
//   * the notification channel must not be IMPORTANCE_MIN

package io.github.benderblog.traintime_pda.liveupdate

import android.annotation.SuppressLint
import android.annotation.TargetApi
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.media.AudioAttributes
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.github.benderblog.traintime_pda.R

object LiveUpdatePublisher {
    private const val TAG = "XDYouLiveUpdate"

    /**
     * Shared with `flutter_local_notifications`' course reminder channel so the user keeps a single
     * channel with the sound and importance they already configured. See [ensureChannel] for why the
     * settings here are mirrored exactly.
     */
    const val CHANNEL_ID = "course_reminder"

    /** Android 16 introduced `ProgressStyle` and promoted ongoing notifications. */
    const val LIVE_UPDATE_API = 36

    /**
     * Requests promotion to a Live Update.
     *
     * This key became public API only in API 37, as `Notification.EXTRA_REQUEST_PROMOTED_ONGOING`;
     * androidx exposes the same string as `NotificationCompat.EXTRA_REQUEST_PROMOTED_ONGOING`. Both
     * declare exactly this value, so it is inlined here to keep working on API 36, where the
     * corresponding `Notification.Builder#setRequestPromotedOngoing` is a blocked hidden API.
     */
    private const val EXTRA_REQUEST_PROMOTED_ONGOING = "android.requestPromotedOngoing"

    /** Progress and point positions share one normalised scale. */
    private const val PROGRESS_SCALE = 100

    const val ACTION_OPEN_LIVE_UPDATE =
        "io.github.benderblog.traintime_pda.liveupdate.OPEN"
    const val EXTRA_SPEC_ID = "io.github.benderblog.traintime_pda.liveupdate.SPEC_ID"

    /** Whether this device and user can actually show a Live Update. */
    enum class Availability {
        /** API level is new enough and the user has allowed promoted notifications. */
        READY,

        /** Below Android 16: `ProgressStyle` does not exist. */
        PLATFORM_UNSUPPORTED,

        /** Android 16, but the user turned Live Updates off for XDYou in system settings. */
        USER_DISABLED,
    }

    data class PublishResult(
        val posted: Boolean,
        /** Whether the system considers the notification shaped for promotion. */
        val promotable: Boolean,
        val availability: Availability,
        val failure: String?,
    )

    fun availability(context: Context): Availability {
        if (Build.VERSION.SDK_INT < LIVE_UPDATE_API) return Availability.PLATFORM_UNSUPPORTED
        val manager = context.applicationContext
            .getSystemService(NotificationManager::class.java)
            ?: return Availability.PLATFORM_UNSUPPORTED
        return if (canPostPromoted(manager)) {
            Availability.READY
        } else {
            Availability.USER_DISABLED
        }
    }

    /**
     * Posts [spec] and reports what actually happened, so the settings page can say whether the
     * system accepted the notification as a Live Update instead of leaving the user guessing.
     */
    fun publish(
        context: Context,
        spec: CourseLiveUpdateSpec,
        onFinished: (PublishResult) -> Unit,
    ) {
        val appContext = context.applicationContext
        val availability = availability(appContext)
        runCatching {
            ensureChannel(appContext)
            val manager = appContext
                .getSystemService(NotificationManager::class.java)
                ?: error("NotificationManager is unavailable")

            if (Build.VERSION.SDK_INT >= LIVE_UPDATE_API) {
                postOnApi36(appContext, manager, spec, availability, onFinished)
            } else {
                // Posting a plain notification here would be misleading: it could never be promoted.
                onFinished(
                    PublishResult(
                        posted = false,
                        promotable = false,
                        availability = availability,
                        failure = null,
                    )
                )
            }
        }.onFailure { error ->
            Log.e(TAG, "Unable to post the course Live Update", error)
            onFinished(
                PublishResult(
                    posted = false,
                    promotable = false,
                    availability = availability,
                    failure = error.message ?: error.toString(),
                )
            )
        }
    }

    /** Removes a posted reminder. Safe to call for a notification that is already gone. */
    fun cancel(context: Context, specId: Int) {
        runCatching {
            context.applicationContext
                .getSystemService(NotificationManager::class.java)
                ?.cancel(specId)
        }.onFailure { error ->
            Log.w(TAG, "Unable to cancel Live Update $specId", error)
        }
    }

    /**
     * Sends the user to this app's notification settings, which is where the per-app Live Update
     * switch ("promoted notifications") lives.
     *
     * The Live Update guide refers to `Settings.ACTION_MANAGE_APP_PROMOTED_NOTIFICATIONS`, but that
     * constant is not present in the public SDK at compileSdk 37 — it fails to compile. The app
     * notification settings screen is a stable API since Android 8 and reaches the same toggle, so
     * it is used instead.
     *
     * Returns false when nothing can handle the intent, so the caller can fall back to the app's
     * general settings.
     */
    fun openPromotedNotificationSettings(context: Context): Boolean {
        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        val resolvable = runCatching {
            intent.resolveActivity(context.packageManager) != null
        }.getOrDefault(false)
        if (!resolvable) return false

        return runCatching {
            context.startActivity(intent)
            true
        }.getOrElse { error ->
            Log.w(TAG, "Unable to open notification settings", error)
            false
        }
    }

    @TargetApi(36)
    private fun postOnApi36(
        context: Context,
        manager: NotificationManager,
        spec: CourseLiveUpdateSpec,
        availability: Availability,
        onFinished: (PublishResult) -> Unit,
    ) {
        val notification = buildNotification(context, spec, System.currentTimeMillis())
        val promotable = notification.hasPromotableCharacteristics()
        manager.notify(spec.id, notification)
        Log.i(
            TAG,
            "Posted course Live Update ${spec.id} " +
                "(promotable=$promotable, availability=$availability)",
        )
        onFinished(
            PublishResult(
                posted = true,
                promotable = promotable,
                availability = availability,
                failure = null,
            )
        )
    }

    @TargetApi(36)
    private fun buildNotification(
        context: Context,
        spec: CourseLiveUpdateSpec,
        now: Long,
    ): Notification {
        val window = (spec.startAtMillis - spec.triggerAtMillis).coerceAtLeast(1L)
        val elapsed = (now - spec.triggerAtMillis).coerceIn(0L, window)
        val progress = ((elapsed * PROGRESS_SCALE) / window).toInt().coerceIn(0, PROGRESS_SCALE)

        val tracker = Icon.createWithResource(context, R.drawable.ic_course_reminder)
        val style = Notification.ProgressStyle()
            .setStyledByProgress(false)
            .setProgress(progress)
            .setProgressTrackerIcon(tracker)
            .setProgressSegments(
                listOf(
                    Notification.ProgressStyle
                        .Segment(PROGRESS_SCALE)
                        .setColor(spec.accentColor)
                )
            )
            .setProgressPoints(
                listOf(
                    Notification.ProgressStyle
                        .Point(PROGRESS_SCALE)
                        .setColor(spec.accentColor)
                )
            )

        val remaining = spec.startAtMillis - now
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_course_reminder)
            .setContentTitle(spec.title)
            .setContentText(spec.subtitle)
            .setSubText(spec.extraText.ifBlank { null })
            .setStyle(style)
            // `when` aimed at the class start is what makes the system render its own live countdown
            // ("15min") in the status-bar chip and on the lock screen, with no polling from us.
            .setWhen(spec.startAtMillis)
            .setShowWhen(true)
            .setOngoing(true)
            .setAutoCancel(false)
            // Progress refreshes must not buzz the phone a second time.
            .setOnlyAlertOnce(true)
            .setColor(spec.accentColor)
            .setContentIntent(contentIntent(context, spec))
            .setDeleteIntent(deleteIntent(context, spec))
            // The activity ends when the class begins; deliberately not a second alarm.
            .apply { if (remaining > 0) setTimeoutAfter(remaining) }
            .build()

        notification.extras.putBoolean(EXTRA_REQUEST_PROMOTED_ONGOING, true)
        return notification
    }

    private fun contentIntent(context: Context, spec: CourseLiveUpdateSpec): PendingIntent {
        val intent = context.packageManager
            .getLaunchIntentForPackage(context.packageName)
            ?: Intent().setPackage(context.packageName)
        intent.action = ACTION_OPEN_LIVE_UPDATE
        intent.putExtra(EXTRA_SPEC_ID, spec.id)
        intent.addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
        )
        return PendingIntent.getActivity(
            context,
            spec.id,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /**
     * Fires when the user dismisses the notification, so the reminder can be retired rather than
     * reposted by its mid-window refresh — Android's guidance is to never repost a dismissed Live
     * Update.
     */
    private fun deleteIntent(context: Context, spec: CourseLiveUpdateSpec): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            spec.id,
            Intent(context, CourseLiveUpdateReceiver::class.java)
                .setAction(CourseLiveUpdateReceiver.ACTION_DISMISSED)
                .putExtra(CourseLiveUpdateReceiver.EXTRA_SPEC_ID, spec.id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    /**
     * Creates the shared channel when it does not exist yet.
     *
     * The values mirror what `flutter_local_notifications` passes for this channel id, because
     * channel settings are immutable after creation: whichever side creates it first wins, so the
     * two definitions must agree or the user would silently get different alerting depending on
     * which path scheduled a reminder first.
     */
    private fun ensureChannel(context: Context) {
        val manager = context
            .getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Course Reminder",
            NotificationManager.IMPORTANCE_MAX,
        ).apply {
            description = "Course reminder notifications for upcoming classes"
            enableVibration(true)
            setShowBadge(false)
            setSound(
                Settings.System.DEFAULT_NOTIFICATION_URI,
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                    .build(),
            )
        }
        manager.createNotificationChannel(channel)
    }

    @TargetApi(36)
    @SuppressLint("NewApi")
    private fun canPostPromoted(manager: NotificationManager): Boolean =
        manager.canPostPromotedNotifications()
}
