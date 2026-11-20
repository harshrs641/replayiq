package com.replayiq.android.internal

import android.graphics.Rect
import android.view.View
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.isSpecified
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.ViewRootForTest
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.isSpecified
import com.replayiq.android.ReplayIQOptions
import com.replayiq.android.compose.ReplayIQMaskKey
import java.lang.reflect.Field
import kotlin.math.max

/**
 * Jetpack Compose → Native DOM, from the semantics tree (best-effort):
 *  - frames from each semantics node's unclipped position and size;
 *  - text (and its style, from the public GetTextLayoutResult action), text fields as `input`
 *    (never the value), roles and labels of clickables, `Modifier.replayIQMask()` as `mask`;
 *  - `verticalScroll` / `horizontalScroll` containers as `scroll` (lazy lists: clipped views whose
 *    children move);
 *  - background colour, rounded shape, border and shadow read from the node's modifiers (by
 *    reflection on Compose internals: lost when R8 renames them);
 *  - images and icons (Role.Image or a content description without text) as islands.
 * Layout nodes without semantics (plain Box / Row backgrounds, drawBehind, Canvas) aren't seen.
 */
internal object ComposeDom {
    @Volatile private var broken = false

    /**
     * Per compose root, by semantics id: modifier styles (re-read every second) and text styles
     * (re-read when the text changes: GetTextLayoutResult costs ~0.3 ms per text).
     */
    class Cache {
        val styles = HashMap<Int, DomNode>()
        val texts = HashMap<Int, DomNode.TextInfo>()
        var refreshedAt = 0L
        var refresh = true
        var textBudget = 0
    }

    fun append(v: View, parent: DomNode, w: ViewWalker, options: ReplayIQOptions) {
        if (broken) { asIsland(v, parent, w); return }
        try {
            val owner = (v as ViewRootForTest).semanticsOwner
            val root = owner.unmergedRootSemanticsNode
            val nodeIds = w.idsOf(v)
            val ids = nodeIds.compose ?: HashMap<Long, Int>().also { nodeIds.compose = it }
            val cache = nodeIds.composeCache ?: Cache().also { nodeIds.composeCache = it }
            val now = android.os.SystemClock.uptimeMillis()
            cache.refresh = now - cache.refreshedAt >= CACHE_MS
            if (cache.refresh) { cache.refreshedAt = now; cache.styles.clear() }
            cache.textBudget = TEXT_READS_PER_WALK
            val ctx = Ctx(w, ids, options, w.d, Density(w.d, v.resources.configuration.fontScale), IntArray(2).also { v.getLocationInWindow(it) }, cache)
            val origin = root.positionInRoot
            for (c in root.children) node(c, origin.x, origin.y, 0f, 0f, ctx)?.let { parent.c.add(it) }
        } catch (t: Throwable) {
            if (!broken) Log.w("Compose DOM unavailable", t)
            broken = t is LinkageError || t is ClassCastException
            parent.c.clear()
            asIsland(v, parent, w)
        }
    }

    /** Can't inspect it: record it as pixels (masked as a whole by the island capture). */
    private fun asIsland(v: View, parent: DomNode, w: ViewWalker) {
        parent.k = "island"
        val loc = IntArray(2).also { v.getLocationInWindow(it) }
        val rect = Rect(loc[0], loc[1], loc[0] + v.width, loc[1] + v.height)
        val vis = Rect()
        if (v.getGlobalVisibleRect(vis)) w.addIsland(parent.id, rect, vis, null)
        w.islandHashOf(parent.id)?.let { parent.img = it; parent.fit = "fill" } ?: run { parent.hint = "unknown" }
    }

    private class Ctx(val w: ViewWalker, val ids: HashMap<Long, Int>, val options: ReplayIQOptions, val d: Float,
                      val density: Density, val windowOrigin: IntArray, val cache: Cache)

    private fun idOf(ctx: Ctx, semId: Int, slot: Int): Int = ctx.ids.getOrPut(semId.toLong() * 4 + slot) { NodeIdAllocator.next() }

