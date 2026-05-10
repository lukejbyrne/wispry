import CryptoKit
import Foundation

struct LicensePayload: Decodable {
    let v: Int
    let product: String
    let plan: String
    let source: String
    let licenseID: String
    let emailSHA256: String
    let issuedAt: String

    enum CodingKeys: String, CodingKey {
        case v
        case product
        case plan
        case source
        case licenseID = "license_id"
        case emailSHA256 = "email_sha256"
        case issuedAt = "issued_at"
    }

    var displayPlan: String {
        switch plan {
        case "founding_lifetime":
            return "Founding lifetime"
        case "skool_member":
            return "Skool member"
        default:
            return plan.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

enum LicenseManager {
    private static let publicKeyBase64 = "DJuLA4imweGqyoFrE1B2GWNwccTMOVnBhKE7DdHSU7w="

    static func payload(for key: String?) -> LicensePayload? {
        guard let key else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".").map(String.init)
        guard parts.count == 3, parts[0] == "IDT1" else { return nil }
        guard let payloadData = base64URLDecode(parts[1]),
              let signatureData = base64URLDecode(parts[2]),
              let publicKeyData = Data(base64Encoded: publicKeyBase64) else {
            return nil
        }

        do {
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
            guard publicKey.isValidSignature(signatureData, for: payloadData) else { return nil }
            let payload = try JSONDecoder().decode(LicensePayload.self, from: payloadData)
            guard payload.v == 1, payload.product == "idonttype" else { return nil }
            return payload
        } catch {
            return nil
        }
    }

    static func isValid(_ key: String?) -> Bool {
        payload(for: key) != nil
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: padding))
        }
        return Data(base64Encoded: base64)
    }
}
