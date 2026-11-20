package com.replayiq.android.internal

import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.roundToLong

/**
 * One node of the Native DOM (recording API v1.1 §1), as captured on the main thread. Plain data:
 * serialised and diffed on the worker thread. Sizes are dp, colours ARGB ints.
 */
internal class DomNode(val id: Int, var k: String) {
    var x = 0f
    var y = 0f
    var w = 0f
    var h = 0f

    // Style (`s`).
    var bg = 0                       // 0 = none
    var radii: FloatArray? = null    // tl, tr, br, bl
    var bw = 0f
    var bc = 0
    var shadow: FloatArray? = null   // dx, dy, blur, spread
    var shadowColor = 0
    var alpha = 1f
    var t: FloatArray? = null        // a, b, c, d, tx, ty (about the centre)
    var clip = false
    var grad: Grad? = null

    var role: String? = null
    var label: String? = null

    var tx: TextInfo? = null
    var img: String? = null          // asset hash (image / island)
    var fit: String? = null
    var input: InputInfo? = null
    var so: FloatArray? = null       // scroll offset
    var hint: String? = null
    /** Text rebuilt from accessibility data: font and position are estimates. */
    var approx = false

    /** Not serialised: selector of a scroll node, for the `scroll` signal. */
    var selector: String? = null

    val c = ArrayList<DomNode>(0)

    fun frame(x: Float, y: Float, w: Float, h: Float) = apply { this.x = x; this.y = y; this.w = w; this.h = h }

    class Grad(val radial: Boolean, val angle: Float, val colors: IntArray, val positions: FloatArray)

    data class TextInfo(
        val v: String, val size: Float, val weight: Int, val italic: Boolean, val color: Int,
        val align: String?, val lineHeight: Float, val maxLines: Int, val font: String? = null,
    )

    data class InputInfo(val type: String, val ph: String?, val len: Int, val focus: Boolean)

    /** The node's own fields: everything but `c`. */
    fun ownJson(): JSONObject {
        val o = JSONObject()
        o.put("id", id).put("k", k)
        o.put("f", JSONArray().put(r1(x)).put(r1(y)).put(r1(w)).put(r1(h)))
        val s = JSONObject()
        if (bg != 0) s.put("bg", color(bg))
        radii?.let { r -> if (r.any { it > 0f }) s.put("r", JSONArray().put(r1(r[0])).put(r1(r[1])).put(r1(r[2])).put(r1(r[3]))) }
        if (bw > 0f) s.put("bw", r1(bw)).put("bc", color(bc))
        shadow?.let { sh -> s.put("sh", JSONArray().put(r1(sh[0])).put(r1(sh[1])).put(r1(sh[2])).put(r1(sh[3])).put(color(shadowColor))) }
        if (alpha < 0.999f) s.put("o", r2(alpha.coerceIn(0f, 1f)))
        t?.let { m -> s.put("t", JSONArray().put(r3(m[0])).put(r3(m[1])).put(r3(m[2])).put(r3(m[3])).put(r1(m[4])).put(r1(m[5]))) }
        if (clip) s.put("clip", true)
        grad?.let { g ->
            val stops = JSONArray()
            for (i in g.colors.indices) stops.put(JSONArray().put(color(g.colors[i])).put(r2(g.positions.getOrElse(i) { i.toFloat() / (g.colors.size - 1).coerceAtLeast(1) })))
            s.put("grad", JSONObject().put("type", if (g.radial) "radial" else "linear").put("angle", r1(g.angle)).put("stops", stops))
        }
        if (s.length() > 0) o.put("s", s)
        role?.let { o.put("role", it) }
        label?.let { o.put("label", it) }
        if (approx) o.put("approx", true)
        tx?.let { t ->
            val j = JSONObject().put("v", t.v).put("size", r1(t.size)).put("col", color(t.color))
            if (t.weight != 400) j.put("w", t.weight)
            if (t.italic) j.put("i", true)
            t.align?.let { j.put("al", it) }
            if (t.lineHeight > 0f) j.put("lh", r1(t.lineHeight))
            if (t.maxLines in 1..999) j.put("ml", t.maxLines)
            t.font?.let { j.put("font", it) }
            o.put("tx", j)
        }
        if (k == "image" || k == "island") {
            val a = img
            if (a != null) o.put("img", JSONObject().put("a", a).put("fit", fit ?: "fill"))
            else if (k == "island") o.put("hint", hint ?: "unknown")
        }
        input?.let { i ->
            val j = JSONObject().put("type", i.type)
            i.ph?.let { j.put("ph", it) }
            if (i.len > 0) j.put("len", i.len)
            if (i.focus) j.put("focus", true)
            o.put("in", j)
        }
        so?.let { o.put("so", JSONArray().put(r1(it[0])).put(r1(it[1]))) }
        return o
    }

    /** The whole subtree. */
    fun fullJson(): JSONObject {
        val o = ownJson()
        if (c.isNotEmpty()) {
            val a = JSONArray()
            for (child in c) a.put(child.fullJson())
            o.put("c", a)
        }
        return o
    }

