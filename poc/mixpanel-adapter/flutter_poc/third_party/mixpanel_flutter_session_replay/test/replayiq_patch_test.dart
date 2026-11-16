// REPLAYIQ POC PATCH: TextFields follow the normal masking rules instead of
// being force-masked; obscureText fields never send their value in wireframes.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mixpanel_flutter_session_replay/mixpanel_flutter_session_replay.dart';
import 'package:mixpanel_flutter_session_replay/src/internal/masking/mask_detector.dart';
import 'package:mixpanel_flutter_session_replay/src/models/masking_directive.dart';
import 'package:mixpanel_flutter_session_replay/src/models/wireframe.dart';

Future<MaskDetectionResult> _detect(
  WidgetTester tester,
  Widget child,
  Set<AutoMaskedView> autoMask,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: RepaintBoundary(
          child: SizedBox(width: 300, height: 300, child: child),
        ),
      ),
    ),
  );
  await tester.pump();
  final boundary = tester.allRenderObjects
      .whereType<RenderRepaintBoundary>()
      .first;
  return MaskDetector(
    directive: MaskingDirective(autoMaskTypes: autoMask),
    trackUnmaskBounds: false,
    collectWireframes: true,
  ).detectMaskRegions(boundary);
}

Widget _fields({bool wrapPlainInMask = false}) {
  final plain = TextField(controller: TextEditingController(text: 'Ada'));
  return Column(
    children: [
      wrapPlainInMask ? MixpanelMask(child: plain) : plain,
      TextField(
        controller: TextEditingController(text: '4111'),
        obscureText: true,
      ),
    ],
  );
}

List<WireframeElement> _inputs(MaskDetectionResult r) =>
    r.rawWireframes!.where((e) => e.role == WireframeRole.input).toList();

void main() {
  testWidgets(
    'text auto-mask off: both fields drawn, obscured value withheld',
    (tester) async {
      final r = await _detect(tester, _fields(), {AutoMaskedView.image});
      // No mask rects: the obscured field paints as dots in the screenshot.
      expect(r.maskRegions, isEmpty);

      final inputs = _inputs(r);
      expect(inputs, hasLength(2));
      expect(inputs[0].text, 'Ada');
      expect(inputs[0].maskDecision, MaskDecision.none);
      expect(inputs[1].text, isNull);
      expect(inputs[1].maskDecision, MaskDecision.textEntry);
    },
  );

  testWidgets('text auto-mask on: plain field is auto-masked', (tester) async {
    final r = await _detect(tester, _fields(), {
      AutoMaskedView.text,
      AutoMaskedView.image,
    });
    expect(r.maskRegions.where((m) => m.source == MaskSource.auto), isNotEmpty);
    final inputs = _inputs(r);
    expect(inputs[0].text, isNull);
    expect(inputs[0].maskDecision, MaskDecision.auto);
  });

  testWidgets('MixpanelMask still masks a plain field', (tester) async {
    final r = await _detect(tester, _fields(wrapPlainInMask: true), {
      AutoMaskedView.image,
    });
    expect(
      r.maskRegions.where((m) => m.source == MaskSource.manual),
      isNotEmpty,
    );
    expect(_inputs(r).every((e) => e.text == null), isTrue);
  });
}
