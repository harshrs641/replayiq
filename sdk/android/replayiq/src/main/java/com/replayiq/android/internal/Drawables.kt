package com.replayiq.android.internal

import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import android.graphics.drawable.DrawableContainer
import android.graphics.drawable.DrawableWrapper
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.InsetDrawable
import android.graphics.drawable.LayerDrawable
import android.graphics.drawable.RippleDrawable
import android.os.Build
import java.lang.reflect.Field
import java.lang.reflect.Method

/**
 * Describes view backgrounds as Native DOM styles where possible (colours, shapes, gradients,
 * strokes), and says when a drawable has to be rasterised instead. Main thread only.
 */
internal object Drawables {

    /** A background: a style at [rect] (view px), or [raster] = draw this drawable as an image. */
    class Bg(val rect: Rect, val color: Int, val radii: FloatArray?, val strokeW: Float, val strokeC: Int,
             val grad: DomNode.Grad?, val oval: Boolean, val raster: Drawable?)

    /** [d] drawn over a view of [w]x[h] px. Null when it draws nothing. */
    fun describe(d: Drawable?, w: Int, h: Int): Bg? {
        if (d == null || w <= 0 || h <= 0) return null
        return try { unwrap(d, w, h, 0) } catch (t: Throwable) { Log.d("background: ${t.javaClass.simpleName}"); rasterBg(d, w, h) }
    }

    private fun bounds(d: Drawable, w: Int, h: Int): Rect {
        val b = d.bounds
        return if (b.isEmpty) Rect(0, 0, w, h) else Rect(b)
    }

    private fun rasterBg(d: Drawable, w: Int, h: Int) = Bg(bounds(d, w, h), 0, null, 0f, 0, null, false, d)

    private fun unwrap(d: Drawable, w: Int, h: Int, depth: Int): Bg? {
        if (depth > 6) return rasterBg(d, w, h)
        if (!d.isVisible || d.alpha == 0) return null
        when (d) {
            is ColorDrawable -> {
                val c = d.color
                return if (c ushr 24 == 0) null else Bg(bounds(d, w, h), c, null, 0f, 0, null, false, null)
            }
            is GradientDrawable -> return gradient(d, w, h)
            is RippleDrawable -> {
                // The ripple itself is a touch effect: describe the content layer (not the mask).
                var content: Drawable? = null
                for (i in 0 until d.numberOfLayers) {
                    if (d.getId(i) == android.R.id.mask) continue
                    if (content != null) return rasterBg(d, w, h)
                    content = d.getDrawable(i)
                }
                return content?.let { unwrap(it, w, h, depth + 1) }
            }
            is LayerDrawable -> {
                if (d.numberOfLayers == 1) return d.getDrawable(0)?.let { unwrap(it, w, h, depth + 1) }
                return rasterBg(d, w, h)
            }
            is InsetDrawable -> return d.drawable?.let { unwrap(it, w, h, depth + 1) }
            is DrawableContainer -> return d.current?.let { if (it === d) rasterBg(d, w, h) else unwrap(it, w, h, depth + 1) }
        }
        if (Build.VERSION.SDK_INT >= 23 && d is DrawableWrapper) return d.drawable?.let { unwrap(it, w, h, depth + 1) }
        materialShape(d, w, h)?.let { return it }
        return rasterBg(d, w, h)
    }

