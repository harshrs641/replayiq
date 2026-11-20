package com.replayiq.android.internal

import android.graphics.Rect
import android.view.View
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import com.replayiq.android.ReplayIQOptions
import com.replayiq.android.compose.ReplayIQMaskKey

/**
 * Jetpack Compose support through the semantics tree. Compose is an optional dependency: nothing
 * here is touched unless the app has Compose on its classpath, and any failure (an incompatible
 * Compose version) disables it for the run instead of crashing.
 */
internal object ComposeSupport {
    @Volatile private var broken = false

    private val available: Boolean by lazy {
        try {
            Class.forName("androidx.compose.ui.platform.ViewRootForTest")
            Class.forName("androidx.compose.ui.semantics.SemanticsNode")
            true
        } catch (_: Throwable) {
            false
        }
    }

    fun isComposeView(v: View): Boolean = available && isRoot(v)

    private fun isRoot(v: View): Boolean = try { v is ViewRootForTest } catch (_: Throwable) { false }

    fun collectMasks(v: View, options: ReplayIQOptions, out: MutableList<Rect>) {
        try {
            check(!broken) { "compose inspection disabled" }
            val root = (v as ViewRootForTest).semanticsOwner.unmergedRootSemanticsNode
            walkMasks(root, options, out)
        } catch (t: Throwable) {
            disable(t)
            // Can't inspect it: mask the whole compose view rather than leak its content.
            val r = Rect(); if (v.getGlobalVisibleRect(r)) out.add(r)
        }
    }

    private fun walkMasks(node: SemanticsNode, options: ReplayIQOptions, out: MutableList<Rect>) {
        if (shouldMask(node, options)) {
            val b = node.boundsInWindow
            if (b.width > 0 && b.height > 0) {
                out.add(Rect(b.left.toInt(), b.top.toInt(), kotlin.math.ceil(b.right).toInt(), kotlin.math.ceil(b.bottom).toInt()))
            }
            return
        }
        for (c in node.children) walkMasks(c, options, out)
    }

    private fun shouldMask(node: SemanticsNode, options: ReplayIQOptions): Boolean {
        val c = node.config
        if (c.contains(SemanticsProperties.Password)) return true
        c.getOrNull(ReplayIQMaskKey)?.let { return it }
        if (c.contains(SemanticsProperties.EditableText)) return options.maskAllInputs || options.maskAllText
        if (options.maskAllText && c.contains(SemanticsProperties.Text)) return true
        if (options.maskAllImages && c.getOrNull(SemanticsProperties.Role) == Role.Image) return true
        return false
    }

    /** `role:"label"` of the clickable composable at window point ([x], [y]), or null. */
    fun selectorAt(v: View, x: Int, y: Int, options: ReplayIQOptions): String? = if (broken) null else try {
        val root = (v as ViewRootForTest).semanticsOwner.rootSemanticsNode
        val hit = deepestClickable(root, x.toFloat(), y.toFloat())
        hit?.let { ViewInspector.selector(role(it), label(it, options)) }
    } catch (t: Throwable) {
        disable(t); null
    }

    private fun deepestClickable(node: SemanticsNode, x: Float, y: Float): SemanticsNode? {
        val b = node.boundsInWindow
        if (!(x >= b.left && x < b.right && y >= b.top && y < b.bottom)) return null
        for (c in node.children.asReversed()) deepestClickable(c, x, y)?.let { return it }
        val c = node.config
        return if (c.contains(SemanticsActions.OnClick) || c.contains(SemanticsProperties.EditableText)) node else null
    }

    fun role(n: SemanticsNode): String {
        val c = n.config
        if (c.contains(SemanticsProperties.EditableText)) return "input"
        return when (c.getOrNull(SemanticsProperties.Role)) {
            Role.Button -> "button"
            Role.Checkbox -> "checkbox"
            Role.Switch -> "switch"
            Role.RadioButton -> "radio"
            Role.Tab -> "tab"
            Role.Image -> "image"
            Role.DropdownList -> "select"
            else -> "button"
        }
    }

    fun label(n: SemanticsNode, options: ReplayIQOptions): String {
        val c = n.config
        c.getOrNull(SemanticsProperties.ContentDescription)?.firstOrNull()?.takeIf { it.isNotBlank() }?.let { return it }
        val masked = c.contains(SemanticsProperties.EditableText) || c.contains(SemanticsProperties.Password) ||
            c.getOrNull(ReplayIQMaskKey) == true || options.maskAllText
        if (!masked) {
            c.getOrNull(SemanticsProperties.Text)?.joinToString(" ") { it.text }?.takeIf { it.isNotBlank() }?.let { return it }
        }
        // A text field's merged Text is its label / placeholder; never use its value.
        val value = c.getOrNull(SemanticsProperties.EditableText)?.text
        if (value != null && c.getOrNull(ReplayIQMaskKey) != true) {
            c.getOrNull(SemanticsProperties.Text)?.map { it.text }?.firstOrNull { it.isNotBlank() && it != value }?.let { return it }
        }
        c.getOrNull(SemanticsProperties.TestTag)?.let { return "#$it" }
        return "Composable"
    }

    private fun disable(t: Throwable) {
        if (!broken) Log.w("Compose inspection unavailable", t)
        broken = t is LinkageError || t is ClassCastException
    }
}
