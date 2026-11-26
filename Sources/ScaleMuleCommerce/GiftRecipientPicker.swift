import SwiftUI

/// A public display identity supplied by the host app, never an email address.
public struct GiftRecipient: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let avatarURL: URL?

    public init(id: String, name: String, avatarURL: URL? = nil) {
        self.id = id; self.name = name; self.avatarURL = avatarURL
    }

    /// Keep the host's ordering, removing self, blocked people and duplicates.
    public static func eligible(_ people: [GiftRecipient], currentUserID: String, blockedIDs: Set<String> = []) -> [GiftRecipient] {
        let key: (String) -> String = { $0.replacingOccurrences(of: "-", with: "").lowercased() }
        let excluded = Set(blockedIDs.map(key)).union([key(currentUserID)])
        var seen = excluded
        return people.filter { !$0.id.isEmpty && seen.insert(key($0.id)).inserted }
    }
}

struct GiftRecipientPicker: View {
    let load: @MainActor () async throws -> [GiftRecipient]
    var selectedID: String? = nil
    let select: (GiftRecipient) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var people: [GiftRecipient] = []
    @State private var search = ""
    @State private var loading = true
    @State private var failed = false
    @State private var reload = 0

    var body: some View {
        NavigationStack {
            GiftRecipientPickerContent(people: people, selectedID: selectedID,
                search: $search, loading: loading, failed: failed,
                retry: { reload += 1 }) { person in
                    select(person)
                    dismiss()
                }
                .navigationTitle("Send to").giftInlineNavigation()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { dismiss() } label: { Image(systemName: "xmark").font(.body.weight(.semibold)) }
                            .accessibilityLabel("Close recipient picker")
                    }
                }
                .task(id: reload) { await refresh() }
        }
        .giftSheet(height: 560)
    }

    @MainActor private func refresh() async {
        loading = true; failed = false
        defer { loading = false }
        do {
            let result = try await load()
            guard !Task.isCancelled else { return }
            people = result
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}

/// The same content is rendered in visual checks, including long names and empty states.
struct GiftRecipientPickerContent: View {
    let people: [GiftRecipient]
    let selectedID: String?
    @Binding var search: String
    var loading = false
    var failed = false
    let retry: () -> Void
    let select: (GiftRecipient) -> Void
    @Environment(\.giftTheme) private var theme

    private var matching: [GiftRecipient] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? people : people.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        VStack(spacing: 8) {
            GiftRecipientSearchField(text: $search).padding(.horizontal, 20).padding(.top, 12)
            ScrollView {
                LazyVStack(spacing: 2) {
                    if loading && people.isEmpty {
                        VStack(spacing: 14) {
                            ProgressView().tint(theme.accent)
                            Text("Finding people…").font(.subheadline).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: 180)
                    } else if failed && people.isEmpty {
                        GiftRecipientEmptyState(symbol: "wifi.exclamationmark", title: "People couldn’t load",
                            detail: "Check your connection and try again.", action: "Try again", perform: retry)
                    } else if people.isEmpty {
                        GiftRecipientEmptyState(symbol: "person.2", title: "Find your people",
                            detail: "People you follow and discover in the feed will appear here.", action: "Refresh", perform: retry)
                    } else if matching.isEmpty {
                        GiftRecipientEmptyState(symbol: "magnifyingglass", title: "No people found",
                            detail: "Try another name or clear your search.", action: "Clear search", perform: { search = "" })
                    } else {
                        ForEach(matching) { person in
                            Button { select(person) } label: {
                                GiftRecipientOptionRow(person: person, selected: person.id == selectedID)
                            }.buttonStyle(GiftRecipientOptionRowButtonStyle())
                                .accessibilityIdentifier("giftRecipient")
                                .accessibilityLabel(person.name)
                                .accessibilityHint(person.id == selectedID ? "Current recipient. Returns to your gift." : "Choose recipient and return to your gift.")
                                .accessibilityAddTraits(person.id == selectedID ? .isSelected : [])
                        }
                    }
                }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 20)
            }.scrollDismissesKeyboard(.interactively)
        }
    }
}

struct GiftRecipientSearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool
    @Environment(\.giftTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.body.weight(.medium)).foregroundStyle(.secondary)
            input.textFieldStyle(.plain).focused($focused).submitLabel(.search).autocorrectionDisabled()
                .accessibilityIdentifier("giftRecipientSearch")
            if !text.isEmpty {
                Button { text = ""; focused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 15).padding(.trailing, text.isEmpty ? 15 : 3)
        .frame(minHeight: 50)
        .background(theme.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(focused ? theme.accent.opacity(0.7) : Color.primary.opacity(0.08), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture { focused = true }
    }
    @ViewBuilder private var input: some View {
        #if os(iOS)
        TextField("Search people", text: $text).textInputAutocapitalization(.never)
        #else
        TextField("Search people", text: $text)
        #endif
    }
}

struct GiftRecipientOptionRow: View {
    let person: GiftRecipient
    let selected: Bool
    @Environment(\.giftTheme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            GiftPersonAvatar(person: person, placeholderFont: .system(.title3, design: .rounded).weight(.semibold))
                .frame(width: 52, height: 52)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                Text(person.name).font(.headline).foregroundStyle(.primary)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                if selected { Text("Current recipient").font(.caption).foregroundStyle(theme.accent) }
            }
            Spacer(minLength: 6)
            Image(systemName: selected ? "checkmark.circle.fill" : "chevron.right")
                .font(selected ? .title3 : .caption.weight(.semibold))
                .foregroundStyle(selected ? theme.accent : Color.secondary.opacity(0.6))
                .frame(width: 24)
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(selected ? theme.accent.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .ignore)
    }
}

private struct GiftRecipientOptionRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
    }
}

struct GiftRecipientEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    let action: String
    let perform: () -> Void
    @Environment(\.giftTheme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 28, weight: .medium))
                .foregroundStyle(theme.accent).frame(width: 68, height: 68)
                .background(theme.accent.opacity(0.08), in: Circle()).padding(.bottom, 4)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(action, action: perform).buttonStyle(GiftOutlineButtonStyle()).padding(.top, 6)
        }.padding(.horizontal, 24).padding(.vertical, 34).frame(maxWidth: .infinity)
    }
}
