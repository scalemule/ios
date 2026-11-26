#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import ScaleMuleCommerce

/// Draws the gift screens' building blocks to PNG files so a change to their
/// look can be reviewed by eye. Runs only when GIFT_SNAPSHOT_DIR names a folder
/// to write to (and GIFT_SNAPSHOT_ART a folder of `<slug>-256.png` pictures).
@MainActor
final class GiftScreenSnapshots: XCTestCase {
    private var theme: GiftTheme {
        GiftTheme(accent: Color(red: 184 / 255, green: 242 / 255, blue: 227 / 255),
                  onAccent: Color(red: 9 / 255, green: 61 / 255, blue: 50 / 255))
    }

    private func art(_ slug: String) -> some View {
        Group {
            if let folder = ProcessInfo.processInfo.environment["GIFT_SNAPSHOT_ART"],
               let image = NSImage(contentsOfFile: folder + "/\(slug)-256.png") {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "gift").resizable().scaledToFit().padding(20).foregroundStyle(.secondary)
            }
        }
    }

    private func write<V: View>(_ name: String, height: CGFloat, @ViewBuilder _ view: () -> V) throws {
        guard let folder = ProcessInfo.processInfo.environment["GIFT_SNAPSHOT_DIR"] else { throw XCTSkip("GIFT_SNAPSHOT_DIR is not set") }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let screen = view()
            .frame(width: 393, height: height, alignment: .top)
            .background(Color.black)
            .giftTheme(theme)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: screen)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let data = try XCTUnwrap(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
    }

    func testWallet() throws {
        try write("recharge", height: 480) {
            VStack(alignment: .leading, spacing: 22) {
                HStack { Text("Recharge").font(.headline); Spacer(); Text("Done").foregroundStyle(theme.accent) }
                HStack { Text("Your credits").foregroundStyle(.secondary); Spacer(); CreditAmount(amount: 80) }
                Text("A little appreciation goes a long way.").font(.title3.weight(.semibold))
                HStack(spacing: 10) {
                    RechargePackTile(credits: 100, price: "$0.99", selected: true)
                    RechargePackTile(credits: 300, price: "$2.99", selected: false)
                    RechargePackTile(credits: 500, price: "$4.99", selected: false)
                }
                Text("Credits never expire. Gifts are digital items and can’t be exchanged for cash.").font(.footnote).foregroundStyle(.secondary)
                Button("Recharge · $0.99") {}.buttonStyle(GiftPrimaryButtonStyle())
                Text("Secure payment with Apple").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }.padding(20)
        }
    }

    func testShop() throws {
        let gifts: [(String, String, Int64)] = [("rose", "Rose", 10), ("coffee", "Coffee", 20), ("ice-cream", "Ice Cream", 25), ("heart", "Heart", 30), ("fire", "Fire", 50), ("star", "Star", 50), ("camera", "Nice Shot", 75), ("camel", "Camel", 100), ("rocket", "Rocket", 150), ("globe", "The World", 200)]
        try write("gift-tray", height: 540) {
            VStack(spacing: 14) {
                HStack { Text("Send a gift").font(.headline); Spacer(); Text("Close").foregroundStyle(theme.accent) }
                HStack(spacing: 10) {
                    GiftPersonAvatar(person: GiftRecipient(id: "1", name: "Maya")).frame(width: 32, height: 32)
                    Text("To Maya").font(.headline); Spacer()
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 10) {
                    ForEach(gifts, id: \.0) { gift in
                        GiftTrayTile(name: gift.1, credits: gift.2, selected: gift.0 == "coffee") { self.art(gift.0) }
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        CreditAmount(amount: 80)
                        Text("Recharge").font(.subheadline.weight(.semibold)).foregroundStyle(theme.accent)
                    }
                    Spacer()
                    Button("Send · 20") {}.buttonStyle(GiftPillButtonStyle())
                }
            }.padding(18)
        }
    }

    private func received(_ slug: String, name: String) throws -> DigitalGift {
        let url = "https://example.com/\(slug).png"
        return try JSONDecoder().decode(DigitalGift.self, from: Data("""
        {"id":"gift-\(slug)","sender_id":"person","recipient_id":"me","product_id":"p","environment":"Sandbox","quantity":1,"total_minor":20,"currency_code":"FHC","status":"delivered","product_snapshot":{"display_name":"\(name)","artwork_url":"\(url)","kind":"both"},"created_at":"2026-11-25T08:07:47Z","delivered_at":"2026-11-25T08:07:47Z"}
        """.utf8))
    }

    func testReceivedCollection() throws {
        let coffee = try received("coffee", name: "Coffee")
        let rose = try received("rose", name: "Rose")
        try write("received-collection", height: 730) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Your gifts").font(.largeTitle.bold())
                Text("From people who appreciate your moments.").foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ReceivedGiftCard(gift: coffee, sender: GiftRecipient(id: "a", name: "Plamen")) { art("coffee") }
                    ReceivedGiftCard(gift: rose, sender: GiftRecipient(id: "b", name: "Мария")) { art("rose") }
                }
            }.padding(18)
        }
    }

    func testArrival() throws {
        let coffee = try received("coffee", name: "Coffee")
        try write("gift-arrival", height: 780) {
            VStack {
                GiftMomentContent(gift: coffee, sender: GiftRecipient(id: "a", name: "Plamen"), isNew: true) { art("coffee") }
                Spacer()
                Button("See your gifts") {}.buttonStyle(GiftPrimaryButtonStyle())
            }.padding(24)
        }
    }

    func testStates() throws {
        try write("empty-collection", height: 450) {
            VStack {
                HStack { Text("Your gifts").font(.headline); Spacer(); Text("Done").foregroundStyle(theme.accent) }.padding(20)
                ReceivedGiftEmptyState()
            }
        }
        try write("delivery-retry", height: 300) {
            VStack(alignment: .leading, spacing: 16) {
                GiftNotice(text: "Your gift is saved. Retry delivery when you’re back online.")
                Button("Retry delivery") {}.buttonStyle(GiftOutlineButtonStyle())
                Text("Credits couldn’t load.").font(.footnote).foregroundStyle(.secondary)
                Button("Retry") {}.buttonStyle(GiftOutlineButtonStyle())
            }.padding(20)
        }
    }
}
#endif
