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

// MARK: - Profile

extension AuthService {
    /// Change the signed-in person's own profile. Only the fields you pass
    /// change. On success the auth state carries the updated user.
    public func updateProfile(
        fullName: String? = nil,
        username: String? = nil,
        avatarUrl: String? = nil,
        locale: String? = nil,
        timeZone: String? = nil
    ) async -> ApiResponse<AuthUser> {
        var body: [String: Any] = [:]
        if let fullName { body["full_name"] = fullName }
        if let username { body["username"] = username }
        if let avatarUrl { body["avatar_url"] = avatarUrl }
        if let locale { body["locale"] = locale }
        if let timeZone { body["time_zone"] = timeZone }
        guard !body.isEmpty else {
            return .failure(ApiError(code: .validationError, message: "Nothing to change", statusCode: 400))
        }

        let result: ApiResponse<AuthUser> = await client.request(RequestOptions(
            method: .patch,
            path: "/v1/auth/profile",
            body: body,
            credential: .sessionToken
        ))
        if case .success(let user) = result {
            await app?.sessionManager.rememberUser(user)
            await app?.authState.transition(to: .authenticated(user))
        }
        return result
    }

}
