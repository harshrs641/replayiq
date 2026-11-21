package com.replayiq.android.internal

import android.app.Activity
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.FragmentManager

/** `navigate` for AndroidX fragments. androidx.fragment is optional: checked before anything here is used. */
internal object FragmentTracker {
    private val available: Boolean by lazy {
        try { Class.forName("androidx.fragment.app.FragmentActivity"); true } catch (_: Throwable) { false }
    }

    fun register(activity: Activity, onScreen: (String) -> Unit) {
        if (!available) return
        try {
            if (activity !is FragmentActivity) return
            activity.supportFragmentManager.registerFragmentLifecycleCallbacks(object : FragmentManager.FragmentLifecycleCallbacks() {
                override fun onFragmentResumed(fm: FragmentManager, f: Fragment) {
                    if (isScreen(f)) onScreen(activity.javaClass.simpleName + "/" + f.javaClass.simpleName)
                }
            }, true)
        } catch (t: Throwable) {
            Log.w("fragment tracking unavailable", t)
        }
    }

    /** Containers (NavHostFragment), dialogs and headless/hidden fragments aren't screens. */
    private fun isScreen(f: Fragment): Boolean {
        if (f.view == null || f.isHidden) return false
        val name = f.javaClass.name
        if (name.endsWith("NavHostFragment") || name.contains("SupportRequestManagerFragment") || name.contains("ReportFragment")) return false
        if (f is androidx.fragment.app.DialogFragment) return false
        return true
    }
}
