package com.replayiq.android.internal

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Outline
import android.graphics.Rect
import android.graphics.Typeface
import android.os.Build
import android.text.InputType
import android.text.Layout
import android.text.Spanned
import android.text.TextPaint
import android.text.style.CharacterStyle
import android.text.style.MetricAffectingSpan
import android.view.Gravity
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import android.widget.AbsListView
import android.widget.CompoundButton
import android.widget.EditText
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import com.replayiq.android.R
import com.replayiq.android.ReplayIQOptions
import java.lang.reflect.Method
import java.util.concurrent.atomic.AtomicInteger
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Stable Native DOM ids of one View (stored in its tags) for its lifetime. */
internal class NodeIds(val id: Int) {
    private var aux = IntArray(0)
    /** Ids of the Compose nodes under an AndroidComposeView, by (semantics id, slot). */
    var compose: HashMap<Long, Int>? = null
    /** Compose styles read from modifiers / text layouts, refreshed at most every second. */
    var composeCache: ComposeDom.Cache? = null
    /** Text style of a TextView read from its spans, kept while the text object is the same. */
    var textStyle: TextStyle? = null
    /** React Native background read by reflection, reused for the same drawable and size for ≤ 1 s. */
    var rnBox: ReactNative.Box? = null
    var rnKey: Any? = null
    var rnSize = 0L
    var rnAt = 0L
    /** Clip shape (RN overflow, outline radius), reused for the same background and size for ≤ 1 s. */
    var rnClip = false
    var outlineR = -1f
    var shapeKey: Any? = null
    var shapeSize = 0L
    var shapeAt = Long.MIN_VALUE / 2

    /** Id of an extra node drawn for this view: 0 background, 1 content, 2 button, 3 scroll spacer. */
    fun aux(slot: Int): Int {
        if (slot >= aux.size) aux = aux.copyOf(slot + 1)
        if (aux[slot] == 0) aux[slot] = NodeIdAllocator.next()
        return aux[slot]
    }
}

/** Style resolved from a text's spans (RN sets size, colour and weight as spans). */
internal class TextStyle(val key: CharSequence, val baseSize: Float, val baseColor: Int, val baseTf: Typeface?,
                         val size: Float, val color: Int, val tf: Typeface?, val fakeBold: Boolean)

internal object NodeIdAllocator {
    private val counter = AtomicInteger(1)
    fun next(): Int = counter.getAndIncrement()
}

/** An area recorded as pixels: [rect] in window px; [surface] when it's a SurfaceView (copied on its own). */
internal class IslandRef(val id: Int, val rect: Rect, val surface: SurfaceView?)

internal class WalkResult(val root: DomNode, val islands: List<IslandRef>, val islandArea: Float, val screenArea: Float, val nodes: Int)

/**
 * Walks an activity's View tree into [DomNode]s (main thread). Frames are dp relative to the
 * parent (scroll children: to the scroll content). Never reads input values; masked views become
 * `mask` nodes with nothing of their content.
 */