    private fun gradient(d: GradientDrawable, w: Int, h: Int): Bg? {
        if (Build.VERSION.SDK_INT < 24) return rasterBg(d, w, h)
        val r = bounds(d, w, h)
        val state = d.state
        val shape = d.shape
        if (shape != GradientDrawable.RECTANGLE && shape != GradientDrawable.OVAL) return rasterBg(d, w, h)
        val oval = shape == GradientDrawable.OVAL
        val alpha = d.alpha / 255f
        var color = 0
        var grad: DomNode.Grad? = null
        var sw = 0f
        var sc = 0
        val colors = d.colors
        if (colors != null && colors.size >= 2) {
            val radial = d.gradientType == GradientDrawable.RADIAL_GRADIENT
            if (d.gradientType == GradientDrawable.SWEEP_GRADIENT) return rasterBg(d, w, h)
            grad = DomNode.Grad(radial, angle(d.orientation), IntArray(colors.size) { withAlpha(colors[it], alpha) },
                FloatArray(colors.size) { it.toFloat() / (colors.size - 1) })
            stroke(d, state).let { sw = it.first; sc = withAlpha(it.second, alpha) }
        } else {
            // Solid: sample the drawn pixels, which include android:tint / setTint and the stroke
            // (neither has a public getter).
            val s = sample(d, r) ?: return rasterBg(d, w, h)
            color = s.fill; sw = s.strokeW; sc = s.strokeC
        }
        val radii: FloatArray? = if (oval) null else d.cornerRadii?.let { a -> floatArrayOf(a[0], a[2], a[4], a[6]) }
            ?: d.cornerRadius.takeIf { it > 0f }?.let { floatArrayOf(it, it, it, it) }
        if (color ushr 24 == 0 && grad == null && (sw <= 0f || sc ushr 24 == 0)) return null
        return Bg(r, color, radii, sw, sc, grad, oval, null)
    }

