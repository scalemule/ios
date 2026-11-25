import Foundation
import Combine
import ScaleMuleCore

/// The requests waiting for the signed-in person's answer: a list for a
/// "Requests" screen and a count for a badge. One per signed-in person;
/// `load()` when the app opens, comes back to the front, or a
/// `connect_request` notification arrives.
@MainActor
public final class ConnectionRequestsModel: ObservableObject {
    /// Newest first.
    @Published public private(set) var requests: [ConnectionRequest] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var hasLoaded = false
    @Published public var errorMessage: String?
    /// Goes up each time a connection is made or ended here, so screens that
    /// show one person's state know to ask again.
    @Published public private(set) var changes = 0

    public var count: Int { requests.count }

    private var service: ConnectionsService?
    private var working: Set<String> = []
    /// People to leave out (blocked).
    public var hiddenUserIds: Set<String> = [] {
        didSet { requests.removeAll { hides($0.fromUserId) } }
    }

    public init() {}

    public func attach(_ service: ConnectionsService) {
        self.service = service
    }

    /// Forget everything (sign-out).
    public func reset() {
        service = nil
        requests = []
        hasLoaded = false
        errorMessage = nil
        working = []
        hiddenUserIds = []
    }

    public func load() async {
        guard let service, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        switch await service.incoming() {
        case .success(let list):
            requests = list.filter { $0.isPending && !hides($0.fromUserId) }
            hasLoaded = true
            errorMessage = nil
        case .failure(let error):
            // A server without connections has no requests; that is not an error.
            if error.statusCode == 404 {
                requests = []
                hasLoaded = true
            } else if !hasLoaded {
                errorMessage = error.userFacingMessage
            }
        }
    }

    public func isWorking(on request: ConnectionRequest) -> Bool { working.contains(request.id) }

    @discardableResult
    public func accept(_ request: ConnectionRequest) async -> Bool {
        await answer(request) { await $0.accept(requestId: request.id) }
    }

    @discardableResult
    public func decline(_ request: ConnectionRequest) async -> Bool {
        await answer(request) { await $0.decline(requestId: request.id) }
    }

    @discardableResult
    public func report(_ request: ConnectionRequest) async -> Bool {
        await answer(request) { await $0.report(requestId: request.id) }
    }

    /// Something elsewhere changed a connection (a profile's button).
    public func noteChange(removingRequestFrom userId: String? = nil) {
        if let userId { requests.removeAll { ConnectionID.same($0.fromUserId, userId) } }
        changes += 1
    }

    private func answer(_ request: ConnectionRequest, _ call: (ConnectionsService) async -> ApiResponse<ConnectionRequestResult>) async -> Bool {
        guard let service, !working.contains(request.id) else { return false }
        working.insert(request.id)
        defer { working.remove(request.id) }
        switch await call(service) {
        case .success:
            requests.removeAll { $0.id == request.id }
            errorMessage = nil
            changes += 1
            return true
        case .failure(let error):
            // Withdrawn or answered on another phone: it is gone either way.
            if error.statusCode == 404 || error.statusCode == 409 {
                requests.removeAll { $0.id == request.id }
                changes += 1
            } else {
                errorMessage = error.userFacingMessage
            }
            return false
        }
    }

    private func hides(_ userId: String) -> Bool {
        hiddenUserIds.contains { ConnectionID.same($0, userId) }
    }
}

/// What the signed-in person is to one other person, for the buttons on a
/// profile or a chat screen: Connect, Requested, Accept, Message.
@MainActor
public final class ConnectionModel: ObservableObject {
    /// Nil until the first answer.
    @Published public private(set) var state: ConnectionState?
    @Published public private(set) var isWorking = false
    @Published public var errorMessage: String?

    public let userId: String
    private let service: ConnectionsService
    private weak var requests: ConnectionRequestsModel?
    private var watching: AnyCancellable?

    public init(userId: String, service: ConnectionsService, requests: ConnectionRequestsModel? = nil) {
        self.userId = userId
        self.service = service
        self.requests = requests
        watching = requests?.$changes.dropFirst().sink { [weak self] _ in
            Task { await self?.load() }
        }
    }

    public func load() async {
        switch await service.state(with: userId) {
        case .success(let found):
            state = found
            errorMessage = nil
        case .failure(let error):
            if state == nil { errorMessage = error.userFacingMessage }
        }
    }

    /// Ask to connect. Returns true when the request went out (or the two
    /// are now connected because they had asked first).
    @discardableResult
    public func connect(note: String? = nil) async -> Bool {
        await work {
            switch await self.service.request(userId: self.userId, note: note) {
            case .success(let result):
                if result.isConnected {
                    self.state = ConnectionState(kind: .connected, canMessage: true, canRequest: false)
                    self.requests?.noteChange(removingRequestFrom: self.userId)
                } else {
                    self.state = ConnectionState(kind: .requestSent, requestId: result.id, canMessage: false, canRequest: false)
                }
                return nil
            case .failure(let error):
                if error.statusCode == 409 {
                    // Already connected.
                    await self.load()
                    return nil
                }
                return error
            }
        }
    }

    /// Accept the request this person sent me.
    @discardableResult
    public func accept() async -> Bool {
        guard let id = state?.requestId, state?.kind == .requestReceived else { return false }
        return await work {
            switch await self.service.accept(requestId: id) {
            case .success:
                self.state = ConnectionState(kind: .connected, canMessage: true, canRequest: false)
                self.requests?.noteChange(removingRequestFrom: self.userId)
                return nil
            case .failure(let error):
                return error
            }
        }
    }

    /// Decline the request this person sent me.
    @discardableResult
    public func decline() async -> Bool {
        guard let id = state?.requestId, state?.kind == .requestReceived else { return false }
        return await work {
            switch await self.service.decline(requestId: id) {
            case .success:
                self.requests?.noteChange(removingRequestFrom: self.userId)
                await self.load()
                return nil
            case .failure(let error):
                return error
            }
        }
    }

    /// Take back the request I sent.
    @discardableResult
    public func withdraw() async -> Bool {
        guard let id = state?.requestId, state?.kind == .requestSent else { return false }
        return await work {
            switch await self.service.withdraw(requestId: id) {
            case .success:
                await self.load()
                return nil
            case .failure(let error):
                return error
            }
        }
    }

    /// End the connection.
    @discardableResult
    public func remove() async -> Bool {
        guard state?.kind == .connected else { return false }
        return await work {
            switch await self.service.remove(userId: self.userId) {
            case .success:
                self.requests?.noteChange()
                await self.load()
                return nil
            case .failure(let error):
                return error
            }
        }
    }

    private func work(_ body: @escaping () async -> ApiError?) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        if let error = await body() {
            errorMessage = error.statusCode == 429
                ? "You've sent a lot of requests today. Try again tomorrow."
                : error.userFacingMessage
            return false
        }
        errorMessage = nil
        return true
    }
}
