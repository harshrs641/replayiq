package com.facebook.react.uimanager

import android.graphics.Color
import android.view.View
import com.facebook.react.uimanager.drawable.CompositeBackgroundDrawable
import com.facebook.react.uimanager.style.BorderRadiusProp
import com.facebook.react.uimanager.style.LogicalEdge

/** Test stand-in for RN's public BackgroundStyleApplicator (DIPs). */
object BackgroundStyleApplicator {
    private fun bg(v: View) = v.background as? CompositeBackgroundDrawable
    @JvmStatic fun getBackgroundColor(v: View): Int? = bg(v)?.color
    @JvmStatic fun getBorderWidth(v: View, e: LogicalEdge): Float? = bg(v)?.widths?.get(e.name)
    @JvmStatic fun getBorderColor(v: View, e: LogicalEdge): Int? = bg(v)?.let { it.colors[e.name] ?: Color.BLACK }
    @JvmStatic fun getBorderRadius(v: View, c: BorderRadiusProp): LengthPercentage? =
        if (c == BorderRadiusProp.BORDER_RADIUS) bg(v)?.radius?.let { LengthPercentage(it) } else null
}

class LengthPercentage(private val value: Float) {
    fun resolve(reference: Float): Float = value
}
