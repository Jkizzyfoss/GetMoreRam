//
//  OnDeviceAnisetteHelper.swift
//  GetMoreRam
//
//  Bridge between GetMoreRam and SideSign/AnisetteKit for obtaining anisette
//  data in the two supported configurations:
//
//   * on-device — the ADI libraries are cached and executed locally through
//     SideSign's `.remoteODA` mode (no Anisette HTTP server involved).
//   * remote    — a normal v3 Anisette server is queried through
//     AnisetteDataHelper. The server's advertised client profile is used so the
//     Anisette headers always match the identity reported to GrandSlam.
//
//  Both paths keep the device identifier and adi.pb in the Keychain and only
//  reprovision when Apple explicitly says the provisioning data is stale, or when
//  the provider itself changed.
//

import Foundation
import CryptoKit
import Security
import AnisetteKit
import SideSign
import StosSign_Common

final class OnDeviceAnisetteHelper {
    static let shared = OnDeviceAnisetteHelper()

    private let provider = SideSign.AnisetteDataManager.shared
    private let metadataURL = URL(string: "https://zzz.haus/oda.json")!

    private init() {}

    // MARK: - On-device (ODA)

    /// Anisette data generated locally by the cached ADI libraries.
    func getSideSignAnisetteData() async throws -> SideSign.AnisetteData {
        // The on-device option is its own provider: switching to/away from it
        // invalidates any identity provisioned against the previous provider.
        AnisetteProviderState.updateProvider("ondevice")

        let identifier = try ensureIdentifier()
        let existingBlob = Keychain.shared.adiPb.flatMap {
            Data(base64Encoded: $0, options: .ignoreUnknownCharacters)
        }

        let requestHeaders = makeRequestHeaders(identifier: identifier)

        do {
            let result = try await fetch(
                identifier: identifier,
                existingBlob: existingBlob,
                headers: requestHeaders
            )
            if let newBlob = result.newAdiBlob {
                Keychain.shared.adiPb = newBlob.base64EncodedString()
            }
            return result.data
        } catch {
            // Only a confirmed unprovisioned ADI error warrants reprovisioning.
            // Network/parse failures must preserve the existing identity/blob.
            guard existingBlob != nil,
                  let adiError = error as? AnisetteKit.AnisetteError,
                  case .adiError(let code, _) = adiError,
                  code == -45061 else { throw error }
            let result = try await fetch(
                identifier: identifier,
                existingBlob: nil,
                headers: requestHeaders
            )
            if let newBlob = result.newAdiBlob {
                Keychain.shared.adiPb = newBlob.base64EncodedString()
            }
            return result.data
        }
    }

    // MARK: - Remote (v3 Anisette server)

    /// Anisette data from the configured remote v3 Anisette server.
    func getRemoteSideSignAnisetteData() async throws -> SideSign.AnisetteData {
        guard let serverURL = AnisetteSettings.serverURL else {
            throw NSError(
                domain: "GetMoreRam.Anisette",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "No Anisette server is configured."]
            )
        }

        // The ADI identity is bound to the provider that minted it, so a server
        // switch needs a fresh identity/adi.pb. This never fires for a plain
        // network error against the same server.
        AnisetteProviderState.updateProvider("remote:\(serverURL.absoluteString)")

        let helper = AnisetteDataHelper.shared
        helper.url = serverURL
        try await helper.fetchClientInfo()

