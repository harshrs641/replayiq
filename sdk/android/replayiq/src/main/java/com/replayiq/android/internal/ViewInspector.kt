package com.replayiq.android.internal

import android.graphics.Rect
import android.text.InputType
import android.text.method.PasswordTransformationMethod
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.CheckBox
import android.widget.CompoundButton
import android.widget.EditText
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.RadioButton
import android.widget.Switch
import android.widget.TextView
import com.replayiq.android.R
import com.replayiq.android.ReplayIQOptions

/** Which views are masked, where they are, and how a touched view is named in selectors. Main thread only. */
internal class ViewInspector(private val options: ReplayIQOptions) {

    /** Explicit choice for [v]: true = mask, false = unmask, null = default rules. */
    fun explicit(v: View): Boolean? {
        (v.getTag(R.id.replayiq_mask) as? Boolean)?.let { return it }
        if (v.tag == XML_TAG) return true
        return null
    }

    /** Whether [v] itself is painted over (not counting ancestors). */
    fun isMasked(v: View): Boolean {
        if (v is TextView && isPassword(v)) return true // passwords: always, even when unmasked
        explicit(v)?.let { return it }
        return when {
            v is EditText -> options.maskAllInputs || options.maskAllText
            v is TextView -> options.maskAllText
            v is ImageView -> options.maskAllImages
            options.maskWebViews && v is android.webkit.WebView -> true
            else -> false
        }
    }

    /** [v] or one of its ancestors is masked. */
    fun isMaskedOrInside(v: View): Boolean {
        var cur: View? = v
        while (cur != null) {
            if (isMasked(cur)) return true
            cur = cur.parent as? View
        }
        return false
    }

    /** Window-pixel rects to paint over, for every visible masked view under [root]. */
    fun collectMasks(root: View, out: MutableList<Rect>) {
        if (root.visibility != View.VISIBLE || root.alpha <= 0f) return
        if (isMasked(root)) {
            val r = Rect()
            if (root.getGlobalVisibleRect(r)) out.add(r)
            return
        }
        if (ComposeSupport.isComposeView(root)) {
            ComposeSupport.collectMasks(root, options, out)
        }
        if (root is ViewGroup) {
            for (i in 0 until root.childCount) collectMasks(root.getChildAt(i), out)
        }
    }

    /** Deepest visible view at window point ([x], [y]) in px. */
    fun hitTest(root: View, x: Int, y: Int): View? {
        if (root.visibility != View.VISIBLE) return null
        val r = Rect()
        if (!root.getGlobalVisibleRect(r) || !r.contains(x, y)) return null
        if (root is ViewGroup) {
            for (i in root.childCount - 1 downTo 0) { // last drawn = on top
                val hit = hitTest(root.getChildAt(i), x, y) ?: continue
                // Compose's interop container covers the whole composable: the composable is the target.
                if (hit is ViewGroup && hit.javaClass.simpleName == "AndroidViewsHandler") continue
                return hit
            }
        }
        return root
    }

    /** `role:"label"` for a tap at window point ([x], [y]) px. */
    fun selectorAt(root: View, x: Int, y: Int): String? {
        val hit = hitTest(root, x, y) ?: return null
        if (ComposeSupport.isComposeView(hit)) {
            ComposeSupport.selectorAt(hit, x, y, options)?.let { return it }
        }
        var target: View = hit
        var cur: View? = hit
        while (cur != null) {
            if (cur.isClickable || cur.isLongClickable) { target = cur; break }
            cur = cur.parent as? View
        }
        return selector(role(target), label(target))
    }

    fun selectorFor(v: View): String = selector(role(v), label(v))

    fun role(v: View): String = when (v) {
        is EditText -> "input"
        is RadioButton -> "radio"
        is CheckBox -> "checkbox"
        is Switch -> "switch"
        is CompoundButton -> if (v.javaClass.simpleName.contains("Switch")) "switch" else "checkbox"
        is Button, is ImageButton -> "button"
        is ImageView -> if (v.isClickable) "button" else "image"
        is TextView -> if (v.isClickable) "button" else "text"
        else -> when {
            v.javaClass.name.contains("SwitchCompat") || v.javaClass.name.contains("MaterialSwitch") -> "switch"
            v.isClickable -> "button"
            else -> "view"
        }
    }

    /** Visible label of [v]: content description, else its text (never the text of a masked view or input), else its id. */
    fun label(v: View): String {
        val masked = isMaskedOrInside(v)
        v.contentDescription?.toString()?.takeIf { it.isNotBlank() }?.let { return clean(it) }
        if (v is EditText) {
            v.hint?.toString()?.takeIf { it.isNotBlank() }?.let { return clean(it) }
        } else if (!masked) {
            if (v is TextView) v.text?.toString()?.takeIf { it.isNotBlank() }?.let { return clean(it) }
            if (v is ViewGroup) firstText(v)?.let { return clean(it) }
        }
        idName(v)?.let { return it }
        return v.javaClass.simpleName.ifEmpty { "View" }
    }

    private fun firstText(g: ViewGroup, depth: Int = 0): String? {
        if (depth > 4) return null
        for (i in 0 until g.childCount) {
            val c = g.getChildAt(i)
            if (c.visibility != View.VISIBLE || isMasked(c)) continue
            c.contentDescription?.toString()?.takeIf { it.isNotBlank() }?.let { return it }
            if (c is TextView && c !is EditText) c.text?.toString()?.takeIf { it.isNotBlank() }?.let { return it }
            if (c is ViewGroup) firstText(c, depth + 1)?.let { return it }
        }
        return null
    }

    private fun idName(v: View): String? {
        if (v.id == View.NO_ID || v.id == 0) return null
        return try { "#" + v.resources.getResourceEntryName(v.id) } catch (_: Exception) { null }
    }

    companion object {
        /** `android:tag="replayiq-mask"` in layout XML masks a view. */
        const val XML_TAG = "replayiq-mask"
        private const val MAX_LABEL = 60

        fun selector(role: String, label: String) = "$role:\"${clean(label)}\""

        fun clean(s: String): String =
            s.replace('\n', ' ').replace('"', '\'').trim().let { if (it.length > MAX_LABEL) it.take(MAX_LABEL - 1) + "…" else it }

        fun isPassword(v: TextView): Boolean {
            if (v.transformationMethod is PasswordTransformationMethod) return true
            val t = v.inputType
            val variation = t and InputType.TYPE_MASK_VARIATION
            return when (t and InputType.TYPE_MASK_CLASS) {
                InputType.TYPE_CLASS_TEXT -> variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                    variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
                    variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
                InputType.TYPE_CLASS_NUMBER -> variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
                else -> false
            }
        }
    }
}
