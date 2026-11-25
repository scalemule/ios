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
    let select: (GiftRecipient) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var people: [GiftRecipient] = []
    @State private var search = ""
    @State private var loading = true
    @State private var failed = false

    private var matching: [GiftRecipient] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? people : people.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                if loading { ProgressView("Loading people…") }
                else if failed {
                    Text("People couldn’t load. Your credits have not been spent.")
                    Button("Try again") { Task { await refresh() } }
                } else if people.isEmpty {
                    Text("Follow someone or explore other people's posts to find someone to send a gift to.")
                    Button("Refresh people") { Task { await refresh() } }
                } else if matching.isEmpty { Text("No matching people.") }
                ForEach(matching) { person in
                    Button {
                        select(person)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: person.avatarURL) { image in image.resizable().scaledToFill() }
                                placeholder: { Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary) }
                                .frame(width: 40, height: 40).clipShape(Circle())
                            Text(person.name).foregroundStyle(.primary)
                        }.padding(.vertical, 4)
                    }.accessibilityIdentifier("giftRecipient")
                }
            }
            .searchable(text: $search, prompt: "Find a person")
            .navigationTitle("Send to")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await refresh() }
        }
    }

    @MainActor private func refresh() async {
        loading = true; failed = false
        defer { loading = false }
        do { people = try await load() }
        catch { failed = true }
    }
}
