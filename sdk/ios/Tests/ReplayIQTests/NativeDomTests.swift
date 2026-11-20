import UIKit
import XCTest
@testable import ReplayIQ

private func own(_ n: DomNode) -> [String: Any] {
    var j: [String: Any] = ["id": n.id, "k": n.kind.rawValue,
                            "f": [n.frame.minX, n.frame.minY, n.frame.width, n.frame.height].map(Double.init)]
    if let t = n.text { j["tx"] = t.json() }
    return j
}

private func node(_ id: Int, _ kids: [DomNode] = [], x: CGFloat = 0, text: String? = nil) -> DomNode {
    var n = DomNode(id: id, kind: text == nil ? .view : .text, frame: CGRect(x: x, y: 0, width: 10, height: 10))
    n.children = kids
    if let text {
        n.text = DomText(value: text, font: ".SFUI", size: 17, weight: 400, italic: false, color: 0xFF00_0000,
                         align: "left", lineHeight: 20, maxLines: 0)
    }
    return n
}

final class DomDifferTests: XCTestCase {
    func diff(_ a: DomNode, _ b: DomNode) -> DomDiffer.Mutation {
        DomDiffer.diff(DomTree(a, own: own), DomTree(b, own: own))
    }

    func testUnchangedTreeIsEmpty() {
        let t = node(1, [node(2), node(3, [node(4)])])
        XCTAssertTrue(diff(t, t).isEmpty)
    }

    func testUpdateCarriesCompleteOwnFields() throws {
        let m = diff(node(1, [node(2, text: "Total $5")]), node(1, [node(2, text: "Total $7")]))
        XCTAssertTrue(m.adds.isEmpty && m.removes.isEmpty)
        let u = try XCTUnwrap(m.updates.first)
        XCTAssertEqual(u["id"] as? Int, 2)
        XCTAssertEqual(u["k"] as? String, "text")
        XCTAssertNotNil(u["f"])
        XCTAssertEqual((u["tx"] as? [String: Any])?["v"] as? String, "Total $7")
        XCTAssertNil(u["c"])
    }

    func testAddWithSubtreeAndNext() throws {
        let m = diff(node(1, [node(2), node(3)]), node(1, [node(2), node(5, [node(6)]), node(3)]))
        XCTAssertEqual(m.adds.count, 1)
        let a = m.adds[0]
        XCTAssertEqual(a["p"] as? Int, 1)
        XCTAssertEqual(a["next"] as? Int, 3)
        let n = try XCTUnwrap(a["n"] as? [String: Any])
        XCTAssertEqual(n["id"] as? Int, 5)
        XCTAssertEqual((n["c"] as? [[String: Any]])?.first?["id"] as? Int, 6)
    }

    func testAppendedSiblingsAreAddedBackToFront() {
        let m = diff(node(1, [node(2)]), node(1, [node(2), node(3), node(4)]))
        XCTAssertEqual(m.adds.map { ($0["n"] as? [String: Any])?["id"] as? Int }, [4, 3])
        XCTAssertNil(m.adds[0]["next"])
        XCTAssertEqual(m.adds[1]["next"] as? Int, 4)
    }

    func testRemoveOnlyTopMost() {
        let m = diff(node(1, [node(2, [node(3, [node(4)])])]), node(1))
        XCTAssertEqual(m.removes.count, 1)
        XCTAssertEqual(m.removes[0]["id"] as? Int, 2)
        XCTAssertEqual(m.removes[0]["p"] as? Int, 1)
    }

    func testReparentIsRemoveThenAdd() {
        let m = diff(node(1, [node(2), node(3, [node(4)])]), node(1, [node(2, [node(4)]), node(3)]))
        XCTAssertEqual(m.removes.map { $0["id"] as? Int }, [4])
        XCTAssertEqual(m.adds.count, 1)
        XCTAssertEqual(m.adds[0]["p"] as? Int, 2)
    }

    func testReorderMovesOnlyWhatLeftItsPlace() {
        let m = diff(node(1, [node(2), node(3), node(4), node(5)]), node(1, [node(2), node(4), node(5), node(3)]))
        XCTAssertEqual(m.removes.map { $0["id"] as? Int }, [3])
        XCTAssertEqual(m.adds.map { ($0["n"] as? [String: Any])?["id"] as? Int }, [3])
        XCTAssertNil(m.adds[0]["next"])
    }

