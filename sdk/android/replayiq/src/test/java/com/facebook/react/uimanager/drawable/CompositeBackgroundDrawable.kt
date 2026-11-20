package com.facebook.react.uimanager.drawable

import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.PixelFormat
import android.graphics.drawable.Drawable

/** Test stand-in for RN's background drawable: the values the applicator reports. */
class CompositeBackgroundDrawable(
    val color: Int?,
    val widths: Map<String, Float> = emptyMap(),
    val colors: Map<String, Int> = emptyMap(),
    val radius: Float? = null,
) : Drawable() {
    fun getBackgroundImage(): Any? = null
    override fun draw(canvas: Canvas) {}
    override fun setAlpha(alpha: Int) {}
    override fun setColorFilter(colorFilter: ColorFilter?) {}
    @Deprecated("") override fun getOpacity() = PixelFormat.TRANSLUCENT
}