internal class ViewWalker(
    private val options: ReplayIQOptions,
    private val inspector: ViewInspector,
    private val images: DrawableAssets,
    private val islandHash: (Int) -> String?,
) {
    internal var d = 1f
        private set
    private val islands = ArrayList<IslandRef>()
    private var islandArea = 0f
    private var nodes = 0
    private val loc = IntArray(2)
    private val tmp = Rect()
    private val matrixValues = FloatArray(9)
    private val outline = Outline()

    private var walkStart = 0L

    /** Set during a walk when some content was left for the next walk (to stay within budget). */
    var incomplete = false

    fun walk(decor: View): WalkResult {
        d = decor.resources.displayMetrics.density
        incomplete = false
        walkStart = android.os.SystemClock.uptimeMillis()
        islands.clear(); islandArea = 0f; nodes = 0
        images.newWalk()
        val root = node(decor, 0f, 0f) ?: DomNode(idsOf(decor).id, "view").frame(0f, 0f, decor.width / d, decor.height / d)
        root.x = 0f; root.y = 0f
        return WalkResult(root, ArrayList(islands), islandArea, (decor.width / d) * (decor.height / d), nodes)
    }

    fun idsOf(v: View): NodeIds =
        (v.getTag(R.id.replayiq_node) as? NodeIds) ?: NodeIds(NodeIdAllocator.next()).also { v.setTag(R.id.replayiq_node, it) }

    /** [rect] window px; [visible] its on-screen part (global px). */
    internal fun addIsland(id: Int, rect: Rect, visible: Rect, surface: SurfaceView?) {
        islands.add(IslandRef(id, rect, surface))
        islandArea += (visible.width() / d) * (visible.height() / d)
    }

    internal fun islandHashOf(id: Int) = islandHash(id)

    // ------------------------------------------------------------------ one view

    private fun node(v: View, fx: Float, fy: Float): DomNode? {
        if (v.visibility != View.VISIBLE || v.width <= 0 || v.height <= 0) return null
        val kind = classify(v)
        if (kind == K_SKIP) return null
        nodes++
        val ids = idsOf(v)
        val w = v.width
        val h = v.height
        val top = DomNode(ids.id, "view").frame(fx / d, fy / d, w / d, h / d)
        common(top, v, ids)

        if (kind == K_MASK) {
            top.k = "mask"
            if (isClickableOrInput(v)) top.role = inspector.role(v)
            return top
        }
        if (kind == K_ISLAND) {
            top.k = "island"
            island(top, v)
            return top
        }

        var edges: List<DomNode>? = null
        val rn = if (ReactNative.handles(v.background)) rnBox(ids, v, w, h) else null
        val bg = if (rn != null && !rn.raster) {
            if (rn.edges != null) edges = edgeNodes(ids, rn, w / d, h / d)
            Drawables.Bg(Rect(0, 0, w, h), rn.color, rn.radii?.let { r -> FloatArray(4) { r[it] * d } }, rn.bw * d, rn.bc, null, false, null)
                .takeIf { rn.color ushr 24 != 0 || rn.bw > 0f || rn.radii != null || v.z >= d * 0.5f }
        } else Drawables.describe(v.background, w, h)
        var bgChild: DomNode? = null
        if (bg != null) {
            if (bg.raster == null && full(bg.rect, w, h)) applyBg(top, bg, v) else bgChild = bgNode(ids, bg, v)
        }
        if (isClickableOrInput(v)) {
            top.role = inspector.role(v)
            top.label = inspector.label(v)
        }

        when (kind) {
            K_TEXT, K_INPUT, K_IMAGE -> {
                val content = when (kind) {
                    K_INPUT -> inputNode(ids, v as EditText)
                    K_TEXT -> textNode(ids, v as TextView)
                    else -> imageNode(ids, v as ImageView)
                }
                val button = (v as? CompoundButton)?.let { buttonNode(ids, it) }
                if (content != null && bgChild == null && button == null && content.x == 0f && content.y == 0f &&
                    abs(content.w - top.w) < 0.5f && abs(content.h - top.h) < 0.5f) {
                    // One node: the view is its content.
                    top.k = content.k; top.tx = content.tx; top.img = content.img; top.fit = content.fit; top.input = content.input
                } else {
                    bgChild?.let { top.c.add(it) }
                    edges?.let { top.c.addAll(it) }
                    button?.let { top.c.add(it) }
                    content?.let { top.c.add(it) }
                }
            }
            K_COMPOSE -> {
                bgChild?.let { top.c.add(it) }
                ComposeDom.append(v, top, this, options)
            }
            K_LTEXT -> {
                bgChild?.let { top.c.add(it) }
                edges?.let { top.c.addAll(it) }
                layoutTextNode(ids, v)?.let { top.c.add(it) }
                if (v is ViewGroup) children(v, top, false, ids) // inline views
            }
            else -> {
                bgChild?.let { top.c.add(it) }
                edges?.let { top.c.addAll(it) }
                if (v is ViewGroup) children(v, top, kind == K_SCROLL, ids)
            }
        }
        return top
    }

    private fun rnBox(ids: NodeIds, v: View, w: Int, h: Int): ReactNative.Box? {
        val key = v.background
        val size = (w.toLong() shl 32) or h.toLong()
        if (ids.rnKey === key && ids.rnSize == size && walkStart - ids.rnAt < RN_REFRESH_MS) return ids.rnBox
        val b = ReactNative.box(v, w / d, h / d)
        ids.rnBox = b; ids.rnKey = key; ids.rnSize = size; ids.rnAt = walkStart
        return b
    }

    /** Lines for a border whose edges differ (RN `borderBottomWidth`…): slots 4–7. */
    private fun edgeNodes(ids: NodeIds, b: ReactNative.Box, w: Float, h: Float): List<DomNode> {
        val e = b.edges!!
        val cols = b.edgeColors!!
        val out = ArrayList<DomNode>(4)
        fun line(i: Int, x: Float, y: Float, lw: Float, lh: Float) {
            if (e[i] <= 0f || cols[i] ushr 24 == 0) return
            out.add(DomNode(ids.aux(4 + i), "view").frame(x, y, lw, lh).also { it.bg = cols[i] })
        }
        line(0, 0f, 0f, e[0], h)
        line(1, 0f, 0f, w, e[1])
        line(2, w - e[2], 0f, e[2], h)
        line(3, 0f, h - e[3], w, e[3])
        return out
    }

    private fun isClickableOrInput(v: View) = v.isClickable || v is EditText

    private fun children(g: ViewGroup, parent: DomNode, scroll: Boolean, ids: NodeIds) {
        val w = g.width
        val h = g.height
        var offX = 0f
        var offY = 0f
        if (scroll) {
            parent.k = "scroll"
            val extentX: Float
            val extentY: Float
            if (scrollFamily(g) == FAMILY_SCROLLVIEW) {
                parent.so = floatArrayOf(g.scrollX / d, g.scrollY / d)
                extentX = max(range(g, false).toFloat(), (g.scrollX + w).toFloat())
                extentY = max(range(g, true).toFloat(), (g.scrollY + h).toFloat())
            } else {
                // RecyclerView / ListView move their children instead of scrolling: put the children
                // back in content coordinates using the (estimated) scroll offset.
                offX = offset(g, false).toFloat()
                offY = offset(g, true).toFloat()
                parent.so = floatArrayOf(offX / d, offY / d)
                extentX = max(range(g, false).toFloat(), offX + w)
                extentY = max(range(g, true).toFloat(), offY + h)
            }
            parent.selector = inspector.stableLabel(g)?.let { ViewInspector.selector("scroll", it) } ?: "scroll"
            if (parent.clip) parent.clip = false // scroll nodes clip anyway
            parent.c.add(DomNode(ids.aux(3), "view").frame(max(0f, extentX / d - 1f), max(0f, extentY / d - 1f), 1f, 1f))
        }
        val borderDp = parent.bw
        val clips = !scroll && g.clipChildren
        for (i in 0 until g.childCount) {
            val c = g.getChildAt(i) ?: continue
            val cx: Float
            val cy: Float
            if (scroll) { cx = c.left + offX; cy = c.top + offY } else { cx = (c.left - g.scrollX).toFloat(); cy = (c.top - g.scrollY).toFloat() }
            if (clips) {
                val l = cx + c.translationX
                val t = cy + c.translationY
                if (l + c.width <= 0 || l >= w || t + c.height <= 0 || t >= h) continue
            }
            val n = node(c, cx, cy) ?: continue
            if (borderDp > 0f) { n.x -= borderDp; n.y -= borderDp }
            parent.c.add(n)
        }
    }

    // ------------------------------------------------------------------ style

    private fun common(n: DomNode, v: View, ids: NodeIds) {
        if (v.alpha < 1f) n.alpha = v.alpha
        if (v.translationX != 0f || v.translationY != 0f || v.scaleX != 1f || v.scaleY != 1f || v.rotation != 0f) {
            val m: Matrix = v.matrix
            if (!m.isIdentity) {
                m.getValues(matrixValues)
                val a = matrixValues[Matrix.MSCALE_X]; val b = matrixValues[Matrix.MSKEW_Y]
                val c = matrixValues[Matrix.MSKEW_X]; val dd = matrixValues[Matrix.MSCALE_Y]
                val cx = v.width / 2f; val cy = v.height / 2f
                // Android's matrix maps view-local px; the DOM's transform is about the centre.
                val tx = a * cx + c * cy + matrixValues[Matrix.MTRANS_X] - cx
                val ty = b * cx + dd * cy + matrixValues[Matrix.MTRANS_Y] - cy
                n.t = floatArrayOf(a, b, c, dd, tx / d, ty / d)
            }
        }
        // Reflection and getOutline (React Native's builds a Path) are cached per view for ≤ 1 s.
        val fresh = walkStart - ids.shapeAt < RN_REFRESH_MS && ids.shapeKey === v.background && ids.shapeSize == ((v.width.toLong() shl 32) or v.height.toLong())
        if (!fresh) {
            ids.rnClip = v is ViewGroup && ReactNative.isReactClass(v.javaClass) && ReactNative.clipsChildren(v)
            ids.outlineR = -1f
            ids.shapeAt = walkStart; ids.shapeKey = v.background; ids.shapeSize = (v.width.toLong() shl 32) or v.height.toLong()
        }
        if (v is ViewGroup && v.childCount > 0 && (v.clipChildren || ids.rnClip)) n.clip = true
        if (v.clipToOutline) {
            n.clip = true
            if (ids.outlineR < 0f) {
                ids.outlineR = 0f
                if (Build.VERSION.SDK_INT >= 24) try {
                    outline.setEmpty()
                    v.outlineProvider?.getOutline(v, outline)
                    ids.outlineR = max(0f, outline.radius / d)
                } catch (_: Throwable) {}
            }
            val r = ids.outlineR
            if (r > 0f) n.radii = floatArrayOf(r, r, r, r)
        }
    }

    private fun full(r: Rect, w: Int, h: Int) = r.left <= 1 && r.top <= 1 && abs(r.right - w) <= 1 && abs(r.bottom - h) <= 1

    private fun applyBg(n: DomNode, bg: Drawables.Bg, v: View) {
        n.bg = bg.color
        n.grad = bg.grad
        if (bg.oval) { val r = min(bg.rect.width(), bg.rect.height()) / 2f / d; n.radii = floatArrayOf(r, r, r, r) }
        else bg.radii?.let { r -> n.radii = floatArrayOf(r[0] / d, r[1] / d, r[2] / d, r[3] / d) }
        if (bg.strokeW > 0f) { n.bw = bg.strokeW / d; n.bc = bg.strokeC }
        val z = v.z
        if (z >= d * 0.5f && v.outlineProvider != null) {
            val zd = z / d
            n.shadow = floatArrayOf(0f, zd * 0.5f, zd * 1.5f, 0f)
            n.shadowColor = 0x40000000
        }
    }

    private fun bgNode(ids: NodeIds, bg: Drawables.Bg, v: View): DomNode {
        val r = bg.rect
        val n = DomNode(ids.aux(0), "view").frame(r.left / d, r.top / d, r.width() / d, r.height() / d)
        val raster = bg.raster
        if (raster != null) {
            n.k = "image"
            n.fit = "fill"
            n.img = images.hashFor(raster, r.width(), r.height(), dp(r.width()), dp(r.height()))
        } else applyBg(n, bg, v)
        return n
    }

    private fun dp(px: Int) = max(1, ceil(px / d).toInt())

    // ------------------------------------------------------------------ content

    private fun textNode(ids: NodeIds, tv: TextView): DomNode? {
        var text = displayedText(tv)
        var color = tv.currentTextColor
        if (text.isEmpty()) {
            val hint = tv.hint?.toString().orEmpty()
            if (hint.isEmpty()) return null
            text = hint; color = tv.currentHintTextColor
        }
        val r = textRect(tv)
        val n = DomNode(ids.aux(1), "text").frame(r.left / d, r.top / d, r.width() / d, r.height() / d)
        n.tx = textInfo(tv, text, color, ids)
        return n
    }

    /** A view that draws a precomputed [android.text.Layout] (Fabric `PreparedLayoutTextView`). */
    private fun layoutTextNode(ids: NodeIds, v: View): DomNode? {
        val lt = ReactNative.layoutText(v)
        val layout = lt?.layout
        val raw = lt?.text
        if (layout == null || raw.isNullOrEmpty()) {
            // Not readable: the accessibility text, marked as an estimate.
            val cd = (raw ?: v.contentDescription)?.toString()?.takeIf { it.isNotBlank() } ?: return null
            val n = DomNode(ids.aux(1), "text").frame(v.paddingLeft / d, v.paddingTop / d,
                max(1, v.width - v.paddingLeft - v.paddingRight) / d, max(1, v.height - v.paddingTop - v.paddingBottom) / d)
            n.tx = DomNode.TextInfo(cd, 14f, 400, false, Color.BLACK, null, 0f, 0)
            n.approx = true
            return n
        }
        val top = v.paddingTop + lt.verticalOffset
        val n = DomNode(ids.aux(1), "text").frame(v.paddingLeft / d, top / d, layout.width / d,
            min(layout.height.toFloat(), v.height - top) .coerceAtLeast(1f) / d)
        val st = style(ids, raw, layout.paint.textSize, layout.paint.color, layout.paint.typeface, layout.paint)
        val align = when (layout.getParagraphAlignment(0)) {
            Layout.Alignment.ALIGN_CENTER -> "center"
            Layout.Alignment.ALIGN_OPPOSITE -> if (layout.getParagraphDirection(0) == Layout.DIR_RIGHT_TO_LEFT) "left" else "right"
            else -> null
        }
        val lh = if (layout.lineCount > 0) (layout.getLineBottom(0) - layout.getLineTop(0)) / d else 0f
        n.tx = DomNode.TextInfo(clipToLayout(raw.toString(), layout), st.size / d, weightOf(st.tf, st.fakeBold), st.tf?.isItalic == true,
            st.color, align, lh, lt.maxLines.takeIf { it in 1..999 } ?: 0, monoOf(st.tf))
        return n
    }

    private fun displayedText(tv: TextView): String {
        val raw = tv.text ?: return ""
        val s = try { tv.transformationMethod?.getTransformation(raw, tv)?.toString() } catch (_: Throwable) { null } ?: raw.toString()
        return clipToLayout(s, tv.layout)
    }

    /** [text] as [layout] shows it: cut at the ellipsis or at the last line. */
    private fun clipToLayout(text: String, layout: Layout?): String {
        var s = text
        if (layout != null && layout.lineCount > 0) {
            val last = layout.lineCount - 1
            if (layout.getEllipsisCount(last) > 0) {
                val cut = layout.getLineStart(last) + layout.getEllipsisStart(last)
                if (cut in 0..s.length) s = s.substring(0, cut) + "…"
            } else if (layout.getLineEnd(last) < s.length) {
                s = s.substring(0, layout.getLineEnd(last)) // maxLines without ellipsis
            }
        }
        return s
    }

    private val spanPaint = TextPaint()

    /**
     * Size / colour / typeface of [text] at its first character, after its spans (RN, and any
     * app using `AbsoluteSizeSpan` / `StyleSpan`…), cached while the text object is the same.
     */
    private fun style(ids: NodeIds, text: CharSequence, size: Float, color: Int, tf: Typeface?, base: TextPaint): TextStyle {
        ids.textStyle?.let { c -> if (c.key === text && c.baseSize == size && c.baseColor == color && c.baseTf === tf) return c }
        var outSize = size; var outColor = color; var outTf = tf; var fake = base.isFakeBoldText
        if (text is Spanned && text.isNotEmpty()) {
            val spans = text.getSpans(0, 1, CharacterStyle::class.java)
            if (spans.isNotEmpty()) {
                spanPaint.set(base)
                spanPaint.textSize = size; spanPaint.color = color; spanPaint.typeface = tf
                for (sp in spans) try {
                    if (sp is MetricAffectingSpan) sp.updateMeasureState(spanPaint)
                    sp.updateDrawState(spanPaint)
                } catch (_: Throwable) {}
                outSize = spanPaint.textSize; outColor = spanPaint.color; outTf = spanPaint.typeface; fake = spanPaint.isFakeBoldText
            }
        }
        return TextStyle(text, size, color, tf, outSize, outColor, outTf, fake).also { ids.textStyle = it }
    }

    private fun weightOf(tf: Typeface?, fakeBold: Boolean): Int {
        val bold = fakeBold || (tf != null && tf.style and Typeface.BOLD != 0)
        return when {
            Build.VERSION.SDK_INT >= 28 && tf != null -> if (bold && tf.weight < 600) 700 else tf.weight
            bold -> 700
            else -> 400
        }
    }

    private fun monoOf(tf: Typeface?) = if (tf != null && tf == Typeface.MONOSPACE) "monospace" else null

    private fun textInfo(tv: TextView, text: String, color: Int, ids: NodeIds): DomNode.TextInfo {
        val raw = tv.text
        val st = if (raw != null && raw.isNotEmpty() && color == tv.currentTextColor) style(ids, raw, tv.textSize, color, tv.typeface, tv.paint) else null
        val tf: Typeface? = st?.tf ?: tv.typeface
        val weight = weightOf(tf, st?.fakeBold ?: tv.paint.isFakeBoldText)
        val size = st?.size ?: tv.textSize
        val col = st?.color ?: color
        val align = when (tv.textAlignment) {
            View.TEXT_ALIGNMENT_CENTER -> "center"
            View.TEXT_ALIGNMENT_VIEW_END, View.TEXT_ALIGNMENT_TEXT_END -> if (tv.layoutDirection == View.LAYOUT_DIRECTION_RTL) "left" else "right"
            else -> when (Gravity.getAbsoluteGravity(tv.gravity, tv.layoutDirection) and Gravity.HORIZONTAL_GRAVITY_MASK) {
                Gravity.CENTER_HORIZONTAL -> "center"
                Gravity.RIGHT -> "right"
                else -> null
            }
        }
        val layout = tv.layout
        val lh = if (layout != null && layout.lineCount > 0) (layout.getLineBottom(0) - layout.getLineTop(0)) / d else 0f
        val maxLines = tv.maxLines.takeIf { it in 1..999 } ?: 0
        return DomNode.TextInfo(text, size / d, weight, tf?.isItalic == true, col, align, lh, maxLines, monoOf(tf))
    }

    /** Where the text is drawn inside [tv] (px): inside its compound padding, at its vertical gravity. */
    private fun textRect(tv: TextView): Rect {
        val left = tv.compoundPaddingLeft
        val right = tv.width - tv.compoundPaddingRight
        val top = tv.extendedPaddingTop
        val box = tv.height - top - tv.extendedPaddingBottom
        val textH = min(tv.layout?.height ?: box, box).coerceAtLeast(0)
        val voff = when (tv.gravity and Gravity.VERTICAL_GRAVITY_MASK) {
            Gravity.CENTER_VERTICAL -> (box - textH) / 2
            Gravity.BOTTOM -> box - textH
            else -> 0
        }.coerceAtLeast(0)
        return Rect(left, top + voff, max(left + 1, right), top + voff + max(1, textH))
    }

    private fun inputNode(ids: NodeIds, et: EditText): DomNode {
        val n = DomNode(ids.aux(1), "input").frame(0f, 0f, et.width / d, et.height / d)
        val cls = et.inputType and InputType.TYPE_MASK_CLASS
        val variation = et.inputType and InputType.TYPE_MASK_VARIATION
        val type = when {
            ViewInspector.isPassword(et) -> "password"
            cls == InputType.TYPE_CLASS_NUMBER -> "number"
            cls == InputType.TYPE_CLASS_PHONE -> "phone"
            cls == InputType.TYPE_CLASS_TEXT && (variation == InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS ||
                variation == InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS) -> "email"
            else -> "text"
        }
        // Never the value: only its length (drawn as dots) and the hint.
        n.input = DomNode.InputInfo(type, et.hint?.toString()?.takeIf { it.isNotBlank() }?.let { ViewInspector.clean(it) }, et.text?.length ?: 0, et.isFocused)
        return n
    }

    private fun imageNode(ids: NodeIds, iv: ImageView): DomNode? {
        val dr = iv.drawable ?: return null
        val cw = iv.width - iv.paddingLeft - iv.paddingRight
        val ch = iv.height - iv.paddingTop - iv.paddingBottom
        if (cw <= 0 || ch <= 0) return null
        val n = DomNode(ids.aux(1), "image").frame(iv.paddingLeft / d, iv.paddingTop / d, cw / d, ch / d)
        val iw = dr.intrinsicWidth
        val ih = dr.intrinsicHeight
        val scaleType = iv.scaleType
        n.fit = when (scaleType) {
            ImageView.ScaleType.CENTER_CROP -> "cover"
            ImageView.ScaleType.FIT_CENTER, ImageView.ScaleType.CENTER_INSIDE, ImageView.ScaleType.FIT_START, ImageView.ScaleType.FIT_END -> "contain"
            ImageView.ScaleType.CENTER -> "none"
            else -> "fill"
        }
        if (iw <= 0 || ih <= 0) {
            n.fit = "fill"
            n.img = images.hashFor(dr, cw, ch, dp(cw), dp(ch))
        } else {
            // ≤ 1x: one bitmap pixel per dp of its size on screen.
            val s = if (scaleType == ImageView.ScaleType.CENTER) 1f / d else min(1f, max(cw.toFloat() / iw, ch.toFloat() / ih) / d)
            n.img = images.hashFor(dr, iw, ih, max(1, (iw * s).roundToInt()), max(1, (ih * s).roundToInt()))
        }
        return n
    }

    private fun buttonNode(ids: NodeIds, b: CompoundButton): DomNode? {
        if (Build.VERSION.SDK_INT < 23) return null
        val dr = b.buttonDrawable ?: return null
        val r = dr.bounds
        if (r.isEmpty) return null
        val n = DomNode(ids.aux(2), "image").frame(r.left / d, r.top / d, r.width() / d, r.height() / d)
        n.fit = "fill"
        n.img = images.hashFor(dr, r.width(), r.height(), dp(r.width()), dp(r.height()))
        return n
    }

    private fun island(n: DomNode, v: View) {
        v.getLocationInWindow(loc)
        val rect = Rect(loc[0], loc[1], loc[0] + v.width, loc[1] + v.height)
        if (v.getGlobalVisibleRect(tmp)) addIsland(n.id, rect, Rect(tmp), v as? SurfaceView)
        val hash = islandHash(n.id)
        if (hash != null) { n.img = hash; n.fit = "fill" } else n.hint = hintFor(v)
    }

    // ------------------------------------------------------------------ classification

    private fun classify(v: View): Int {
        val explicit = inspector.explicit(v)
        val masked = when {
            explicit == true -> true
            v is EditText -> false // inputs never carry their value
            v is TextView && ViewInspector.isPassword(v) -> true
            explicit == false -> false
            else -> inspector.isMasked(v)
        }
        if (masked) return K_MASK
        if (ComposeSupport.isComposeView(v)) return K_COMPOSE
        val cls = v.javaClass
        val cached = kinds[cls]
        if (cached != null) return cached
        val k = when {
            ReactNative.isOverlay(v) -> K_SKIP
            ReactNative.isLayoutText(v) -> K_LTEXT
            v is SurfaceView || v is TextureView || v is WebView || v is ProgressBar -> K_ISLAND
            islandByName(cls) -> K_ISLAND
            v is Switch || Drawables.isA(cls, "androidx.appcompat.widget.SwitchCompat") -> K_ISLAND
            v is EditText -> K_INPUT
            v is TextView -> K_TEXT
            v is ImageView -> K_IMAGE
            v is ViewGroup -> if (scrollFamily(v) != 0) K_SCROLL else K_VIEW
            drawsItself(cls) -> K_ISLAND
            else -> K_VIEW
        }
        kinds[cls] = k
        return k
    }

    private fun islandByName(cls: Class<*>): Boolean {
        var c: Class<*>? = cls
        while (c != null && c != View::class.java) {
            val n = c.name
            if (n.endsWith(".MapView") || n.endsWith("PlayerView") || n.endsWith(".PreviewView") || n.contains("LottieAnimationView")) return true
            c = c.superclass
        }
        return false
    }

    /** A leaf view whose class (below View) overrides onDraw: custom drawing we can't describe. */
    private fun drawsItself(cls: Class<*>): Boolean {
        var c: Class<*>? = cls
        while (c != null && c != View::class.java) {
            try { c.getDeclaredMethod("onDraw", Canvas::class.java); return true } catch (_: NoSuchMethodException) {} catch (_: Throwable) { return false }
            c = c.superclass
        }
        return false
    }

    private fun hintFor(v: View): String {
        val n = v.javaClass.name
        return when {
            v is WebView -> "web"
            n.contains("MapView") -> "map"
            n.contains("Video") || n.contains("Player") -> "video"
            n.contains("Preview") || n.contains("Camera") -> "camera"
            else -> "unknown"
        }
    }

    private fun scrollFamily(v: View): Int = families.getOrPut(v.javaClass) {
        when {
            v is ScrollView || v is HorizontalScrollView || Drawables.isA(v.javaClass, "androidx.core.widget.NestedScrollView") -> FAMILY_SCROLLVIEW
            v is AbsListView || Drawables.isA(v.javaClass, "androidx.recyclerview.widget.RecyclerView") -> FAMILY_LIST
            else -> 0
        }
    }

    private fun offset(v: View, vertical: Boolean): Int = invoke(if (vertical) vOffset else hOffset, v)
    private fun range(v: View, vertical: Boolean): Int = invoke(if (vertical) vRange else hRange, v)

    private fun invoke(m: Method?, v: View): Int = try { (m?.invoke(v) as? Int) ?: 0 } catch (_: Throwable) { 0 }

    private val kinds = HashMap<Class<*>, Int>()
    private val families = HashMap<Class<*>, Int>()

    private companion object {
        const val K_VIEW = 0
        const val K_TEXT = 1
        const val K_INPUT = 2
        const val K_IMAGE = 3
        const val K_SCROLL = 4
        const val K_MASK = 5
        const val K_ISLAND = 6
        const val K_COMPOSE = 7
        const val RN_REFRESH_MS = 1000L
        const val K_SKIP = 8
        const val K_LTEXT = 9
        const val FAMILY_SCROLLVIEW = 1
        const val FAMILY_LIST = 2

        private fun viewMethod(name: String): Method? = try {
            View::class.java.getDeclaredMethod(name).apply { isAccessible = true }
        } catch (_: Throwable) { null }

        val vOffset = viewMethod("computeVerticalScrollOffset")
        val hOffset = viewMethod("computeHorizontalScrollOffset")
        val vRange = viewMethod("computeVerticalScrollRange")
        val hRange = viewMethod("computeHorizontalScrollRange")
    }
}
