import Foundation
import ScaleMuleCore

extension AuthService {
    // MARK: - A14: Forgot Password

    public func forgotPassword(email: String) async -> ApiResponse<MessageResult> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/forgot-password",
            body: ["email": email],
            credential: .none
        ))
    }

    // MARK: - A15: Reset Password

    public func resetPassword(token: String, newPassword: String) async -> ApiResponse<MessageResult> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/reset-password",
            body: ["token": token, "new_password": newPassword],
            credential: .none
        ))
    }

    // MARK: - A16: Change Password

    public func changePassword(currentPassword: String, newPassword: String) async -> ApiResponse<MessageResult> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/password/change",
            body: ["current_password": currentPassword, "new_password": newPassword],
            credential: .sessionToken
        ))
    }
}
