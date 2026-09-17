// Copyright 2025 Traintime PDA authors.
// SPDX-License-Identifier: MPL-2.0

// Delivers a scheduled course Live Update, advances its progress, and retires it on dismissal.

package io.github.benderblog.traintime_pda.liveupdate

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class CourseLiveUpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val specId = intent.getIntExtra(EXTRA_SPEC_ID, -1)
        if (specId < 0) return

        val appContext = context.applicationContext
        when (intent.action) {
            ACTION_POST -> {
                val spec = CourseLiveUpdateScheduler.find(appContext, specId)
                if (spec == null) {
                    Log.w(TAG, "Reminder $specId fired but is no longer stored")
                    return
                }
                if (spec.triggerAtMillis > System.currentTimeMillis() + DELIVERY_TOLERANCE_MS) {
                    // If exact alarms were unavailable the alarm may have been pulled forward;
                    // re-arm rather than reminding too early.
                    Log.i(TAG, "Reminder $specId arrived early, re-arming")
                    CourseLiveUpdateScheduler.arm(appContext, spec)
                    return
                }
                publish(appContext, spec)
            }

            ACTION_REFRESH -> {
                // Reposting with the same id advances the progress bar. setOnlyAlertOnce(true) keeps
                // this silent. A spec the user already dismissed is gone from the store, so this is
                // also where Android's "never repost a dismissed Live Update" rule is honoured.
                val spec = CourseLiveUpdateScheduler.find(appContext, specId)
                if (spec == null) {
                    Log.i(TAG, "Reminder $specId was dismissed; skipping its progress refresh")
                    return
                }
                publish(appContext, spec)
            }

            ACTION_DISMISSED -> CourseLiveUpdateScheduler.retire(appContext, specId)
        }
    }

    /**
     * Keeps the receiver alive until the publish reports back, since the notification is built and
     * posted asynchronously with respect to the broadcast.
     */
    private fun publish(context: Context, spec: CourseLiveUpdateSpec) {
        val pendingResult = goAsync()
        LiveUpdatePublisher.publish(context, spec) { pendingResult.finish() }
    }

    companion object {
        private const val TAG = "XDYouLiveUpdate"

        const val ACTION_POST = "io.github.benderblog.traintime_pda.liveupdate.POST"
        const val ACTION_REFRESH = "io.github.benderblog.traintime_pda.liveupdate.REFRESH"
        const val ACTION_DISMISSED = "io.github.benderblog.traintime_pda.liveupdate.DISMISSED"
        const val EXTRA_SPEC_ID = "io.github.benderblog.traintime_pda.liveupdate.SPEC_ID"

        private const val DELIVERY_TOLERANCE_MS = 1_000L
    }
}
