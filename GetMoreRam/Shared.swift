//
//  Shared.swift
//  GetMoreRam
//
//  Created by s s on 2025/3/15.
//
import SwiftUI
// Selective import: `import SideSign` would make `Account`/`Team`/`TeamType`
// ambiguous with the StosSign_Common types used by the App ID/signing UI.
import class SideSign.AnisetteDataManager
import enum SideSign.ServerError
import enum SideSign.DeveloperPortalError
import StosSign_API
import StosSign_Auth
import StosSign_Common

class AlertHelper<T> : ObservableObject {
    @Published var show = false
    private var result : T?
    private var c : CheckedContinuation<Void, Never>? = nil
    
    func open() async -> T? {
        await withCheckedContinuation { c in
            self.c = c
            Task { await MainActor.run {
                self.show = true
            }}
        }
        return self.result
    }
    
    func close(result: T?) {
        if let c {
            self.result = result
            c.resume()
            self.c = nil
        }
        DispatchQueue.main.async {
            self.show = false
        }

    }
}
typealias YesNoHelper = AlertHelper<Bool>

class InputHelper : AlertHelper<String> {
    @Published var initVal = ""
    
    func open(initVal: String) async -> String? {
        self.initVal = initVal
        return await super.open()
    }
    
    override func open() async -> String? {
        self.initVal = ""
        return await super.open()
    }
}

extension String: @retroactive Error {}
extension String: @retroactive LocalizedError {
    public var errorDescription: String? { return self }
        
//    private static var enBundle : Bundle? = {
//        let language = "en"
//        let path = Bundle.main.path(forResource:language, ofType: "lproj")
//        let bundle = Bundle(path: path!)
//        return bundle
//    }()
    
    var loc: String {
//        let message = NSLocalizedString(self, comment: "")
//        if message != self {
//            return message
//        }
//
//        if let forcedString = String.enBundle?.localizedString(forKey: self, value: nil, table: nil){
//            return forcedString
//        }else {
            return self
//        }
    }
    
    func localizeWithFormat(_ arguments: CVarArg...) -> String{
        String.localizedStringWithFormat(self.loc, arguments)
    }
    
}

enum AnisetteClientInfo {
    static let defaultsKey = "AnisetteClientInfo"

    // Apple currently rejects Mac / Android / Xcode anisette identities on
    // GrandSlam with HTTP 503, which surfaces as error -80045 / -80046, so every
    // supported path now reports the same Windows PC profile. The value is
    // trimmed: the reference string ships with spaces around the first field.
    static let windowsClientInfo = "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>"
    static let windowsUserAgent = "akd/1.0 CFNetwork/808.1.4"

    // Identity shipped by earlier builds. Kept only so upgrades can recognise and
    // replace a stale Mac profile instead of silently reusing it.
    static let legacyRemoteDefault = "<iMac18,3> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.akd/1.0)>"

    static let onDeviceDefault = windowsClientInfo
    static let remoteDefault = windowsClientInfo

    static func resolved(fallback: String) -> String {
        let stored = UserDefaults.standard.string(forKey: defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? fallback : stored
    }

    /// The Windows profile is the identity the current GSA workaround requires.
    /// Anything else (Mac/Android/Xcode) would make the Anisette headers disagree
    /// with the identity reported to GrandSlam, so it is normalised away.
    static func isWindowsCompatible(_ clientInfo: String) -> Bool {
        let lower = clientInfo.lowercased()
        return lower.contains("windows") || lower.contains("<pc")
    }

    static func sanitized(_ clientInfo: String?, fallback: String) -> String {
        let value = clientInfo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty, isWindowsCompatible(value) else { return fallback }
        return value
    }
}

enum AnisetteDefaults {
    // A v3 server that actually serves Windows ADI data. Only a default: the
    // server stays user-configurable in Settings (see Anisette Server URL).
    static let serverURL = "https://ani.jkcoxson.com"
    static let legacyServerURL = "https://ani.sidestore.io"
}

enum AnisetteSettings {
    static let serverKey = "AnisetteServer"
    static let onDeviceKey = "UseOnDeviceAnisette"

    /// An unset preference now means "use the remote Windows v3 server". Older
    /// builds treated unset as on-device, which produced a Mac identity Apple
    /// rejects; the migrator keeps an explicit choice but changes the default.
    static var useOnDeviceAnisette: Bool {
        UserDefaults.standard.bool(forKey: onDeviceKey)
    }

    static var serverURL: URL? {
        let raw = UserDefaults.standard.string(forKey: serverKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return URL(string: raw.isEmpty ? AnisetteDefaults.serverURL : raw)
    }
}

/// Detects when the active Anisette provider changed. The adi.pb/identity is bound
/// to the provider that minted it, so switching servers or modes invalidates the
/// old state. It is deliberately never cleared for ordinary network errors.
enum AnisetteProviderState {
    private static let defaultsKey = "AnisetteProviderIdentityKey"

    static func updateProvider(_ newValue: String) {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: defaultsKey)
        guard previous != newValue else { return }
        defaults.set(newValue, forKey: defaultsKey)
        guard previous != nil else { return }

        Keychain.shared.adiPb = nil
        Keychain.shared.identifier = nil
        AnisetteDataHelper.shared.resetClientInfo()
        SideSign.AnisetteDataManager.shared.clearCache()
    }

