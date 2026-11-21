import 'dart:convert';

import 'node.dart';

/// A node flattened for diffing.
class FlatNode {
  FlatNode(this.node, this.parent, this.own, this.children);
  final UiNode node;
  final int? parent;

  /// The node's own fields, encoded, for cheap equality.
  final String own;
  final List<int> children;
}

Map<int, FlatNode> flatten(UiNode root) {
  final out = <int, FlatNode>{};
  root.visit((n, p) {
    out[n.id] = FlatNode(n, p?.id, jsonEncode(n.own()), [
      for (final c in n.c) c.id,
    ]);
  });
  return out;
}

class UiDiff {
  final List<Map<String, Object?>> adds = [];
  final List<Map<String, Object?>> removes = [];
  final List<Map<String, Object?>> updates = [];

  bool get isEmpty => adds.isEmpty && removes.isEmpty && updates.isEmpty;
  int get size => adds.length + removes.length + updates.length;
}

/// Changes from [prev] to [next] (Recording API v1.1 `ui_mutation`):
/// removes and adds of whole subtrees, and updates carrying a node's
/// complete own fields. Children whose order changed are removed and
/// re-added.
UiDiff diffTrees(Map<int, FlatNode> prev, Map<int, FlatNode> next) {
  final out = UiDiff();

  // Nodes (re)inserted in [next]: new, moved to another parent, or
  // reordered among their siblings.
  final inserted = <int>{};
  next.forEach((id, n) {
    final old = prev[id];
    if (old == null || old.parent != n.parent) inserted.add(id);
  });
  next.forEach((id, n) {
    final old = prev[id];
    if (old == null || n.children.isEmpty) return;
    final kept = [
      for (final c in n.children)
        if (!inserted.contains(c) && prev[c]?.parent == id) c,
    ];
    final keptSet = kept.toSet();
    final before = [
      for (final c in old.children)
        if (keptSet.contains(c)) c,
    ];
    var same = before.length == kept.length;
    for (var i = 0; same && i < kept.length; i++) {
      same = before[i] == kept[i];
    }
    if (!same) inserted.addAll(kept);
  });

  // Removes: nodes gone from [next] or reinserted, topmost only.
  final removed = <int>{};
  prev.forEach((id, n) {
    if (!next.containsKey(id) || inserted.contains(id)) removed.add(id);
  });
  for (final id in removed) {
    final p = prev[id]!.parent;
    if (p != null && !removed.contains(p)) {
      out.removes.add({'p': p, 'id': id});
    }
  }

  // Adds: topmost inserted nodes, parents first; within a parent in
  // reverse order so `next` always names a node that already exists.
  final roots = <int>[];
  void walk(int id) {
    final n = next[id]!;
    if (inserted.contains(id)) {
      if (!inserted.contains(n.parent)) roots.add(id);
      return; // its subtree travels with it
    }
    for (final c in n.children) {
      walk(c);
    }
  }

  final rootId = next.keys.isEmpty ? null : next.keys.first;
  if (rootId != null) walk(rootId);
  final byParent = <int, List<int>>{};
  for (final id in roots) {
    byParent.putIfAbsent(next[id]!.parent!, () => []).add(id);
  }
  byParent.forEach((p, ids) {
    final siblings = next[p]!.children;
    for (final id in ids.reversed) {
      final i = siblings.indexOf(id);
      final after = i + 1 < siblings.length ? siblings[i + 1] : null;
      out.adds.add({'p': p, 'next': ?after, 'n': next[id]!.node.toJson()});
    }
  });

  // Updates: kept nodes whose own fields changed.
  next.forEach((id, n) {
    if (inserted.contains(id)) return;
    final old = prev[id];
    if (old != null && old.own != n.own) out.updates.add(n.node.own());
  });
  return out;
}