    func testGainingAnImageReAddsTheNode() {
        var a = node(1, [node(2)])
        var b = a
        b.children[0].kind = .island
        let own2: (DomNode) -> [String: Any] = { n in
            var j = own(n)
            if n.kind == .island { j["img"] = ["a": "h"] }
            return j
        }
        let m = DomDiffer.diff(DomTree(a, own: own2), DomTree(b, own: own2))
        XCTAssertEqual(m.removes.map { $0["id"] as? Int }, [2])
        XCTAssertEqual(m.adds.count, 1)
        XCTAssertTrue(m.updates.isEmpty)
        a = b
    }

    func testLongestIncreasing() {
        XCTAssertEqual(DomDiffer.longestIncreasing([0, 2, 3, 1]), [0, 1, 2])
        XCTAssertEqual(DomDiffer.longestIncreasing([-1, 0, 1]), [1, 2])
    }
}

final class DomWalkerTests: XCTestCase {
    func walk(_ build: (UIView) -> Void, options: ReplayIQOptions = ReplayIQOptions()) -> DomNode {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.backgroundColor = .white
        window.isHidden = false
        build(window)
        window.layoutIfNeeded()
        return DomWalker(options: options).walk(window).root
    }

    func all(_ n: DomNode) -> [DomNode] { [n] + n.children.flatMap(all) }

    func testLabelsInputsAndStyles() throws {
        let root = walk { w in
            let card = UIView(frame: CGRect(x: 10, y: 100, width: 300, height: 200))
            card.backgroundColor = .red
            card.layer.cornerRadius = 12
            card.layer.borderWidth = 1
            card.layer.borderColor = UIColor.blue.cgColor
            w.addSubview(card)
            let label = UILabel(frame: CGRect(x: 8, y: 8, width: 200, height: 22))
            label.text = "Order summary"
            label.font = .systemFont(ofSize: 17, weight: .semibold)
            card.addSubview(label)
            let field = UITextField(frame: CGRect(x: 8, y: 40, width: 200, height: 34))
            field.placeholder = "Card number"
            field.text = "4242424242424242"
            card.addSubview(field)
            let secure = UITextField(frame: CGRect(x: 8, y: 80, width: 200, height: 34))
            secure.isSecureTextEntry = true
            secure.text = "hunter2"
            card.addSubview(secure)
        }
        let nodes = all(root)
        let card = try XCTUnwrap(nodes.first { $0.style.bg == 0xFFFF_0000 })
        XCTAssertEqual(card.frame, CGRect(x: 10, y: 100, width: 300, height: 200))
        XCTAssertEqual(card.style.radii, [12, 12, 12, 12])
        XCTAssertEqual(card.style.borderColor, 0xFF00_00FF)

        let text = try XCTUnwrap(nodes.first { $0.kind == .text })
        XCTAssertEqual(text.text?.value, "Order summary")
        XCTAssertEqual(text.text?.weight, 600)
        XCTAssertEqual(text.frame.origin, CGPoint(x: 8, y: 8), "relative to the card")

        let inputs = nodes.filter { $0.kind == .input }
        XCTAssertEqual(inputs.count, 2)
        XCTAssertEqual(inputs[0].input?.placeholder, "Card number")
        XCTAssertEqual(inputs[0].input?.length, 16)
        XCTAssertEqual(inputs[1].input?.type, "password")
        XCTAssertNil(inputs[1].input?.length)
        XCTAssertTrue(inputs.allSatisfy { $0.children.isEmpty }, "an input's subviews (its value) are never walked")
        // The value is nowhere in the tree.
        let json = DomTree(root) { own($0) }.root.description
        XCTAssertFalse(json.contains("4242424242424242"))
        XCTAssertFalse(json.contains("hunter2"))
    }

    func testMaskedViewsSendNothingInside() {
        let root = walk { w in
            let box = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            box.replayIQMasked = true
            let l = UILabel(frame: box.bounds)
            l.text = "Member #88-1234"
            box.addSubview(l)
            w.addSubview(box)
        }
        let nodes = all(root)
        let mask = nodes.first { $0.kind == .mask }
        XCTAssertNotNil(mask)
        XCTAssertTrue(mask!.children.isEmpty)
        XCTAssertFalse(nodes.contains { $0.text?.value.contains("Member") == true })
    }

