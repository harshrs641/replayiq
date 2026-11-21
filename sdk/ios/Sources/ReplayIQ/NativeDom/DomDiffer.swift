import Foundation

/// A serialised tree, flattened for diffing.
struct DomTree {
    struct Entry {
        var parent: Int
        /// The node's own fields (everything but `c`).
        var own: NSDictionary
        var children: [Int]
    }

    var root: [String: Any] = [:]
    var rootID = 0
    var entries: [Int: Entry] = [:]
    /// Each node with its subtree, for `adds`.
    var full: [Int: [String: Any]] = [:]

    /// `own` builds a node's fields without children; nil drops the node.
    init(_ node: DomNode, own: (DomNode) -> [String: Any]) {
        rootID = node.id
        root = add(node, parent: 0, own: own) ?? [:]
    }

    init() {}

    private mutating func add(_ n: DomNode, parent: Int, own: (DomNode) -> [String: Any]) -> [String: Any]? {
        guard entries[n.id] == nil else { return nil } // a layer seen twice: keep the first
        var fields = own(n)
        entries[n.id] = Entry(parent: parent, own: fields as NSDictionary, children: [])
        var kids: [[String: Any]] = []
        var ids: [Int] = []
        for c in n.children {
            if let j = add(c, parent: n.id, own: own) {
                kids.append(j)
                ids.append(c.id)
            }
        }
        entries[n.id]?.children = ids
        if !kids.isEmpty { fields["c"] = kids }
        full[n.id] = fields
        return fields
    }
}

/// Computes `ui_mutation` contents between two trees (recording API v1.1).
enum DomDiffer {
    struct Mutation {
        var adds: [[String: Any]] = []
        var removes: [[String: Any]] = []
        var updates: [[String: Any]] = []
        var isEmpty: Bool { adds.isEmpty && removes.isEmpty && updates.isEmpty }

        func json() -> [String: Any] {
            var m: [String: Any] = [:]
            if !adds.isEmpty { m["adds"] = adds }
            if !removes.isEmpty { m["removes"] = removes }
            if !updates.isEmpty { m["updates"] = updates }
            return m
        }
    }

    static func diff(_ old: DomTree, _ new: DomTree) -> Mutation {
        var m = Mutation()
        // Nodes that leave their place: gone, re-parented or re-ordered.
        var moved = Set<Int>()
        for (id, o) in old.entries {
            guard let n = new.entries[id] else { moved.insert(id); continue }
            if n.parent != o.parent { moved.insert(id) }
            // The server picks the element (div, img) when a node is added:
            // a node that changes kind or gains/loses its image is re-added.
            if (n.own["k"] as? String) != (o.own["k"] as? String) || (n.own["img"] == nil) != (o.own["img"] == nil) {
                moved.insert(id)
            }
        }
        if new.rootID != old.rootID { moved.insert(old.rootID) }
        for (pid, n) in new.entries {
            guard let o = old.entries[pid] else { continue }
            let oldKids = o.children.filter { new.entries[$0]?.parent == pid && !moved.contains($0) }
            let newKids = n.children.filter { old.entries[$0]?.parent == pid && !moved.contains($0) }
            if oldKids != newKids {
                let keep = longestIncreasing(newKids.map { id in oldKids.firstIndex(of: id) ?? -1 })
                for (i, id) in newKids.enumerated() where !keep.contains(i) { moved.insert(id) }
            }
        }

        // Removes: top-most moved nodes of the old tree.
        func removeWalk(_ id: Int) {
            guard let e = old.entries[id] else { return }
            if moved.contains(id) {
                m.removes.append(["p": e.parent, "id": id])
                return
            }
            e.children.forEach(removeWalk)
        }
        removeWalk(old.rootID)

        // Adds: top-most new or moved nodes, with their subtrees. Siblings are
        // added back to front so each `next` already exists.
        let added = Set(new.entries.keys.filter { old.entries[$0] == nil || moved.contains($0) })
        func addWalk(_ id: Int) {
            guard let e = new.entries[id] else { return }
            if !added.contains(id) {
                for (i, c) in e.children.enumerated().reversed() {
                    if added.contains(c) {
                        var a: [String: Any] = ["p": id, "n": new.full[c] ?? [:]]
                        if i + 1 < e.children.count { a["next"] = e.children[i + 1] }
                        m.adds.append(a)
                    } else {
                        addWalk(c)
                    }
                }
            }
        }
        addWalk(new.rootID)

        // Updates: kept nodes whose own fields changed.
        for (id, n) in new.entries where !added.contains(id) {
            if let o = old.entries[id], !o.own.isEqual(n.own) {
                m.updates.append(n.own as! [String: Any])
            }
        }
        m.updates.sort { ($0["id"] as? Int ?? 0) < ($1["id"] as? Int ?? 0) }
        return m
    }

    /// Indices (into `seq`) of a longest strictly increasing subsequence,
    /// ignoring -1 entries.
    static func longestIncreasing(_ seq: [Int]) -> Set<Int> {
        var tails: [Int] = [] // indices into seq
        var prev = [Int](repeating: -1, count: seq.count)
        for (i, v) in seq.enumerated() where v >= 0 {
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if seq[tails[mid]] < v { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { prev[i] = tails[lo - 1] }
            if lo == tails.count { tails.append(i) } else { tails[lo] = i }
        }
        var out = Set<Int>()
        var k = tails.last ?? -1
        while k >= 0 { out.insert(k); k = prev[k] }
        return out
    }
}
