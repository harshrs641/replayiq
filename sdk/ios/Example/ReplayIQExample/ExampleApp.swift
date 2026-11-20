import MapKit
import ReplayIQ
import SwiftUI

@main
struct ExampleApp: App {
    @StateObject private var cart = Cart()

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let env = ProcessInfo.processInfo.environment
        let key = env["RIQ_KEY"] ?? info["ReplayIQKey"] as? String ?? "verify"
        let endpoint = env["RIQ_ENDPOINT"] ?? info["ReplayIQEndpoint"] as? String ?? "http://localhost:8080"

        let options = ReplayIQOptions()
        options.debug = true
        options.metadata = ["example": "checkout"]
        switch env["RIQ_MODE"] {
        case "screenshot": options.recordingMode = .screenshot
        case "nativeDom": options.recordingMode = .nativeDom
        default: options.recordingMode = .auto
        }
        ReplayIQ.start(key: key, endpoint: endpoint, options: options)
        ReplayIQ.identify("demo-user-42", traits: ["plan": "pro"])
    }

    var body: some Scene {
        WindowGroup {
            ShopView().environmentObject(cart)
        }
    }
}

struct Product: Identifiable, Hashable {
    let id: Int
    let name: String
    let price: Double
    let symbol: String
}

final class Cart: ObservableObject {
    @Published var items: [Product] = []
    var total: Double { items.reduce(0) { $0 + $1.price } }
}

let products = [
    Product(id: 1, name: "Trail Runner Shoes", price: 129, symbol: "shoe.fill"),
    Product(id: 2, name: "Merino Hoodie", price: 89, symbol: "tshirt.fill"),
    Product(id: 3, name: "Insulated Bottle", price: 32, symbol: "waterbottle.fill"),
    Product(id: 4, name: "Daypack 22L", price: 74, symbol: "backpack.fill"),
]

struct ShopView: View {
    @EnvironmentObject var cart: Cart
    @State private var showUIKit = false

    var body: some View {
        NavigationView {
            List {
                Section("Products") {
                    ForEach(products) { p in
                        HStack {
                            Image(systemName: p.symbol).frame(width: 32)
                            VStack(alignment: .leading) {
                                Text(p.name)
                                Text(p.price, format: .currency(code: "USD")).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("Add") {
                                cart.items.append(p)
                                ReplayIQ.track("add_to_cart", properties: ["product": p.name, "price": p.price])
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityLabel("Add \(p.name)")
                        }
                    }
                }
                Section("Checkout") {
                    NavigationLink("Cart (\(cart.items.count))") { CartView() }
                    Button("UIKit checkout") { showUIKit = true }
                }
                Section("Stores") {
                    NavigationLink("Store map") { StoreMapView() }
                }
                Section("Diagnostics") {
                    NavigationLink("Debug tools") { DebugView() }
                }
            }
            .navigationTitle("Outdoor Shop")
            .replayIQScreen("Shop")
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showUIKit) { UIKitCheckout().ignoresSafeArea() }
    }
}

struct CartView: View {
    @EnvironmentObject var cart: Cart

    var body: some View {
        List {
            ForEach(Array(cart.items.enumerated()), id: \.offset) { _, p in
                HStack { Text(p.name); Spacer(); Text(p.price, format: .currency(code: "USD")) }
            }
            HStack { Text("Total").bold(); Spacer(); Text(cart.total, format: .currency(code: "USD")).bold() }
            NavigationLink("Checkout") { CheckoutView() }
        }
        .navigationTitle("Cart")
        .replayIQScreen("Cart")
    }
}

struct CheckoutView: View {
    @EnvironmentObject var cart: Cart
    @State private var name = ""
    @State private var email = ""
    @State private var card = ""
    @State private var password = ""
    @State private var status = ""
    @State private var paying = false

    var body: some View {
        Form {
            Section("Contact") {
                TextField("Full name", text: $name)
                TextField("Email", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                SecureField("Account password", text: $password)
            }
            Section("Payment") {
                TextField("Card number", text: $card).keyboardType(.numberPad)
                // Custom-drawn sensitive content: masked with the modifier.
                HStack {
                    Image(systemName: "creditcard.fill")
                    Text(card.isEmpty ? "•••• •••• •••• 4242" : card)
                    Spacer()
                    Text("Saved card")
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.15)))
                .replayIQMask()
            }
            Section {
                Button(paying ? "Paying…" : "Pay now") { pay() }.disabled(paying)
                Button("Apply coupon") {
                    // Does nothing: tap it fast to produce a rage click.
                    ReplayIQ.log("coupon tapped but no coupon field", level: .warn)
                }
                if !status.isEmpty { Text(status).foregroundColor(.secondary) }
            }
        }
        .navigationTitle("Checkout")
        .replayIQScreen("Checkout")
    }

    private func pay() {
        paying = true
        ReplayIQ.track("checkout_started", properties: ["total": cart.total])
        ReplayIQ.log("pay tapped, total \(cart.total)")
        API.get("http://127.0.0.1:8080/health") { code in
            API.get("http://127.0.0.1:9/payments/authorize") { code2 in
                DispatchQueue.main.async {
                    paying = false
                    if code2 == 0 {
                        status = "Payment failed (health \(code), payments unreachable)"
                        ReplayIQ.log("payment service unreachable", level: .error)
                    } else {
                        status = "Paid"
                    }
                }
            }
        }
    }
}

/// Mostly a map: in `.auto` mode this screen is recorded as screenshots.
struct StoreMapView: View {
    @State private var region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.009),
                                                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))

    var body: some View {
        VStack(spacing: 0) {
            Map(coordinateRegion: $region)
            Text("3 stores nearby").padding()
        }
        .navigationTitle("Stores")
        .replayIQScreen("Store map")
    }
}