    func testMaskAllTextMasksLabels() {
        let opts = ReplayIQOptions()
        opts.maskAllText = true
        let root = walk({ w in
            let l = UILabel(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
            l.text = "secret"
            w.addSubview(l)
        }, options: opts)
        XCTAssertFalse(all(root).contains { $0.kind == .text })
        XCTAssertTrue(all(root).contains { $0.kind == .mask })
    }

    func testScrollOffsetAndContentCoordinates() throws {
        let root = walk { w in
            let sv = UIScrollView(frame: CGRect(x: 0, y: 50, width: 390, height: 400))
            sv.contentInsetAdjustmentBehavior = .never
            sv.contentSize = CGSize(width: 390, height: 2000)
            let row = UIView(frame: CGRect(x: 0, y: 900, width: 390, height: 44))
            row.backgroundColor = .green
            sv.addSubview(row)
            sv.contentOffset = CGPoint(x: 0, y: 700)
            w.addSubview(sv)
        }
        let scroll = try XCTUnwrap(all(root).first { $0.kind == .scroll })
        XCTAssertEqual(scroll.scrollOffset, CGPoint(x: 0, y: 700))
        XCTAssertEqual(scroll.frame.origin, CGPoint(x: 0, y: 50))
        let row = try XCTUnwrap(all(scroll).first { $0.style.bg == 0xFF00_FF00 })
        XCTAssertEqual(row.frame.origin.y, 900, "children stay in content coordinates")
        XCTAssertEqual(scroll.children.first?.frame.height, 2000, "sizer as tall as the content")
    }

    func testIdsAreStableAcrossWalks() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let v = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        v.backgroundColor = .red
        window.addSubview(v)
        let w = DomWalker(options: ReplayIQOptions())
        let a = all(w.walk(window).root).map(\.id)
        let b = all(w.walk(window).root).map(\.id)
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set(a).count, a.count)
    }

    func testImagesAndTransforms() throws {
        let img = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { ctx in
            UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        let root = walk { w in
            let iv = UIImageView(image: img)
            iv.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
            iv.contentMode = .scaleAspectFill
            iv.transform = CGAffineTransform(rotationAngle: .pi / 2)
            w.addSubview(iv)
        }
        let image = try XCTUnwrap(all(root).first { $0.kind == .image })
        XCTAssertEqual(image.fit, "cover")
        XCTAssertEqual(image.frame.size, CGSize(width: 20, height: 20), "untransformed frame")
        XCTAssertEqual(image.style.transform.b, 1, accuracy: 0.001)
        guard case .image = image.pixels else { return XCTFail("expected image pixels") }
    }

    func testTransformAboutCentre() {
        let l = CALayer()
        l.bounds = CGRect(x: 0, y: 0, width: 100, height: 50)
        l.anchorPoint = .zero
        l.transform = CATransform3DMakeScale(2, 2, 1)
        let t = DomWalker.transform(l, size: l.bounds.size)
        // About the top-left corner == about the centre, then shifted by (50, 25).
        XCTAssertEqual(t.a, 2)
        XCTAssertEqual(t.tx, 50, accuracy: 0.001)
        XCTAssertEqual(t.ty, 25, accuracy: 0.001)
    }

    func testColorsAndWeights() {
        XCTAssertEqual(DomColor.argb(UIColor(red: 1, green: 0, blue: 0, alpha: 0.5).cgColor), 0x80FF_0000)
        XCTAssertEqual(DomColor.argb(UIColor(white: 1, alpha: 1).cgColor), 0xFFFF_FFFF)
        XCTAssertEqual(DomColor.hex(0x80FF_0000), "#80FF0000")
        XCTAssertEqual(DomWalker.cssWeight(UIFont.Weight.bold.rawValue), 700)
        XCTAssertEqual(DomWalker.cssWeight(UIFont.Weight.regular.rawValue), 400)
    }

    func testGradientAngle() throws {
        let g = CAGradientLayer()
        g.colors = [UIColor.red.cgColor, UIColor.blue.cgColor]
        g.startPoint = CGPoint(x: 0, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 0.5)
        let d = try XCTUnwrap(DomWalker.gradient(g))
        XCTAssertEqual(d.angle, 90, accuracy: 0.01, "left to right")
        XCTAssertEqual(d.stops.map(\.1), [0, 1])
    }
}

