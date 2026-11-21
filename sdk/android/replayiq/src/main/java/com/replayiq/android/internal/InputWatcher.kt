package com.replayiq.android.internal

import android.text.Editable
import android.text.TextWatcher
import android.view.View
import android.view.ViewTreeObserver
import android.widget.EditText
import org.json.JSONObject
import java.util.WeakHashMap

/**
 * `input` events: when a focused EditText is edited, one event per burst of typing (a new burst
 * starts after [quietMs] without changes). Only the field's selector is sent, never its value.
 * Main thread only.
 */
internal class InputWatcher(
    private val inspector: ViewInspector,
    private val emit: (JSONObject) -> Unit,
    private val clock: () -> Long = System::currentTimeMillis,
    private val quietMs: Long = 1_000,
) {
    private val watched = WeakHashMap<EditText, Watcher>()
    private val observedRoots = WeakHashMap<View, Boolean>()
    @Volatile var enabled = true

    private val focusListener = ViewTreeObserver.OnGlobalFocusChangeListener { oldFocus, newFocus ->
        if (newFocus is EditText) watch(newFocus)
        if (!enabled) return@OnGlobalFocusChangeListener
        try {
            val now = clock()
            if (oldFocus is EditText) emit(Events.focus(now, false, inspector.selectorFor(oldFocus)))
            if (newFocus is EditText) emit(Events.focus(now, true, inspector.selectorFor(newFocus)))
        } catch (t: Throwable) { Log.w("focus event failed", t) }
    }

    fun observe(root: View) {
        if (observedRoots[root] == true) return
        val vto = root.viewTreeObserver
        if (!vto.isAlive) return
        vto.addOnGlobalFocusChangeListener(focusListener)
        observedRoots[root] = true
        (root.findFocus() as? EditText)?.let { watch(it) }
    }

    fun watch(field: EditText) {
        if (watched.containsKey(field)) return
        val w = Watcher(field)
        field.addTextChangedListener(w)
        watched[field] = w
    }

    private inner class Watcher(private val field: EditText) : TextWatcher {
        private var lastChange = Long.MIN_VALUE
        override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
        override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
        override fun afterTextChanged(s: Editable?) {
            if (!enabled || !field.hasFocus()) return // programmatic setText on an unfocused field
            val now = clock()
            val newBurst = lastChange == Long.MIN_VALUE || now - lastChange >= quietMs
            lastChange = now
            if (newBurst) {
                try { emit(Events.input(now, inspector.selectorFor(field))) } catch (t: Throwable) { Log.w("input event failed", t) }
            }
        }
    }
}
