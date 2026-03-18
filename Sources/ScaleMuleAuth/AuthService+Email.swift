import Foundation
import ScaleMuleCore

extension AuthService {
    // MARK: - A03: Verify Email

    public func verifyEmail(token: String) async -> ApiResponse<VerifyEmailResult> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/verify-email",
            body: ["token": token],
            credential: .none
        ))
    }

    // MARK: - A04: Resend Verification

    public func resendVerification(email: String) async -> ApiResponse<MessageResult> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/resend-verification",
            body: ["email": email],
            credential: .none
        ))
    }

    // MARK: - A17: Change Email

    public func changeEmail(newEmail: String, password: String) async -> ApiResponse<MessageResult> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/email/change",
            body: ["new_email": newEmail, "password": password],
            credential: .sessionToken
        ))
    }
}
