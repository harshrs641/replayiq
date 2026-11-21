package com.replayiq.android.internal

import android.content.Context
import android.content.SharedPreferences

/** The session state that must survive process death (so a relaunch within the timeout continues the session). */
internal data class SessionState(
    val id: String,
    val startedAt: Long,
    val sampled: Boolean,
    var seq: Int = 0,
    var lastActive: Long = startedAt,
    var created: Boolean = false,
)

internal class SessionStore(context: Context) {
    private val prefs: SharedPreferences = context.getSharedPreferences("com.replayiq.android", Context.MODE_PRIVATE)

    fun load(): SessionState? {
        val id = prefs.getString(K_ID, null) ?: return null
        return SessionState(
            id = id,
            startedAt = prefs.getLong(K_STARTED, 0),
            sampled = prefs.getBoolean(K_SAMPLED, true),
            seq = prefs.getInt(K_SEQ, 0),
            lastActive = prefs.getLong(K_ACTIVE, 0),
            created = prefs.getBoolean(K_CREATED, false),
        )
    }

    /** [sync] = commit() (used from the crash handler, which must not lose the write). */
    fun save(s: SessionState?, sync: Boolean = false) {
        val e = prefs.edit()
        if (s == null) {
            e.remove(K_ID).remove(K_STARTED).remove(K_SAMPLED).remove(K_SEQ).remove(K_ACTIVE).remove(K_CREATED)
        } else {
            e.putString(K_ID, s.id).putLong(K_STARTED, s.startedAt).putBoolean(K_SAMPLED, s.sampled)
                .putInt(K_SEQ, s.seq).putLong(K_ACTIVE, s.lastActive).putBoolean(K_CREATED, s.created)
        }
        if (sync) e.commit() else e.apply()
    }

    var optedOut: Boolean
        get() = prefs.getBoolean(K_OPT_OUT, false)
        set(v) { prefs.edit().putBoolean(K_OPT_OUT, v).apply() }

    var userId: String?
        get() = prefs.getString(K_USER, null)
        set(v) { prefs.edit().putString(K_USER, v).apply() }

    var traits: Map<String, String>
        get() = prefs.getStringSet(K_TRAITS, emptySet())!!.mapNotNull {
            val i = it.indexOf('='); if (i <= 0) null else it.substring(0, i) to it.substring(i + 1)
        }.toMap()
        set(v) { prefs.edit().putStringSet(K_TRAITS, v.map { (k, x) -> "$k=$x" }.toSet()).apply() }

    private companion object {
        const val K_ID = "session_id"
        const val K_STARTED = "session_started_at"
        const val K_SAMPLED = "session_sampled"
        const val K_SEQ = "session_seq"
        const val K_ACTIVE = "session_last_active"
        const val K_CREATED = "session_created"
        const val K_OPT_OUT = "opted_out"
        const val K_USER = "user_id"
        const val K_TRAITS = "user_traits"
    }
}