    fun count(): Int { var n = 1; for (child in c) n += child.count(); return n }

    companion object {
        fun color(argb: Int): String = "#" + String.format(java.util.Locale.US, "%08X", argb)

        // Rounded so sub-pixel jitter doesn't produce updates; whole numbers serialise as ints.
        fun r1(v: Float): Number = round(v, 10.0)
        fun r2(v: Float): Number = round(v, 100.0)
        fun r3(v: Float): Number = round(v, 1000.0)

        private fun round(v: Float, scale: Double): Number {
            if (v.isNaN() || v.isInfinite()) return 0
            val l = (v * scale).roundToLong()
            return if (l % scale.toLong() == 0L) l / scale.toLong() else l / scale
        }
    }
}

/**
 * Turns successive trees into `ui_snapshot` / `ui_mutation` payloads. Stateful (the previous tree);
 * worker thread only.
 */
internal class DomDiffer {
    private class Prev(val own: String, val k: String, val kids: IntArray)

    private var prev = HashMap<Int, Prev>()
    private var prevRoot = -1

    class Mutation(val adds: JSONArray, val removes: JSONArray, val updates: JSONArray) {
        val isEmpty get() = adds.length() == 0 && removes.length() == 0 && updates.length() == 0
    }

    /** Scroll nodes whose offset changed in the last [mutation]. */
    val scrolled = ArrayList<DomNode>()

    val hasBaseline get() = prevRoot >= 0

    fun reset() { prev = HashMap(); prevRoot = -1 }

    /**
     * Identity of a node's element on the server: an image or island without its asset yet is
     * built as a plain box there, which a later update can't turn into an image, so gaining (or
     * losing) the asset replaces the node.
     */
    private fun kindKey(n: DomNode): String = if ((n.k == "image" || n.k == "island") && n.img == null) n.k + "-" else n.k

    /** Full tree; becomes the baseline for the next mutation. */
    fun snapshot(root: DomNode): JSONObject {
        val next = HashMap<Int, Prev>(prev.size.coerceAtLeast(64))
        val json = record(root, next)
        prev = next
        prevRoot = root.id
        scrolled.clear()
        return json
    }

    private fun record(n: DomNode, into: HashMap<Int, Prev>): JSONObject {
        val own = n.ownJson()
        into[n.id] = Prev(own.toString(), kindKey(n), IntArray(n.c.size) { n.c[it].id })
        if (n.c.isNotEmpty()) {
            val a = JSONArray()
            for (child in n.c) a.put(record(child, into))
            own.put("c", a)
        }
        return own
    }

    /** Changes since the baseline, or null when the root changed (a snapshot is needed then). */
    fun mutation(root: DomNode): Mutation? {
        if (root.id != prevRoot) return null
        val m = Mutation(JSONArray(), JSONArray(), JSONArray())
        val next = HashMap<Int, Prev>(prev.size)
        scrolled.clear()
        val own = root.ownJson()
        val ownStr = own.toString()
        val p = prev[root.id]!!
        if (p.k != kindKey(root)) return null
        if (p.own != ownStr) m.updates.put(own)
        next[root.id] = Prev(ownStr, kindKey(root), IntArray(root.c.size) { root.c[it].id })
        diffChildren(root, p, m, next)
        prev = next
        return m
    }

    private fun diffChildren(parent: DomNode, p: Prev, m: Mutation, next: HashMap<Int, Prev>) {
        val prevIndex = HashMap<Int, Int>(p.kids.size * 2)
        p.kids.forEachIndexed { i, id -> prevIndex[id] = i }
        // Children kept in place: same parent, same kind, and still in the same relative order.
        val kept = HashSet<Int>()
        var last = -1
        for (child in parent.c) {
            val pi = prevIndex[child.id] ?: continue
            if (pi > last && prev[child.id]?.k == kindKey(child)) { kept.add(child.id); last = pi }
        }
        for (id in p.kids) if (id !in kept) m.removes.put(JSONObject().put("p", parent.id).put("id", id))
        for ((i, child) in parent.c.withIndex()) {
            if (child.id in kept) {
                val cp = prev[child.id]!!
                val own = child.ownJson()
                val ownStr = own.toString()
                if (cp.own != ownStr) {
                    m.updates.put(own)
                    if (child.k == "scroll" && !sameScroll(cp.own, child)) scrolled.add(child)
                }
                next[child.id] = Prev(ownStr, kindKey(child), IntArray(child.c.size) { child.c[it].id })
                diffChildren(child, cp, m, next)
            } else {
                val add = JSONObject().put("p", parent.id)
                for (j in i + 1 until parent.c.size) {
                    val sib = parent.c[j].id
                    if (sib in kept) { add.put("next", sib); break }
                }
                add.put("n", record(child, next))
                m.adds.put(add)
            }
        }
    }

    private fun sameScroll(prevOwn: String, n: DomNode): Boolean {
        val so = n.so ?: return true
        val key = "\"so\":[" + DomNode.r1(so[0]) + "," + DomNode.r1(so[1]) + "]"
        return prevOwn.contains(key)
    }
}