final class DomAssetTests: XCTestCase {
    func image(_ w: Int, _ h: Int, alpha: Bool) -> CGImage {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = !alpha
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: f).image { ctx in
            UIColor.purple.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        }.cgImage!
    }

    func testHashIsSha256OfUploadAndUploadedOnce() throws {
        var sent: [DomAssets.Encoded] = []
        let a = DomAssets(registry: nil) { sent.append($0) }
        let img = image(300, 300, alpha: false)
        let h1 = try XCTUnwrap(a.hash(.image(img), points: CGSize(width: 200, height: 200)))
        let h2 = a.hash(.image(img), points: CGSize(width: 200, height: 200))
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(DomAssets.sha256(sent[0].data), h1)
        XCTAssertEqual(sent[0].type, "image/jpeg")
        let decoded = try XCTUnwrap(UIImage(data: sent[0].data)?.cgImage)
        XCTAssertEqual(decoded.width, 200, "downscaled to 1x of the node")
    }

    func testRenderedPixelsDedupeByContent() {
        var sent = 0
        let a = DomAssets(registry: nil) { _ in sent += 1 }
        let h1 = a.hash(.rendered(image(40, 20, alpha: true)), points: CGSize(width: 40, height: 20))
        let h2 = a.hash(.rendered(image(40, 20, alpha: true)), points: CGSize(width: 40, height: 20))
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(sent, 1)
    }

    func testRegistrySkipsKnownAssets() {
        let reg = AssetRegistry(dir: tempDir(), key: "k")
        XCTAssertTrue(reg.claim("abc"))
        XCTAssertFalse(reg.claim("abc"), "already queued")
        reg.markUploaded("abc")
        let reopened = AssetRegistry(dir: reg.dirForTests, key: "k")
        XCTAssertTrue(reopened.isKnown("abc"))
        XCTAssertFalse(reopened.claim("abc"))
    }
}

final class AssetUploadTests: XCTestCase {
    final class Server: HTTPClient {
        var have = Set<String>()
        var log: [String] = []
        func send(_ r: URLRequest, completion: @escaping (Int, [AnyHashable: Any], Error?) -> Void) {
            let m = r.httpMethod ?? "GET"
            log.append("\(m) \(r.url!.path)")
            if m == "HEAD" {
                completion(have.contains(r.url!.lastPathComponent) ? 200 : 404, [:], nil)
            } else if r.url!.path == "/api/v1/assets" {
                XCTAssertEqual(r.value(forHTTPHeaderField: "X-Asset-Hash"), DomAssets.sha256(r.httpBody!))
                XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "image/png")
                XCTAssertNil(r.value(forHTTPHeaderField: "Content-Encoding"))
                have.insert(r.value(forHTTPHeaderField: "X-Asset-Hash")!)
                completion(201, [:], nil)
            } else {
                completion(202, [:], nil)
            }
        }
    }

    func testAssetsGoBeforeTheBatchAndHeadSkipsKnown() {
        let q = BatchQueue(dir: tempDir())
        let png = Data([1, 2, 3])
        let h = DomAssets.sha256(png)
        let known = Data([4, 5])
        let hk = DomAssets.sha256(known)
        q.enqueue(path: "api/v1/assets|image/png|\(h)", body: png, kind: .asset)
        q.enqueue(path: "api/v1/assets|image/png|\(hk)", body: known, kind: .asset)
        q.enqueue(path: "api/v1/events", body: Data("{}".utf8), kind: .events)
        let server = Server()
        server.have.insert(hk)
        let reg = AssetRegistry(dir: tempDir(), key: "k")
        let u = Uploader(queue: q, client: server, endpoint: URL(string: "http://h")!, key: "k")
        u.registry = reg
        let e = expectation(description: "idle")
        u.whenIdle(timeout: 5) { e.fulfill() }
        wait(for: [e], timeout: 10)
        XCTAssertEqual(server.log, ["HEAD /api/v1/assets/\(h)", "POST /api/v1/assets", "HEAD /api/v1/assets/\(hk)", "POST /api/v1/events"])
        XCTAssertTrue(reg.isKnown(h) && reg.isKnown(hk))
        XCTAssertTrue(q.items().isEmpty)
    }
}

/// Stands in for React Native Fabric's RCTParagraphComponentView.
@objc(RCTParagraphTestComponentView)
final class RCTParagraphTestComponentView: UIView {
    @objc var attributedText: NSAttributedString?
}

final class ReactNativeFidelityTests: XCTestCase {
    func all(_ n: DomNode) -> [DomNode] { [n] + n.children.flatMap(all) }

