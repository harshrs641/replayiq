// Derived from mixpanel_flutter_session_replay 2.1.0 (MixpanelMask /
// MixpanelUnmask), Copyright 2022 Mixpanel, Inc., Apache-2.0; see LICENSE and
// NOTICE. Renamed, wireframe text removed, render markers added.
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Paints over [child] in session replays.
///
/// The pixels are covered on the device, before the screenshot is encoded,
/// so they never leave the phone; in native-DOM recording the subtree is
/// sent as an empty `mask` node. Taps on a masked widget are recorded
/// without its label.
///
/// ```dart
/// ReplayIQMask(child: Text(user.email))
/// ```
///
/// Text fields are always masked; there is no need to wrap them.
class ReplayIQMask extends StatelessWidget {
  const ReplayIQMask({super.key, required this.child});

  final Widget child;

  // Found by the element walk (screenshots) and, through its render
  // marker, by the render walk (native DOM).
  @override
  Widget build(BuildContext context) => _MaskMarker(mask: true, child: child);
}

/// Exempts [child] from `maskAllText` / `maskAllImages`.
///
/// Text fields inside it stay masked.
class ReplayIQUnmask extends StatelessWidget {
  const ReplayIQUnmask({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => _MaskMarker(mask: false, child: child);
}

class _MaskMarker extends SingleChildRenderObjectWidget {
  const _MaskMarker({required this.mask, super.child});

  final bool mask;

  @override
  RenderReplayIQMaskMarker createRenderObject(BuildContext context) =>
      RenderReplayIQMaskMarker(mask: mask);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderReplayIQMaskMarker renderObject,
  ) => renderObject.mask = mask;
}

/// Marks a [ReplayIQMask] (`mask: true`) or [ReplayIQUnmask] subtree in
/// the render tree. Paints and lays out exactly like its child.
class RenderReplayIQMaskMarker extends RenderProxyBox {
  RenderReplayIQMaskMarker({required this.mask});

  bool mask;
}
