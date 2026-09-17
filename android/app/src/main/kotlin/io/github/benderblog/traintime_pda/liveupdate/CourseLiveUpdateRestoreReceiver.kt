// Copyright 2025 Traintime PDA authors.
// SPDX-License-Identifier: MPL-2.0

// Restores course Live Updates after a reboot or an app update. AlarmManager forgets everything
// across reboots, and the Dart side only rebuilds the plan when the app is opened.

package io.github.benderblog.traintime_pda.liveupdate

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class CourseLiveUpdateRestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action !in RESTORE_ACTIONS) return

        val armed = CourseLiveUpdateScheduler.rearm(context.applicationContext)
        Log.i(TAG, "Re-armed $armed course Live Updates after $action")
    }

    companion object {
        private const val TAG = "XDYouLiveUpdate"

        private val RESTORE_ACTIONS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON",
        )
    }
}