    private fun node(sn: SemanticsNode, originX: Float, originY: Float, offX: Float, offY: Float, ctx: Ctx): DomNode? {
        val size = sn.size
        if (size.width <= 0 || size.height <= 0) return null
        val d = ctx.d
        val pos = sn.positionInRoot
        val cfg = sn.config
        val kids = sn.children
        val n = DomNode(idOf(ctx, sn.id, 0), "view").frame((pos.x - originX) / d + offX, (pos.y - originY) / d + offY, size.width / d, size.height / d)
        val clickable = cfg.contains(SemanticsActions.OnClick)
        val editable = cfg.getOrNull(SemanticsProperties.EditableText)

        if (masked(cfg, ctx.options, editable != null)) {
            n.k = "mask"
            if (clickable || editable != null) n.role = ComposeSupport.role(sn)
            return n
        }
        val style = ctx.cache.styles.getOrPut(sn.id) { DomNode(0, "view").also { modifierStyle(sn, it, ctx) } }
        n.bg = style.bg; n.radii = style.radii; n.bw = style.bw; n.bc = style.bc; n.shadow = style.shadow; n.shadowColor = style.shadowColor
        if (clickable) { n.role = ComposeSupport.role(sn); n.label = ViewInspector.clean(ComposeSupport.label(sn, ctx.options)) }

        if (editable != null) {
            n.k = "input"
            val password = cfg.contains(SemanticsProperties.Password)
            val ph = firstText(sn, editable.text)
            n.input = DomNode.InputInfo(if (password) "password" else "text", ph?.let { ViewInspector.clean(it) }, editable.text.length,
                cfg.getOrNull(SemanticsProperties.Focused) == true)
            n.role = "input"
            return n
        }

        val texts = cfg.getOrNull(SemanticsProperties.Text)
        val isImage = cfg.getOrNull(SemanticsProperties.Role) == Role.Image ||
            (cfg.contains(SemanticsProperties.ContentDescription) && texts.isNullOrEmpty() && kids.isEmpty() && !clickable)
        if (isImage && texts.isNullOrEmpty()) {
            n.k = "island"
            val rect = Rect(ctx.windowOrigin[0] + pos.x.toInt(), ctx.windowOrigin[1] + pos.y.toInt(),
                ctx.windowOrigin[0] + pos.x.toInt() + size.width, ctx.windowOrigin[1] + pos.y.toInt() + size.height)
            ctx.w.addIsland(n.id, rect, rect, null)
            ctx.w.islandHashOf(n.id)?.let { n.img = it; n.fit = "fill" } ?: run { n.hint = "unknown" }
            return n
        }

        val vRange = cfg.getOrNull(SemanticsProperties.VerticalScrollAxisRange)
        val hRange = cfg.getOrNull(SemanticsProperties.HorizontalScrollAxisRange)
        val lazy = cfg.contains(SemanticsProperties.CollectionInfo) || cfg.contains(SemanticsActions.ScrollToIndex)
        var childOffX = 0f
        var childOffY = 0f
        if ((vRange != null || hRange != null) && !lazy) {
            // verticalScroll / horizontalScroll: the range is in px, children laid out in content coordinates.
            n.k = "scroll"
            val sx = (hRange?.value?.invoke() ?: 0f) / d
            val sy = (vRange?.value?.invoke() ?: 0f) / d
            n.so = floatArrayOf(sx, sy)
            childOffX = sx; childOffY = sy
            val ex = ((hRange?.maxValue?.invoke() ?: 0f) / d) + size.width / d
            val ey = ((vRange?.maxValue?.invoke() ?: 0f) / d) + size.height / d
            n.c.add(DomNode(idOf(ctx, sn.id, 3), "view").frame(max(0f, ex - 1f), max(0f, ey - 1f), 1f, 1f))
            n.selector = ViewInspector.selector("scroll", ComposeSupport.label(sn, ctx.options))
        } else if (vRange != null || hRange != null) {
            n.clip = true // lazy list: its range is in items, not px; children move instead
        }

        if (!texts.isNullOrEmpty()) {
            val value = texts.joinToString(" ") { it.text }
            val cached = ctx.cache.texts[sn.id]
            val info = when {
                cached != null && cached.v == value -> cached
                ctx.cache.textBudget > 0 -> { ctx.cache.textBudget--; textInfo(cfg, value, ctx).also { ctx.cache.texts[sn.id] = it } }
                else -> {
                    // Over this walk's budget: placeholder style now, the real one on the next walk.
                    ctx.w.incomplete = true
                    (cached ?: DomNode.TextInfo(value, 14f, 400, false, 0xFF000000.toInt(), null, 0f, 0)).copy(v = value)
                }
            }
            val wrap = n.bg != 0 || n.bw > 0f || n.shadow != null || kids.isNotEmpty() || n.k == "scroll"
            if (!wrap) { n.k = "text"; n.tx = info; return n }
            n.c.add(DomNode(idOf(ctx, sn.id, 1), "text").frame(0f, 0f, n.w, n.h).also { it.tx = info })
        }
        for (c in kids) node(c, pos.x, pos.y, childOffX, childOffY, ctx)?.let { n.c.add(it) }
        return n
    }

    private fun masked(cfg: androidx.compose.ui.semantics.SemanticsConfiguration, o: ReplayIQOptions, editable: Boolean): Boolean {
        cfg.getOrNull(ReplayIQMaskKey)?.let { return it }
        if (editable) return false // inputs never carry their value
        if (cfg.contains(SemanticsProperties.Password)) return true
        if (o.maskAllText && cfg.contains(SemanticsProperties.Text)) return true
        if (o.maskAllImages && cfg.getOrNull(SemanticsProperties.Role) == Role.Image) return true
        return false
    }

