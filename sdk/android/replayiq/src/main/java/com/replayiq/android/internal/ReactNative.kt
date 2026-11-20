package com.replayiq.android.internal

import android.graphics.Color
import android.graphics.drawable.Drawable
import android.text.Layout
import android.view.View
import java.lang.reflect.Method

/**
 * React Native views (Fabric and the old renderer), read by reflection so the SDK has no RN
 * dependency. Every lookup is optional: when a method is missing (another RN version, or renamed
 * by the app's R8) the walker falls back to its generic handling (a rasterised background, an
 * `approx` text from the content description).
 */
internal object ReactNative {
    private const val PKG = "com.facebook.react."

    fun isReactClass(c: Class<*>): Boolean = c.name.startsWith(PKG)

    /** RN's full-window debug overlay (dev builds): draws nothing useful, never a touch target. */
    fun isOverlay(v: View): Boolean = v.javaClass.name.endsWith(".DebuggingOverlay")

    /** A background drawn by RN's own drawable (`CompositeBackgroundDrawable`, `CSSBackgroundDrawable`…). */
    fun handles(d: Drawable?): Boolean = d != null && isReactClass(d.javaClass)

    /** View box drawn by RN's background drawable: sizes dp, colours ARGB. */
    class Box(
        val color: Int,
        val radii: FloatArray?,       // tl, tr, br, bl (dp)
        val bw: Float, val bc: Int,   // uniform border
        val edges: FloatArray?,       // l, t, r, b widths (dp) when the border isn't uniform
        val edgeColors: IntArray?,
        val raster: Boolean,          // background image / gradient: rasterise instead
    )

    // ------------------------------------------------------------------ backgrounds

    private class Api(
        val bgColor: Method, val borderWidth: Method, val borderColor: Method, val borderRadius: Method,
        val edges: Map<String, Any>, val corners: Map<String, Any>, val resolve: Method,
    )

    @Volatile private var api: Api? = null
    @Volatile private var apiFailed = false

    private fun api(cl: ClassLoader?): Api? {
        api?.let { return it }
        if (apiFailed) return null
        return try {
            val app = Class.forName(PKG + "uimanager.BackgroundStyleApplicator", false, cl)
            val edge = Class.forName(PKG + "uimanager.style.LogicalEdge", false, cl)
            val corner = Class.forName(PKG + "uimanager.style.BorderRadiusProp", false, cl)
            val lp = Class.forName(PKG + "uimanager.LengthPercentage", false, cl)
            fun consts(c: Class<*>) = c.enumConstants!!.associateBy { (it as Enum<*>).name }
            Api(
                app.getMethod("getBackgroundColor", View::class.java),
                app.getMethod("getBorderWidth", View::class.java, edge),
                app.getMethod("getBorderColor", View::class.java, edge),
                app.getMethod("getBorderRadius", View::class.java, corner),
                consts(edge), consts(corner),
                lp.getMethod("resolve", Float::class.javaPrimitiveType),
            ).also { api = it }
        } catch (t: Throwable) {
            apiFailed = true
            Log.d("React Native background API unavailable: $t")
            null
        }
    }

    /** [v]'s RN background, or null when it can't be read (the caller rasterises it). */
    fun box(v: View, wDp: Float, hDp: Float): Box? {
        val d = v.background ?: return null
        return try {
            if (d.javaClass.name.endsWith("CompositeBackgroundDrawable")) {
                val a = api(v.javaClass.classLoader) ?: return null
                composite(a, v, d, wDp, hDp)
            } else legacy(d, v.resources.displayMetrics.density, wDp, hDp)
        } catch (t: Throwable) {
            Log.d("React Native background: $t")
            null
        }
    }