    /// A 9-slice border image like React Native's: a `px`-wide ring.
    func borderImage(size: Int, px: Int, radius: CGFloat, color: UIColor) -> CGImage {
        let f = UIGraphicsImageRendererFormat()
        f.scale = 1
        f.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: f).image { _ in
            let r = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: CGFloat(px) / 2, dy: CGFloat(px) / 2)
            let path = UIBezierPath(roundedRect: r, cornerRadius: radius)
            path.lineWidth = CGFloat(px)
            color.setStroke()
            path.stroke()
        }.cgImage!
    }

    func testPaintOrderFollowsZPosition() {
        let a = CALayer(), b = CALayer(), c = CALayer()
        b.zPosition = -1024
        c.zPosition = -1024
        XCTAssertTrue(DomWalker.paintOrder([a, b, c]).elementsEqual([b, c, a], by: ===))
        XCTAssertTrue(DomWalker.paintOrder([a, b]).count == 2)
    }

    func testNineSliceBorderIsDescribed() throws {
        let img = borderImage(size: 51, px: 3, radius: 24, color: UIColor(red: 0xD1 / 255, green: 0xD5 / 255, blue: 0xDB / 255, alpha: 1))
        let center = CGRect(x: 24 / 51.0, y: 24 / 51.0, width: 3 / 51.0, height: 3 / 51.0)
        let b = try XCTUnwrap(DomWalker.sliceBorder(img, center: center, scale: 3))
        XCTAssertEqual(b.width, 1, accuracy: 0.34)
        XCTAssertEqual(b.color >> 24, 0xFF)
        XCTAssertEqual(b.color & 0xFF_FFFF, 0xD1D5DB, "border colour")
        XCTAssertEqual(b.radius, 8)
    }

    func testReactNativeComponentReplaysInOrder() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let component = UIView(frame: CGRect(x: 20, y: 100, width: 362, height: 44))
        window.addSubview(component)
        let field = UITextField(frame: CGRect(x: 1, y: 1, width: 360, height: 41))
        field.placeholder = "Full name"
        component.addSubview(field)
        // React Native adds these after the subviews, behind them.
        let bg = CALayer()
        bg.frame = component.bounds
        bg.backgroundColor = UIColor.white.cgColor
        bg.cornerRadius = 8
        bg.zPosition = -1024
        component.layer.addSublayer(bg)
        let border = CALayer()
        border.frame = component.bounds
        border.contents = borderImage(size: 51, px: 3, radius: 24, color: .gray)
        border.contentsCenter = CGRect(x: 24 / 51.0, y: 24 / 51.0, width: 3 / 51.0, height: 3 / 51.0)
        border.contentsScale = 3
        border.zPosition = -1024
        component.layer.addSublayer(border)

        let root = DomWalker(options: ReplayIQOptions()).walk(window).root
        let nodes = all(root)
        XCTAssertFalse(nodes.contains { $0.kind == .image }, "no stretched border image")
        let kinds = nodes.filter { $0.kind == .input || $0.style.bg == 0xFFFF_FFFF || $0.style.borderWidth > 0 }
        XCTAssertEqual(kinds.last?.kind, .input, "the input paints over its background and border")
        let borderNode = try XCTUnwrap(nodes.first { $0.style.borderWidth > 0 && $0.kind == .view })
        XCTAssertEqual(borderNode.style.radii, [8, 8, 8, 8])
    }

    func testParagraphBecomesText() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let p = RCTParagraphTestComponentView(frame: CGRect(x: 20, y: 82, width: 362, height: 34))
        p.attributedText = NSAttributedString(string: "Checkout", attributes: [
            .font: UIFont.systemFont(ofSize: 28, weight: .bold),
            .foregroundColor: UIColor(red: 0x11 / 255, green: 0x18 / 255, blue: 0x27 / 255, alpha: 1),
        ])
        let bitmap = UIView(frame: p.bounds) // RCTParagraphTextView: drawn text
        bitmap.layer.contents = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }.cgImage
        p.addSubview(bitmap)
        window.addSubview(p)
        let nodes = all(DomWalker(options: ReplayIQOptions()).walk(window).root)
        let t = try XCTUnwrap(nodes.first { $0.kind == .text })
        XCTAssertEqual(t.text?.value, "Checkout")
        XCTAssertEqual(t.text?.size, 28)
        XCTAssertEqual(t.text?.weight, 700)
        XCTAssertEqual(t.text?.color, 0xFF11_1827)
        XCTAssertTrue(t.children.isEmpty)
        XCTAssertFalse(nodes.contains { $0.kind == .image || $0.kind == .island }, "its bitmap is not sent")
    }
}
