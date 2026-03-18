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

    public func verifyPhoneOtp(phone: String, code: String) async -> ApiResponse<LoginResult> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/phone/verify-otp",
            body: ["phone": phone, "code": code],
            credential: .none
        ))
    }

    // MARK: - A13: Resend Phone OTP

    public func resendPhoneOtp(phone: String) async -> ApiResponse<PhoneOtpResult> {
        await client.request(RequestOptions(
            method: .post,
            path: "/v1/auth/phone/resend-otp",
            body: ["phone": phone],
            credential: .none
        ))
    }
}
