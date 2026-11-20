package com.replayiq.sample

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.util.AttributeSet
import android.view.View

/** A view that draws itself (a price chart): ReplayIQ can't describe it, so it's sent as pixels. */
class SparklineView(context: Context, attrs: AttributeSet?) : View(context, attrs) {
    private val points = floatArrayOf(0.2f, 0.5f, 0.35f, 0.7f, 0.55f, 0.9f, 0.6f, 0.8f)
    private val line = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.rgb(0x4F, 0x46, 0xE5); style = Paint.Style.STROKE; strokeWidth = 3 * resources.displayMetrics.density
    }
    private val fill = Paint().apply { color = Color.rgb(0xEE, 0xF2, 0xFF) }
    private val path = Path()

    override fun onDraw(canvas: Canvas) {
        canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), fill)
        path.reset()
        points.forEachIndexed { i, p ->
            val x = width * i / (points.size - 1f)
            val y = height * (1f - p)
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        canvas.drawPath(path, line)
    }
}
