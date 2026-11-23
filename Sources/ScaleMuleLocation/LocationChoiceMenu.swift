#if os(iOS)
import SwiftUI
import ScaleMuleSocial

/// What the person picked to share: a kind, and which venue for `.place`.
public struct LocationSelection: Equatable, Sendable, Codable {
    public var kind: LocationChoiceKind
    public var placeIndex: Int

    public init(kind: LocationChoiceKind, placeIndex: Int = 0) {
        self.kind = kind
        self.placeIndex = placeIndex
    }

    /// The public point to send with the post (nil for `.none`).
    public func location(in choices: LocationChoices?) -> SharedLocation? {
        choices?.location(for: kind, place: placeIndex)
    }
}

/// A menu for a share screen: each venue nearby, the city (or "near" the
/// nearest one), the exact spot and no location, limited to what the app
/// allows. The label is the app's own, given the current choice's text.
public struct LocationChoiceMenu<Label: View>: View {
    let choices: LocationChoices
    let settings: LocationSettings
    @Binding var selection: LocationSelection
    let label: (String?, LocationChoiceKind) -> Label

    public init(
        choices: LocationChoices,
        settings: LocationSettings = .standard,
        selection: Binding<LocationSelection>,
        @ViewBuilder label: @escaping (_ text: String?, _ kind: LocationChoiceKind) -> Label
    ) {
        self.choices = choices
        self.settings = settings
        _selection = selection
        self.label = label
    }

    public var body: some View {
        let available = choices.available(settings)
        Menu {
            if available.contains(.place) {
                Section("Place") {
                    ForEach(Array(choices.places.enumerated()), id: \.offset) { index, place in
                        button(place.label ?? "This place", symbol: "building.columns", selection: LocationSelection(kind: .place, placeIndex: index))
                    }
                }
            }
            if available.contains(.city), let city = choices.label(for: .city) {
                button(city, symbol: "building.2", selection: LocationSelection(kind: .city))
            }
            if available.contains(.exact) {
                button("Exact spot", symbol: "mappin", selection: LocationSelection(kind: .exact))
            }
            button("No location", symbol: "location.slash", selection: LocationSelection(kind: .none))
        } label: {
            label(choices.label(for: selection.kind, place: selection.placeIndex), selection.kind)
        }
        .accessibilityIdentifier("locationChoice")
    }

    private func button(_ title: String, symbol: String, selection choice: LocationSelection) -> some View {
        Button {
            selection = choice
        } label: {
            if choice == selection {
                SwiftUI.Label(title, systemImage: "checkmark")
            } else {
                SwiftUI.Label(title, systemImage: symbol)
            }
        }
    }
}
#endif