    private data class SampleKey(val identity: Int, val state: Int, val w: Int, val h: Int, val alpha: Int, val level: Int)
    private class Sample(val fill: Int, val strokeW: Float, val strokeC: Int)
    private val samples = object : LinkedHashMap<SampleKey, Sample>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<SampleKey, Sample>?) = size > 256
    }
    private var row: Bitmap? = null

    /** Draws the middle pixel row of [d] at [r]'s size: fill = centre pixel, stroke = edge pixels up to the fill. */
    private fun sample(d: GradientDrawable, r: Rect): Sample? {
        val w = r.width(); val h = r.height()
        if (w < 3 || h < 3) return null
        val key = SampleKey(System.identityHashCode(d.constantState ?: d), d.state.contentHashCode(), w, h, d.alpha, d.level)
        samples[key]?.let { return it }
        val bmp = row?.takeIf { it.width >= w } ?: Bitmap.createBitmap(maxOf(w, 1080), 1, Bitmap.Config.ARGB_8888).also { row?.recycle(); row = it }
        bmp.eraseColor(0)
        val old = Rect(d.bounds)
        try {
            d.setBounds(0, 0, w, h)
            val c = Canvas(bmp)
            c.translate(0f, -(h / 2).toFloat())
            d.draw(c)
        } finally {
            d.bounds = old
        }
        val fill = bmp.getPixel(w / 2, 0)
        var sw = 0
        while (sw < w / 2 && bmp.getPixel(sw, 0) != fill) sw++
        val strokeC = if (sw > 0) bmp.getPixel(if (sw >= 2 && bmp.getPixel(0, 0) ushr 24 < 0xC0) 1 else 0, 0) else 0
        val s = Sample(fill, if (sw > 0) sw.toFloat() else 0f, strokeC)
        samples[key] = s
        return s
    }

    private fun forState(csl: ColorStateList, state: IntArray) = csl.getColorForState(state, csl.defaultColor)

    private fun withAlpha(c: Int, a: Float): Int {
        if (a >= 0.999f) return c
        val na = ((c ushr 24) * a).toInt().coerceIn(0, 255)
        return (na shl 24) or (c and 0xFFFFFF)
    }

    /** GradientDrawable.Orientation → CSS angle (0deg = to top, clockwise). */
    private fun angle(o: GradientDrawable.Orientation?): Float = when (o) {
        GradientDrawable.Orientation.TOP_BOTTOM -> 180f
        GradientDrawable.Orientation.TR_BL -> 225f
        GradientDrawable.Orientation.RIGHT_LEFT -> 270f
        GradientDrawable.Orientation.BR_TL -> 315f
        GradientDrawable.Orientation.BOTTOM_TOP -> 0f
        GradientDrawable.Orientation.BL_TR -> 45f
        GradientDrawable.Orientation.LEFT_RIGHT -> 90f
        GradientDrawable.Orientation.TL_BR -> 135f
        null -> 180f
    }

    // GradientDrawable has no public stroke getters: read its constant state (best-effort).
    private var strokeFields: Pair<Field, Field>? = null
    private var strokeBroken = false

    private fun stroke(d: GradientDrawable, state: IntArray): Pair<Float, Int> {
        if (strokeBroken) return 0f to 0
        return try {
            val cs = d.constantState ?: return 0f to 0
            val f = strokeFields ?: run {
                val cls = cs.javaClass
                val wf = cls.getDeclaredField("mStrokeWidth").apply { isAccessible = true }
                val cf = cls.getDeclaredField("mStrokeColors").apply { isAccessible = true }
                (wf to cf).also { strokeFields = it }
            }
            val width = (f.first.get(cs) as? Int)?.toFloat() ?: 0f
            val csl = f.second.get(cs) as? ColorStateList
            if (width <= 0f || csl == null) 0f to 0 else width to forState(csl, state)
        } catch (t: Throwable) {
            strokeBroken = true
            Log.d("GradientDrawable stroke not readable: ${t.javaClass.simpleName}")
            0f to 0
        }
    }

    // Material Components' MaterialShapeDrawable (MaterialButton, MaterialCardView, ...), through its public API.
    private class MsdMethods(val fill: Method, val strokeW: Method, val strokeC: Method, val corners: Array<Method>)
    private var msd: MsdMethods? = null
    private var msdBroken = false

    private fun materialShape(d: Drawable, w: Int, h: Int): Bg? {
        if (msdBroken || !isA(d.javaClass, "com.google.android.material.shape.MaterialShapeDrawable")) return null
        return try {
            val m = msd ?: run {
                val c = d.javaClass
                MsdMethods(
                    c.getMethod("getFillColor"), c.getMethod("getStrokeWidth"), c.getMethod("getStrokeColor"),
                    arrayOf(c.getMethod("getTopLeftCornerResolvedSize"), c.getMethod("getTopRightCornerResolvedSize"),
                        c.getMethod("getBottomRightCornerResolvedSize"), c.getMethod("getBottomLeftCornerResolvedSize")),
                ).also { msd = it }
            }
            val state = d.state
            val fill = (m.fill.invoke(d) as? ColorStateList)?.let { forState(it, state) } ?: 0
            val sw = (m.strokeW.invoke(d) as? Float) ?: 0f
            val sc = (m.strokeC.invoke(d) as? ColorStateList)?.let { forState(it, state) } ?: 0
            val radii = FloatArray(4) { (m.corners[it].invoke(d) as? Float) ?: 0f }
            Bg(bounds(d, w, h), withAlpha(fill, d.alpha / 255f), radii, sw, sc, null, false, null)
        } catch (t: Throwable) {
            msdBroken = true
            Log.d("MaterialShapeDrawable not readable: ${t.javaClass.simpleName}")
            null
        }
    }

    fun isA(c: Class<*>, name: String): Boolean {
        var cur: Class<*>? = c
        while (cur != null) { if (cur.name == name) return true; cur = cur.superclass }
        return false
    }

    /**
     * Draws [d] laid out at [w]x[h] px into a new [tw]x[th] bitmap (temporarily re-bounding it).
     * Main thread. BitmapDrawables are scaled from their bitmap instead (works for hardware bitmaps).
     */
    fun rasterize(d: Drawable, w: Int, h: Int, tw: Int, th: Int): Bitmap? {
        if (w <= 0 || h <= 0 || tw <= 0 || th <= 0) return null
        if (d is BitmapDrawable && d.tileModeX == null && d.tileModeY == null) {
            val src = d.bitmap ?: return null
            if (src.isRecycled) return null
            val soft = if (Build.VERSION.SDK_INT >= 26 && src.config == Bitmap.Config.HARDWARE) src.copy(Bitmap.Config.ARGB_8888, false) else src
            val out = Bitmap.createScaledBitmap(soft, minOf(tw, soft.width), minOf(th, soft.height), true)
            return if (out === src) src.copy(Bitmap.Config.ARGB_8888, false) else out
        }
        val bmp = Bitmap.createBitmap(tw, th, Bitmap.Config.ARGB_8888)
        val old = Rect(d.bounds)
        try {
            d.setBounds(0, 0, w, h)
            val c = Canvas(bmp)
            c.scale(tw.toFloat() / w, th.toFloat() / h)
            d.draw(c)
        } finally {
            d.bounds = old
        }
        return bmp
    }
}
