import Foundation
import ScaleMuleCore

extension AuthService {
    // MARK: - A18: Change Phone

    public func changePhone(newPhone: String) async -> ApiResponse<ChangePhoneResult> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/phone/change",
            body: ["new_phone": newPhone],
            credential: .sessionToken
        ))
    }
}