        let stosSignAnisette = try await helper.getAnisetteData()
        return convertToSideSign(
            stosSignAnisette,
            clientInfo: helper.clientInfo ?? AnisetteClientInfo.remoteDefault,
            userAgent: helper.userAgent ?? AnisetteClientInfo.windowsUserAgent
        )
    }

    // MARK: - SideSign / AnisetteKit plumbing

    /// Drops cached provider state (in-memory Anisette cache + recorded provider).
    func resetProviderState() {
        provider.clearCache()
        AnisetteProviderState.reset()
    }

    private func makeRequestHeaders(identifier: UUID) -> AnisetteRequestHeaders {
        // AnisetteKit otherwise supplies a constant placeholder local-user ID.
        // Bind LU and device ID to the same bytes used by the ADI provider.
        var identifierBytes = identifier.uuid
        let identifierData = withUnsafeBytes(of: &identifierBytes) { Data($0) }
        return AnisetteRequestHeaders.defaultHeaders.with {
            $0.clientInfo = AnisetteClientInfo.sanitized(
                AnisetteClientInfo.resolved(fallback: AnisetteClientInfo.onDeviceDefault),
                fallback: AnisetteClientInfo.onDeviceDefault)
            $0.userAgent = AnisetteClientInfo.windowsUserAgent
            $0.deviceID = identifier.uuidString.uppercased()
            $0.localUserID = SHA256.hash(data: identifierData)
                .map { String(format: "%02X", $0) }.joined()
        }
    }

    private func fetch(
        identifier: UUID,
        existingBlob: Data?,
        headers: AnisetteRequestHeaders
    ) async throws -> (data: SideSign.AnisetteData, newAdiBlob: Data?) {
        try await provider.fetchAnisetteData(
            mode: .remoteODA(sourceURL: metadataURL, fallbackURL: metadataURL),
            identifier: identifier,
            existingAdiBlob: existingBlob,
            headers: headers
        )
    }

    private func ensureIdentifier() throws -> UUID {
        if let stored = Keychain.shared.identifier, let uuid = uuid(from: stored) {
            return uuid
        }

        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw NSError(
                domain: "GetMoreRam.OnDeviceAnisette",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Could not generate Anisette device identifier."]
            )
        }

        let data = Data(bytes)
        Keychain.shared.identifier = data.base64EncodedString()
        guard let uuid = uuid(from: Keychain.shared.identifier!) else {
            throw NSError(
                domain: "GetMoreRam.OnDeviceAnisette",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Generated Anisette identifier is invalid."]
            )
        }
        return uuid
    }

    private func uuid(from value: String) -> UUID? {
        if let uuid = UUID(uuidString: value) {
            return uuid
        }
        guard let data = Data(base64Encoded: value, options: .ignoreUnknownCharacters), data.count == 16 else {
            return nil
        }
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            return UUID(uuid: baseAddress.load(as: uuid_t.self))
        }
    }

    /// Converts remote anisette data (StosSign model) into the SideSign model that
    /// `DeveloperPortal.authenticate` consumes, keeping the client identity that
    /// matches the server that produced it.
    func convertToSideSign(_ data: StosSign_Common.AnisetteData,
                           clientInfo: String,
                           userAgent: String) -> SideSign.AnisetteData {
        let dateFormatter = ISO8601DateFormatter()
        return SideSign.AnisetteData(
            machineID: data.machineID,
            oneTimePassword: data.oneTimePassword,
            localUserID: data.localUserID,
            routingInfo: String(data.routingInfo),
            deviceID: data.deviceUniqueIdentifier,
            serialNumber: data.deviceSerialNumber,
            clientInfo: AnisetteClientInfo.sanitized(clientInfo, fallback: AnisetteClientInfo.remoteDefault),
            userAgent: userAgent.isEmpty ? AnisetteClientInfo.windowsUserAgent : userAgent,
            clientTime: dateFormatter.string(from: data.date),
            locale: data.locale.identifier,
            timeZone: data.timeZone.abbreviation() ?? data.timeZone.identifier
        )
    }

    func convert(_ data: SideSign.AnisetteData) throws -> StosSign_Common.AnisetteData {
        guard let routingInfo = UInt64(data.routingInfo) else {
            throw NSError(
                domain: "GetMoreRam.OnDeviceAnisette",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Local Anisette returned an invalid routing-info value."]
            )
        }

        let dateFormatter = ISO8601DateFormatter()
        guard let date = dateFormatter.date(from: data.clientTime) else {
            throw NSError(
                domain: "GetMoreRam.OnDeviceAnisette",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Local Anisette returned an invalid client time."]
            )
        }

        return StosSign_Common.AnisetteData(
            machineID: data.machineID,
            oneTimePassword: data.oneTimePassword,
            localUserID: data.localUserID,
            routingInfo: routingInfo,
            deviceUniqueIdentifier: data.deviceID,
            deviceSerialNumber: data.serialNumber,
            deviceDescription: data.clientInfo,
            date: date,
            locale: Locale(identifier: data.locale),
            timeZone: TimeZone(abbreviation: data.timeZone) ?? .current
        )
    }
}