    /** First text below [sn] (a text field's label / placeholder) that isn't the field's value. */
    private fun firstText(sn: SemanticsNode, value: String, depth: Int = 0): String? {
        if (depth > 6) return null
        for (c in sn.children) {
            val t = c.config.getOrNull(SemanticsProperties.Text)?.joinToString(" ") { it.text }
            if (!t.isNullOrBlank() && t != value && c.config.getOrNull(ReplayIQMaskKey) != true) return t
            firstText(c, value, depth + 1)?.let { return it }
        }
        return null
    }

    private fun textInfo(cfg: androidx.compose.ui.semantics.SemanticsConfiguration, text: String, ctx: Ctx): DomNode.TextInfo {
        val results = ArrayList<TextLayoutResult>(1)
        try { cfg.getOrNull(SemanticsActions.GetTextLayoutResult)?.action?.invoke(results) } catch (_: Throwable) {}
        val r = results.firstOrNull() ?: return DomNode.TextInfo(text, 14f, 400, false, 0xFF000000.toInt(), null, 0f, 0)
        val style = r.layoutInput.style
        val d = ctx.d
        val sizeDp = if (style.fontSize.isSpecified) with(r.layoutInput.density) { style.fontSize.toPx() } / d else 14f
        val color = if (style.color.isSpecified) style.color.toArgb() else 0xFF000000.toInt()
        val align = when (style.textAlign) {
            TextAlign.Center -> "center"
            TextAlign.Right, TextAlign.End -> "right"
            TextAlign.Justify -> "justify"
            else -> null
        }
        val lh = if (r.lineCount > 0) (r.getLineBottom(0) - r.getLineTop(0)) / d else 0f
        val ml = r.layoutInput.maxLines.takeIf { it in 1..999 } ?: 0
        return DomNode.TextInfo(text, sizeDp, style.fontWeight?.weight ?: 400, style.fontStyle == FontStyle.Italic, color, align, lh, ml)
    }

    // ------------------------------------------------------------------ modifiers (reflection, best-effort)

    private const val CACHE_MS = 1_000L
    private const val TEXT_READS_PER_WALK = 4
    @Volatile private var modifiersBroken = false
    private val fields = HashMap<String, Field?>()

    private fun field(o: Any, name: String): Any? {
        val key = o.javaClass.name + "#" + name
        val f = synchronized(fields) {
            fields.getOrPut(key) {
                try { o.javaClass.getDeclaredField(name).apply { isAccessible = true } } catch (_: Throwable) { null }
            }
        } ?: return null
        return f.get(o)
    }

    private fun modifierStyle(sn: SemanticsNode, n: DomNode, ctx: Ctx) {
        if (modifiersBroken) return
        try {
            val size = Size(sn.size.width.toFloat(), sn.size.height.toFloat())
            for (mi in sn.layoutInfo.getModifierInfo()) {
                val m = mi.modifier
                val name = m.javaClass.name
                when {
                    name.endsWith("BackgroundElement") -> {
                        if (n.bg != 0 || n.grad != null) continue
                        val c = (field(m, "color") as? Long)?.let { Color(it.toULong()) }
                        val brushColor = (field(m, "brush") as? Brush)?.let { (it as? SolidColor)?.value }
                        val col = c?.takeIf { it.isSpecified } ?: brushColor
                        val alpha = (field(m, "alpha") as? Float) ?: 1f
                        if (col != null && col.isSpecified) n.bg = col.copy(alpha = col.alpha * alpha).toArgb()
                        shape(field(m, "shape") as? Shape, size, ctx)?.let { n.radii = it }
                    }
                    name.endsWith("BorderModifierNodeElement") -> {
                        val width = (field(m, "width") as? Float) ?: 0f
                        val col = ((field(m, "brush") as? Brush) as? SolidColor)?.value
                        if (width > 0f && col != null) { n.bw = width; n.bc = col.toArgb() }
                        if (n.radii == null) shape(field(m, "shape") as? Shape, size, ctx)?.let { n.radii = it }
                    }
                    name.endsWith("ShadowGraphicsLayerElement") -> {
                        val e = (field(m, "elevation") as? Float) ?: 0f
                        if (e >= 0.5f) { n.shadow = floatArrayOf(0f, e * 0.5f, e * 1.5f, 0f); n.shadowColor = 0x40000000 }
                        if (n.radii == null) shape(field(m, "shape") as? Shape, size, ctx)?.let { n.radii = it }
                    }
                }
            }
            if (n.shadow != null && n.bg == 0) n.shadow = null
        } catch (t: Throwable) {
            modifiersBroken = t is LinkageError
            Log.d("Compose modifiers not readable: $t")
        }
    }

    private fun shape(s: Shape?, size: Size, ctx: Ctx): FloatArray? {
        s ?: return null
        val o = s.createOutline(size, LayoutDirection.Ltr, ctx.density)
        if (o !is Outline.Rounded) return null
        val r = o.roundRect
        val d = ctx.d
        return floatArrayOf(r.topLeftCornerRadius.x / d, r.topRightCornerRadius.x / d, r.bottomRightCornerRadius.x / d, r.bottomLeftCornerRadius.x / d)
    }
}