    private fun composite(a: Api, v: View, d: Drawable, wDp: Float, hDp: Float): Box {
        val image = getter(d.javaClass, "getBackgroundImage")?.invoke(d)
        val color = (a.bgColor.invoke(null, v) as? Int) ?: 0

        fun width(edge: String): Float? = (a.borderWidth.invoke(null, v, a.edges[edge]) as? Float)?.takeIf { !it.isNaN() }
        fun colorOf(edge: String): Int? = a.borderColor.invoke(null, v, a.edges[edge]) as? Int
        val all = width("ALL") ?: 0f
        // Physical edges first, then logical (LTR: start = left), then all.
        val l = width("LEFT") ?: width("START") ?: all
        val t = width("TOP") ?: all
        val r = width("RIGHT") ?: width("END") ?: all
        val b = width("BOTTOM") ?: all
        val allColor = colorOf("ALL") ?: Color.BLACK
        fun edgeColor(vararg names: String): Int {
            for (n in names) { val c = colorOf(n); if (c != null && c != Color.BLACK) return c }
            return allColor // RN answers black for an edge without its own colour
        }

        fun radius(vararg names: String): Float {
            for (n in names) {
                val lp = a.borderRadius.invoke(null, v, a.corners[n] ?: continue) ?: continue
                return (a.resolve.invoke(lp, wDp) as Float).coerceIn(0f, minOf(wDp, hDp) / 2f)
            }
            return 0f
        }
        val radii = floatArrayOf(
            radius("BORDER_TOP_LEFT_RADIUS", "BORDER_TOP_START_RADIUS", "BORDER_START_START_RADIUS", "BORDER_RADIUS"),
            radius("BORDER_TOP_RIGHT_RADIUS", "BORDER_TOP_END_RADIUS", "BORDER_START_END_RADIUS", "BORDER_RADIUS"),
            radius("BORDER_BOTTOM_RIGHT_RADIUS", "BORDER_BOTTOM_END_RADIUS", "BORDER_END_END_RADIUS", "BORDER_RADIUS"),
            radius("BORDER_BOTTOM_LEFT_RADIUS", "BORDER_BOTTOM_START_RADIUS", "BORDER_END_START_RADIUS", "BORDER_RADIUS"),
        ).takeIf { r -> r.any { it > 0f } }

        val uniform = l == t && t == r && r == b
        return if (uniform || (l <= 0f && t <= 0f && r <= 0f && b <= 0f)) {
            Box(color, radii, if (uniform) l else 0f, edgeColor("ALL"), null, null, image != null)
        } else {
            Box(color, radii, 0f, 0, floatArrayOf(l, t, r, b),
                intArrayOf(edgeColor("LEFT", "START"), edgeColor("TOP"), edgeColor("RIGHT", "END"), edgeColor("BOTTOM")), image != null)
        }
    }

    /** RN < 0.76: `ReactViewBackgroundDrawable` / `CSSBackgroundDrawable` with public getters (px). */
    private fun legacy(d: Drawable, density: Float, wDp: Float, hDp: Float): Box? {
        val c = d.javaClass
        val color = getter(c, "getColor")?.invoke(d) as? Int ?: return null
        val bw = ((getter(c, "getFullBorderWidth")?.invoke(d) as? Float)?.takeIf { !it.isNaN() } ?: 0f) / density
        val bc = try { c.getMethod("getBorderColor", Int::class.javaPrimitiveType).invoke(d, 8) as? Int } catch (_: Throwable) { null } ?: Color.BLACK
        val r = ((getter(c, "getFullBorderRadius")?.invoke(d) as? Float)?.takeIf { !it.isNaN() } ?: 0f) / density
        val rr = r.coerceIn(0f, minOf(wDp, hDp) / 2f)
        return Box(color, if (rr > 0f) floatArrayOf(rr, rr, rr, rr) else null, bw, bc, null, null, false)
    }

    private val getters = HashMap<String, HashMap<Class<*>, Method?>>()

    /** Public no-arg [name] of [c], cached by class (no allocation once cached). */
    private fun getter(c: Class<*>, name: String): Method? = synchronized(getters) {
        val byClass = getters.getOrPut(name) { HashMap() }
        if (byClass.containsKey(c)) byClass[c] else (try { c.getMethod(name) } catch (_: Throwable) { null }).also { byClass[c] = it }
    }

    // ------------------------------------------------------------------ views

    /** `overflow: hidden` on a `ReactViewGroup` (RN clips in its own draw, not with clipChildren). */
    fun clipsChildren(v: View): Boolean = try {
        getter(v.javaClass, "getOverflow")?.invoke(v) == "hidden"
    } catch (_: Throwable) { false }

    fun isLayoutText(v: View): Boolean = v.javaClass.name.endsWith(".PreparedLayoutTextView")

    class LayoutText(val text: CharSequence?, val layout: Layout?, val verticalOffset: Float, val maxLines: Int)

    /** Text of a Fabric `PreparedLayoutTextView`: its precomputed [Layout] when readable. */
    fun layoutText(v: View): LayoutText? = try {
        val c = v.javaClass
        val prepared = getter(c, "getPreparedLayout")?.invoke(v)
        if (prepared != null) {
            val pc = prepared.javaClass
            val layout = getter(pc, "getLayout")?.invoke(prepared) as? Layout
            val voff = getter(pc, "getVerticalOffset")?.invoke(prepared) as? Float ?: 0f
            val ml = getter(pc, "getMaximumNumberOfLines")?.invoke(prepared) as? Int ?: 0
            LayoutText(layout?.text ?: getter(c, "getText")?.invoke(v) as? CharSequence, layout, voff, ml)
        } else (getter(c, "getText")?.invoke(v) as? CharSequence)?.let { LayoutText(it, null, 0f, 0) }
    } catch (_: Throwable) { null }

    private var testIdKey = 0

    /** RN `testID` (stored in the view's `react_test_id` tag). */
    fun testId(v: View): String? {
        if (!isReactClass(v.javaClass)) return null
        if (testIdKey == 0) testIdKey = try {
            v.resources.getIdentifier("react_test_id", "id", v.context.packageName).let { if (it == 0) -1 else it }
        } catch (_: Throwable) { -1 }
        if (testIdKey == -1) return null
        return (v.getTag(testIdKey) as? String)?.takeIf { it.isNotBlank() }
    }
}
