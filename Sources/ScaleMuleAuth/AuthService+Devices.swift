import Foundation
import ScaleMuleCore

public final class AuthDevicesSubService: Sendable {
    private let client: HTTPClient

    init(client: HTTPClient) {
        self.client = client
    }

    // MARK: - A27: List Devices

    public func list() async -> ApiResponse<DeviceListResult> {
        await client.request(RequestOptions(
            method: .get,
            path: "/v1/auth/devices",
            credential: .sessionToken
        ))
    }

    // MARK: - A28: Trust Device

    public func trust(deviceId: String) async -> ApiResponse<MessageResult> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/devices/\(deviceId)/trust",
            credential: .sessionToken
        ))
    }

    // MARK: - A29: Block Device

    public func block(deviceId: String) async -> ApiResponse<MessageResult> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/devices/\(deviceId)/block",
            credential: .sessionToken
        ))
    }

    // MARK: - A30: Delete Device

    public func delete(deviceId: String) async -> ApiResponse<EmptyResponse> {
        await client.requestVoid(RequestOptions(
            method: .delete,
            path: "/v1/auth/devices/\(deviceId)",
            credential: .sessionToken
        ))
    }
}
