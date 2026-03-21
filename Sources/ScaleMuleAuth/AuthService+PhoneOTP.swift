import Foundation
import ScaleMuleCore

extension AuthService {
    // MARK: - A11: Send Phone OTP

    public func sendPhoneOtp(phone: String, purpose: OtpPurpose = .login) async -> ApiResponse<PhoneOtpResult> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/phone/send-otp",
            body: ["phone": phone, "purpose": purpose.rawValue],
            credential: .none
        ))
    }

    // MARK: - A12: Verify Phone OTP

    /// Backend returns `{ verified: true, message: "..." }`, NOT a login session.
    /// Clients should re-call `sendPhoneOtp` if they need to resend — there is no dedicated resend endpoint.
    public func verifyPhoneOtp(phone: String, code: String) async -> ApiResponse<VerifyPhoneOtpResult> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/phone/verify-otp",
            body: ["phone": phone, "code": code],
            credential: .none
        ))
    }
}