    /// Forgets the recorded provider. Used after an identity is imported/set
    /// explicitly so the next login does not treat it as a provider change and
    /// wipe the freshly imported credentials.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

/// Repairs Anisette state Apple will not accept any more.
///
/// Provisioning data (adi.pb) plus the identifier that minted it are one identity.
/// Apple refuses a Mac-profile identity outright, and a blob the server can no
/// longer validate cannot be fixed in place, so the only repair is to forget the
/// pair and let the next sign in provision a fresh Windows identity.
enum AnisetteRecovery {
    /// Drops the identity, cached Anisette data and the recorded provider.
    static func purgeIdentity() {
        Keychain.shared.adiPb = nil
        Keychain.shared.identifier = nil
        AnisetteDataHelper.shared.resetClientInfo()
        SideSign.AnisetteDataManager.shared.clearCache()
        AnisetteProviderState.reset()
    }

    /// True only for failures that mean "this identity is no longer usable".
    /// Ordinary network errors, a wrong password or a cancelled 2FA must keep
    /// the identity, otherwise every retry would reprovision from scratch.
    static func shouldPurge(after error: Error) -> Bool {
        if let serverError = error as? ServerError {
            switch serverError {
            case .underlyingError(let code, _):
                return RefusalCodes.codes.contains(code)
            case .badServerResponse(let reason, _):
                // SideSign reports a refused GrandSlam connection as a bad server
                // response whose reason carries the HTTP status.
                return RefusalCodes.statuses.contains { reason.contains("HTTP \($0)") }
            case .invalidResponseFormat, .missingKey:
                return false
            }
        }

        if let portalError = error as? DeveloperPortalError,
           case .invalidAnisetteData(_) = portalError {
            return true
        }

        // AnisetteDataHelper reports server-side provisioning failures as plain
        // strings, so match those explicitly instead of guessing from prose.
        if let message = error as? String {
            return RefusalCodes.messages.contains { message.contains($0) }
        }

        return false
    }

    private enum RefusalCodes {
        static let codes = [-80045, -80046]
        static let statuses = [433, 503]
        static let messages = ["-80045", "-80046", "not provisioned"]
    }
}

enum AnisetteSettingsMigrator {
    private static let versionKey = "AnisetteSettingsMigrationVersion"
    private static let currentVersion = 1

    /// Existing installs persist `AnisetteServer`/`UseOnDeviceAnisette`/client info
    /// in UserDefaults, so changing the property defaults alone would never reach
    /// them. This upgrades the stored values once.
    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.integer(forKey: versionKey) < currentVersion else { return }

        let storedServer = defaults.string(forKey: AnisetteSettings.serverKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if storedServer == nil || storedServer!.isEmpty || storedServer == AnisetteDefaults.legacyServerURL {
            defaults.set(AnisetteDefaults.serverURL, forKey: AnisetteSettings.serverKey)
        }

        let storedClientInfo = defaults.string(forKey: AnisetteClientInfo.defaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if storedClientInfo == AnisetteClientInfo.legacyRemoteDefault {
            defaults.removeObject(forKey: AnisetteClientInfo.defaultsKey)
        }

        // The stored identity is deliberately kept: it may be an imported
        // SideStore account. A stale or Mac-profile blob is dropped by
        // AnisetteRecovery when Apple actually refuses it, which covers upgrades
        // without throwing away a working identity.

        // `UseOnDeviceAnisette` is intentionally left untouched: an unset value
        // already means "remote Windows v3 server" (the new default), while users
        // who explicitly toggled the switch keep their choice.

        defaults.set(currentVersion, forKey: versionKey)
    }
}

class SharedModel: ObservableObject {
    @Published var isLogin = false
    @AppStorage(AnisetteSettings.serverKey) var anisetteServerURL = AnisetteDefaults.serverURL
    @AppStorage(AnisetteSettings.onDeviceKey) var useOnDeviceAnisette = false
    @AppStorage(AnisetteClientInfo.defaultsKey) var anisetteClientInfo = ""
    var session: AppleAPISession?
    var account: Account?
    var team: Team?
    
    init() {
        AnisetteSettingsMigrator.migrateIfNeeded()
        AnisetteDataHelper.shared.url = URL(string: anisetteServerURL)
    }
}

class DataManager {
    static let shared = DataManager()
    let model = SharedModel()
}

extension Error {
    var detailedDescription: String {
        let localizedError = self as? LocalizedError
        var lines: [String] = []
        
        if let description = localizedError?.errorDescription, !description.isEmpty {
            lines.append(description)
        } else {
            let nsError = self as NSError
            lines.append(nsError.localizedDescription)
        }
        
        if let failureReason = localizedError?.failureReason, !failureReason.isEmpty {
            lines.append("Reason: \(failureReason)")
        }
        
        if let recoverySuggestion = localizedError?.recoverySuggestion, !recoverySuggestion.isEmpty {
            lines.append("Suggestion: \(recoverySuggestion)")
        }
        
        let nsError = self as NSError
        if nsError.domain != NSCocoaErrorDomain || nsError.code != 0 {
            lines.append("Domain: \(nsError.domain)")
            lines.append("Code: \(nsError.code)")
        }
        
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            lines.append("Underlying: \(underlying.detailedDescription)")
        }
        
        return lines.joined(separator: "\n")
    }
}
