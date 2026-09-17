// Copyright 2025 Traintime PDA authors.
// SPDX-License-Identifier: MPL-2.0

// Exact-alarm bookkeeping for course Live Updates.
//
// flutter_local_notifications cannot express `ProgressStyle` or `setRequestPromotedOngoing`, so
// reminders that should be Live Updates are scheduled natively here and delivered by
// [CourseLiveUpdateReceiver]. Each reminder arms two alarms: one to post it, and one to advance its
// progress bar at the midpoint of the wait. The pending list is persisted so [rearm] can restore it
// after a reboot or an app update.

package io.github.benderblog.traintime_pda.liveupdate

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import org.json.JSONArray

object CourseLiveUpdateScheduler {
    private const val TAG = "XDYouLiveUpdate"

    private const val PREFERENCES_NAME = "course_live_update_reminders"
    private const val KEY_SPECS = "specs"

    /**
     * Arms the post alarm and, when the wait is long enough, the progress-refresh alarm.
     *
     * Returns whether the post alarm was armed; alarms for moments already in the past are skipped,
     * since those specs only exist so a delivery in flight can still look itself up.
     */
    internal fun arm(context: Context, spec: CourseLiveUpdateSpec): Boolean {
        val now = System.currentTimeMillis()
        val postArmed = if (spec.triggerAtMillis > now) {
            setAlarm(context, spec.triggerAtMillis, postPendingIntent(context, spec.id), spec.id)
        } else {
            false
        }

        val refreshAt = spec.refreshAtMillis
        if (refreshAt != null && refreshAt > now) {
            setAlarm(context, refreshAt, refreshPendingIntent(context, spec.id), spec.id)
        }
        return postArmed
    }

    internal fun disarm(context: Context, specId: Int) {
        val manager = context.getSystemService(AlarmManager::class.java) ?: return
        listOf(postPendingIntent(context, specId), refreshPendingIntent(context, specId)).forEach {
            manager.cancel(it)
            it.cancel()
        }
    }

    /**
     * Replaces the stored reminder set with [specs] and (re)arms the alarms.
     *
     * Alarms that disappeared or moved are cancelled first, so this is safe to call on every app
     * start with a freshly computed plan. Returns the number of reminders armed.
     */
    fun schedule(context: Context, specs: List<CourseLiveUpdateSpec>): Int {
        val appContext = context.applicationContext
        val previous = load(appContext)
        save(appContext, specs)

        val wanted = specs.associateBy { it.id }
        previous.forEach { old ->
            val current = wanted[old.id]
            if (current == null ||
                current.triggerAtMillis != old.triggerAtMillis ||
                current.startAtMillis != old.startAtMillis
            ) {
                disarm(appContext, old.id)
            }
        }

        var armed = 0
        specs.forEach { spec -> if (arm(appContext, spec)) armed++ }
        Log.i(TAG, "Scheduled $armed of ${specs.size} course Live Updates")
        return armed
    }

    /** Cancels every pending reminder and removes any that are already on screen. */
    fun cancelAll(context: Context): Int {
        val appContext = context.applicationContext
        val previous = load(appContext)
        previous.forEach { spec ->
            disarm(appContext, spec.id)
            LiveUpdatePublisher.cancel(appContext, spec.id)
        }
        save(appContext, emptyList())
        Log.i(TAG, "Cancelled ${previous.size} course Live Updates")
        return previous.size
    }

    /**
     * Retires a reminder the user dismissed: its alarms are dropped and it leaves the plan, so the
     * pending progress refresh cannot bring it back.
     */
    fun retire(context: Context, specId: Int) {
        val appContext = context.applicationContext
        disarm(appContext, specId)
        save(appContext, load(appContext).filterNot { it.id == specId })
        Log.i(TAG, "Reminder $specId was dismissed and retired from the plan")
    }

    /** Re-arms every future reminder and prunes the ones that already started. */
    fun rearm(context: Context): Int {
        val appContext = context.applicationContext
        val now = System.currentTimeMillis()
        val stored = load(appContext)
        // A reminder whose class has already begun can never be useful again.
        val future = stored.filter { it.startAtMillis > now }
        if (future.size != stored.size) save(appContext, future)

        var armed = 0
        future.forEach { spec -> if (arm(appContext, spec)) armed++ }
        return armed
    }

    fun find(context: Context, specId: Int): CourseLiveUpdateSpec? =
        load(context.applicationContext).firstOrNull { it.id == specId }

    fun pendingCount(context: Context): Int {
        val now = System.currentTimeMillis()
        return load(context.applicationContext).count { it.startAtMillis > now }
    }

    private fun setAlarm(
        context: Context,
        atMillis: Long,
        pendingIntent: PendingIntent,
        specId: Int,
    ): Boolean {
        val manager = context.getSystemService(AlarmManager::class.java)
        if (manager == null) {
            Log.w(TAG, "No AlarmManager available, cannot schedule reminder $specId")
            return false
        }
        return try {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || manager.canScheduleExactAlarms()) {
                manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pendingIntent)
            } else {
                // XDYou asks for SCHEDULE_EXACT_ALARM/USE_EXACT_ALARM, but a user can still revoke
                // it; an inexact wake-up is far better than no reminder at all.
                Log.i(TAG, "Exact alarms unavailable, scheduling reminder $specId inexactly")
                manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pendingIntent)
            }
            true
        } catch (error: SecurityException) {
            Log.w(TAG, "Exact alarm denied for $specId, retrying inexactly", error)
            runCatching {
                manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMillis, pendingIntent)
            }.fold(
                onSuccess = { true },
                onFailure = { inner ->
                    Log.e(TAG, "Unable to schedule reminder $specId", inner)
                    false
                },
            )
        }
    }

    /**
     * Post and refresh share a request code and are told apart by their action, which is part of a
     * `PendingIntent`'s identity. That avoids having to invent collision-free request codes for the
     * second alarm.
     */
    private fun postPendingIntent(context: Context, specId: Int): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            specId,
            Intent(context, CourseLiveUpdateReceiver::class.java)
                .setAction(CourseLiveUpdateReceiver.ACTION_POST)
                .putExtra(CourseLiveUpdateReceiver.EXTRA_SPEC_ID, specId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun refreshPendingIntent(context: Context, specId: Int): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            specId,
            Intent(context, CourseLiveUpdateReceiver::class.java)
                .setAction(CourseLiveUpdateReceiver.ACTION_REFRESH)
                .putExtra(CourseLiveUpdateReceiver.EXTRA_SPEC_ID, specId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    private fun load(context: Context): List<CourseLiveUpdateSpec> = runCatching {
        val prefs = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_SPECS, null)
        if (raw.isNullOrBlank()) {
            emptyList<CourseLiveUpdateSpec>()
        } else {
            val array = JSONArray(raw)
            buildList<CourseLiveUpdateSpec> {
                for (index in 0 until array.length()) {
                    val json = array.optJSONObject(index) ?: continue
                    val spec = CourseLiveUpdateSpec.fromJson(json) ?: continue
                    add(spec)
                }
            }
        }
    }.getOrElse { error ->
        Log.w(TAG, "Unable to read stored course Live Updates", error)
        emptyList()
    }

    private fun save(context: Context, specs: List<CourseLiveUpdateSpec>) {
        runCatching {
            val array = JSONArray()
            specs.forEach { array.put(it.toJson()) }
            context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_SPECS, array.toString())
                .apply()
        }.onFailure { error ->
            Log.e(TAG, "Unable to persist course Live Updates", error)
        }
    }
}
