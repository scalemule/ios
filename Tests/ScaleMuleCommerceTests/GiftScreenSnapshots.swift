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
        try write("wallet", height: 780) {
            VStack(alignment: .leading, spacing: 14) {
                CreditBalanceCard(credits: 80, caption: "Use credits to send gifts.")
                Text("Get credits").font(.title3.bold()).padding(.top, 10)
                CreditPackRow(credits: 100, name: "100 Firehosy Credits", price: "$0.99") {}
                CreditPackRow(credits: 300, name: "300 Firehosy Credits", price: "$2.99") {}
                CreditPackRow(credits: 500, name: "Best value", price: "$4.99") {}
                Text("Your gifts").font(.title3.bold()).padding(.top, 14)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                    GiftCard(name: "Coffee") { art("coffee") }
                    GiftCard(name: "Rose", count: 3) { art("rose") }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Payments are handled by Apple. Credits do not expire and cannot be transferred or withdrawn as cash.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Missing a purchase? Check again") {}.font(.footnote.weight(.semibold))
                }.padding(.top, 14)
            }.padding(.horizontal, 18).padding(.vertical, 16)
        }
    }

    func testShop() throws {
        try write("shop", height: 800) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    GiftRecipientRow(recipient: GiftRecipient(id: "1", name: "Maya"), canChange: true)
                    HStack(spacing: 10) {
                        CreditAmount(amount: 80, font: .title3.weight(.bold))
                        Text("credits").font(.subheadline).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Get credits") {}.buttonStyle(GiftOutlineButtonStyle())
                    }
                    .padding(.vertical, 12).padding(.horizontal, 14)
                    .background(theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Text("Choose a gift").font(.title3.bold()).padding(.top, 6)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 12)], spacing: 12) {
                        GiftCard(name: "Rose", price: 10) { art("rose") }
                        GiftCard(name: "Coffee", price: 20, isSelected: true) { art("coffee") }
                        GiftCard(name: "Ice Cream", price: 25) { art("ice-cream") }
                        GiftCard(name: "Heart", price: 30) { art("heart") }
                        GiftCard(name: "Fire", price: 50) { art("fire") }
                        GiftCard(name: "Nice Shot", price: 75) { art("camera") }
                    }
                }.padding(.horizontal, 18).padding(.vertical, 16)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        art("coffee").frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Coffee").font(.headline)
                            Text("Thanks for making my day.").font(.footnote).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        CreditAmount(amount: 20, font: .headline)
                    }
                    Button("Send to Maya") {}.buttonStyle(GiftPrimaryButtonStyle())
                }.padding(16).background(Color.white.opacity(0.1))
            }
        }
    }

    func testStates() throws {
        try write("states", height: 520) {
            VStack(alignment: .leading, spacing: 14) {
                GiftRecipientRow(recipient: nil, canChange: true)
                GiftNotice(text: "Your purchase is still being confirmed. Credits will appear shortly.")
                GiftNotice(text: "Gifts couldn’t load. Check your connection.", isError: true)
                Button("Connect to App Store") {}.buttonStyle(GiftPrimaryButtonStyle())
                Button("Get credits") {}.buttonStyle(GiftPrimaryButtonStyle()).disabled(true)
                HStack { Button("Try again") {}.buttonStyle(GiftOutlineButtonStyle()); Button("$4.99") {}.buttonStyle(GiftPillButtonStyle()) }
                CreditBalanceCard(credits: nil)
            }.padding(18)
        }
    }
}
#endif
