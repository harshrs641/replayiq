package com.replayiq.android.internal

import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Outline
import android.graphics.Rect
import android.graphics.Typeface
import android.os.Build
import android.text.InputType
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

    /** Id of an extra node drawn for this view: 0 background, 1 content, 2 button, 3 scroll spacer. */
    fun aux(slot: Int): Int {
        if (slot >= aux.size) aux = aux.copyOf(slot + 1)
        if (aux[slot] == 0) aux[slot] = NodeIdAllocator.next()
        return aux[slot]
    }
}

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

    /** Set during a walk when some content was left for the next walk (to stay within budget). */
    var incomplete = false

    fun walk(decor: View): WalkResult {
        d = decor.resources.displayMetrics.density
        incomplete = false
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
        nodes++
        val ids = idsOf(v)
        val w = v.width
        val h = v.height
        val kind = classify(v)
        val top = DomNode(ids.id, "view").frame(fx / d, fy / d, w / d, h / d)
        common(top, v)

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

        val bg = Drawables.describe(v.background, w, h)
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
                    button?.let { top.c.add(it) }
                    content?.let { top.c.add(it) }
                }
            }
            K_COMPOSE -> {
                bgChild?.let { top.c.add(it) }
                ComposeDom.append(v, top, this, options)
            }
            else -> {
                bgChild?.let { top.c.add(it) }
                if (v is ViewGroup) children(v, top, kind == K_SCROLL, ids)
            }
        }
        return top
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
            parent.selector = ViewInspector.selector("scroll", inspector.label(g))
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

    private fun common(n: DomNode, v: View) {
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
        if (v is ViewGroup && v.clipChildren && v.childCount > 0) n.clip = true
        if (v.clipToOutline) {
            n.clip = true
            if (Build.VERSION.SDK_INT >= 24) try {
                outline.setEmpty()
                v.outlineProvider?.getOutline(v, outline)
                val r = outline.radius / d
                if (r > 0f) n.radii = floatArrayOf(r, r, r, r)
            } catch (_: Throwable) {}
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
        n.tx = textInfo(tv, text, color)
        return n
    }

    private fun displayedText(tv: TextView): String {
        val raw = tv.text ?: return ""
        var s = try { tv.transformationMethod?.getTransformation(raw, tv)?.toString() } catch (_: Throwable) { null } ?: raw.toString()
        val layout = tv.layout
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

    private fun textInfo(tv: TextView, text: String, color: Int): DomNode.TextInfo {
        val tf: Typeface? = tv.typeface
        val weight = when {
            Build.VERSION.SDK_INT >= 28 && tf != null -> if (tf.isBold && tf.weight < 600) 700 else tf.weight
            tf?.isBold == true || tv.paint.isFakeBoldText -> 700
            else -> 400
        }
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
        val font = if (tf != null && tf == Typeface.MONOSPACE) "monospace" else null
        return DomNode.TextInfo(text, tv.textSize / d, weight, tf?.isItalic == true, color, align, lh, maxLines, font)
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