enum API {
    /// A custom session with the default configuration (recorded too).
    static let session = URLSession(configuration: .default)

    static func get(_ url: String, completion: @escaping (Int) -> Void) {
        session.dataTask(with: URL(string: url)!) { _, response, _ in
            completion((response as? HTTPURLResponse)?.statusCode ?? 0)
        }.resume()
    }
}

struct DebugView: View {
    @State private var diagnostics = ""

    var body: some View {
        List {
            Section("Diagnostics") {
                Button("Refresh diagnostics") {
                    let d = ReplayIQ.diagnostics
                    diagnostics = (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys]))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                }
                Button("Reset diagnostics") { ReplayIQ.resetDiagnostics(); diagnostics = "" }
                Text(diagnostics).font(.system(size: 8).monospaced()).lineLimit(40)
                    .accessibilityIdentifier("diagnostics")
            }
            Button("Log info") { ReplayIQ.log("debug: info line") }
            Button("Log warning") { ReplayIQ.log("debug: something looks off", level: .warn) }
            Button("Log error") { ReplayIQ.log("debug: something failed", level: .error) }
            Button("Fetch via URLSession.shared") {
                URLSession.shared.dataTask(with: URL(string: "http://127.0.0.1:8080/health?probe=1")!).resume()
            }
            Button("Flush now") { ReplayIQ.flush() }
            Section("Crashes (sent on next launch)") {
                Button("Throw NSException") { NSArray().object(at: 5) }.foregroundColor(.red)
                Button("Segfault") { UnsafeMutablePointer<Int>(bitPattern: 8)!.pointee = 1 }.foregroundColor(.red)
            }
            Section("Session") {
                Text(ReplayIQ.sessionId ?? "not recording").font(.footnote.monospaced()).textSelection(.enabled).accessibilityIdentifier("sessionId")
                Button("End session (stop)") { ReplayIQ.stop() }
            }
        }
        .navigationTitle("Debug")
        .replayIQScreen("Debug")
    }
}
