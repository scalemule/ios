import Foundation
import Network

public actor NetworkMonitor {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private var isMonitoring = false

    public private(set) var isConnected: Bool = true
    public private(set) var connectionType: ConnectionType = .unknown

    public enum ConnectionType: Sendable {
        case wifi
        case cellular
        case wiredEthernet
        case unknown
    }

    public init() {
        self.monitor = NWPathMonitor()
        self.queue = DispatchQueue(label: "com.scalemule.sdk.network-monitor")
    }

    public func start() {
        guard !isMonitoring else { return }
        isMonitoring = true

        let monitor = self.monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task {
                await self.updatePath(path)
            }
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.cancel()
        isMonitoring = false
    }

    private func updatePath(_ path: NWPath) {
        isConnected = path.status == .satisfied

        if path.usesInterfaceType(.wifi) {
            connectionType = .wifi
        } else if path.usesInterfaceType(.cellular) {
            connectionType = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            connectionType = .wiredEthernet
        } else {
            connectionType = .unknown
        }
    }
}
