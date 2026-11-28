#if os(iOS)
import SwiftUI

/// A searchable list of countries for a phone number field: flag, name and
/// calling code, with a tick on the one in use. Show it in a sheet from the
/// button that carries the flag and code; it sets `selection` and calls
/// `onDone` when a country is picked or Cancel is pressed.
///
///     .sheet(isPresented: $choosingCountry) {
///         PhoneCountryPicker(selection: $country) { choosingCountry = false }
///     }
///
/// It uses the system's own list, search box and colours, so it follows the
/// app's tint and light or dark appearance.
public struct PhoneCountryPicker: View {
    @Binding private var selection: PhoneCountry
    private let countries: [PhoneCountry]
    private let onDone: () -> Void

    @State private var query = ""

    /// `countries`: pass an app's own list to offer fewer countries.
    public init(
        selection: Binding<PhoneCountry>,
        countries: [PhoneCountry] = PhoneCountry.all,
        onDone: @escaping () -> Void
    ) {
        _selection = selection
        self.countries = countries
        self.onDone = onDone
    }

    public var body: some View {
        let shown = PhoneCountry.matching(query, in: countries)
        NavigationStack {
            List(shown) { country in
                Button {
                    selection = country
                    onDone()
                } label: {
                    HStack(spacing: 12) {
                        Text(country.flag)
                            .font(.title3)
                        Text(country.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(country.dialCode)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                            .opacity(country == selection ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(country.name), \(country.dialCode)")
                .accessibilityAddTraits(country == selection ? .isSelected : [])
                .accessibilityIdentifier("phoneCountry-\(country.code)")
            }
            .listStyle(.plain)
            .overlay {
                if shown.isEmpty {
                    Text("No countries found")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("phoneCountryNoneFound")
                }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search countries"
            )
            .autocorrectionDisabled()
            .navigationTitle("Country")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDone)
                }
            }
        }
    }
}
#endif
