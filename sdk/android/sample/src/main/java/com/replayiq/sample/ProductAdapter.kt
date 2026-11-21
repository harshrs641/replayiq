package com.replayiq.sample

import android.view.Gravity
import android.view.ViewGroup
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.recyclerview.widget.RecyclerView
import com.replayiq.android.ReplayIQ

/** 40 product rows: a RecyclerView recorded as a `scroll` node whose rows are recycled. */
class ProductAdapter : RecyclerView.Adapter<ProductAdapter.Row>() {
    class Row(val view: LinearLayout, val name: TextView, val price: TextView) : RecyclerView.ViewHolder(view)

    override fun getItemCount() = 40

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): Row {
        val ctx = parent.context
        val d = ctx.resources.displayMetrics.density
        val row = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            layoutParams = RecyclerView.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (56 * d).toInt())
            isClickable = true
        }
        row.addView(ImageView(ctx).apply {
            setImageResource(R.drawable.ic_shoe)
            setBackgroundResource(R.drawable.rounded_tile)
            val p = (6 * d).toInt()
            setPadding(p, p, p, p)
        }, LinearLayout.LayoutParams((40 * d).toInt(), (40 * d).toInt()))
        val name = TextView(ctx).apply { textSize = 16f; setPadding((12 * d).toInt(), 0, 0, 0) }
        row.addView(name, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        val price = TextView(ctx).apply { textSize = 16f; setTextColor(0xFF4F46E5.toInt()) }
        row.addView(price, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        return Row(row, name, price)
    }

    override fun onBindViewHolder(holder: Row, position: Int) {
        holder.name.text = "Trail Runner ${position + 4}"
        holder.price.text = "\$${99 + position * 5}.00"
        holder.view.setOnClickListener {
            ReplayIQ.track("product_opened", mapOf("position" to position))
            Toast.makeText(it.context, "Product ${position + 4}", Toast.LENGTH_SHORT).show()
        }
    }
}
