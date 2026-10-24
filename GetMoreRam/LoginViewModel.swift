//
//  LoginViewModel.swift
//  GetMoreRam
//
//  Created by s s on 2025/3/15.
//
import SwiftUI
import StosSign_API
import StosSign_Auth
import StosSign_Common
import class SideSign.DeveloperPortal
import enum SideSign.TwoFactorRequest
import enum SideSign.TwoFactorResponse
import struct SideSign.AnisetteData

@MainActor
class LoginViewModel: ObservableObject {
    @Published var appleID = ""
    @Published var password = ""
    @Published var needVerificationCode = false
    @Published var verificationCode = ""
    @Published var loginModalShow = false
    @Published var teamSelectionShow = false
    @Published var isLoginInProgress = false
    @Published private(set) var isVerificationCodeSubmitting = false
    @Published var logs = ""
    @Published var availableTeams: [Team] = []
    
    private var verificationCodeHandler: ((String?) -> Void)?
    private var isAuthenticationCancellationRequested = false
    
    func submitVerificationCode() {
        guard !isVerificationCodeSubmitting,
              let verificationCodeHandler else { return }

        self.verificationCodeHandler = nil
        isVerificationCodeSubmitting = true
        verificationCodeHandler(verificationCode)
    }

    func cancelAuthentication() {
        guard isLoginInProgress else { return }

        isAuthenticationCancellationRequested = true

        let verificationCodeHandler = verificationCodeHandler
        self.verificationCodeHandler = nil
        needVerificationCode = false
        verificationCode = ""
        isVerificationCodeSubmitting = false

        verificationCodeHandler?(nil)
    }
    
    func authenticate() async throws -> Bool {
        if isLoginInProgress {
            return false
        }
        
        logs = ""
        isLoginInProgress = true
        isAuthenticationCancellationRequested = false
        
        func logging(text: String) {
            Task { @MainActor [weak self] in
                self?.logs.append("\(text)\n")
            }
        }
        
        AnisetteDataHelper.shared.loggingFunc = logging

        defer {
            verificationCodeHandler = nil
            appleID = ""
            password = ""
            needVerificationCode = false
            verificationCode = ""
            isLoginInProgress = false
            isVerificationCodeSubmitting = false
            isAuthenticationCancellationRequested = false
        }

        return try await signIn(logging: logging)
    }

    /// Runs one sign-in. If Apple refuses the identity itself (-80045/-80046 or a
    /// stale provisioning blob), the identity is discarded and the whole flow is
    /// retried once with a freshly provisioned one. Any other error (wrong
    /// password, cancelled 2FA, network) propagates untouched so credentials and
    /// Anisette state survive.
    private func signIn(logging: (String) -> Void) async throws -> Bool {
        do {
            return try await performSignIn(logging: logging)
        } catch {
            // A user cancel surfaces from SideSign as its own error; report it as
            // a cancellation so the UI does not show an alert for it.
            if isAuthenticationCancellationRequested { throw CancellationError() }
            guard AnisetteRecovery.shouldPurge(after: error) else { throw error }

            logging("Apple refused the Anisette identity; provisioning a new one and retrying")
            AnisetteRecovery.purgeIdentity()
            logging("Provider: \(currentProviderDescription)")
            verificationCode = ""
            needVerificationCode = false
            verificationCodeHandler = nil
            // A rejected code leaves the submit flag set, which would keep the
            // retry's code field disabled.
            isVerificationCodeSubmitting = false
            return try await performSignIn(logging: logging)
        }
    }

    private func performSignIn(logging: (String) -> Void) async throws -> Bool {
        // Both supported configurations go through the same SideSign
        // authentication path (Windows GrandSlam identity, updated 2FA flows,
        // no connection reuse). Only the Anisette data source differs.
        let anisette: SideSign.AnisetteData
        if AnisetteSettings.useOnDeviceAnisette {
            anisette = try await OnDeviceAnisetteHelper.shared.getSideSignAnisetteData()
        } else {
            anisette = try await OnDeviceAnisetteHelper.shared.getRemoteSideSignAnisetteData()
        }

        let portal = DeveloperPortal()
        let result = try await portal.authenticate(
            appleID: appleID, password: password, anisetteData: anisette,
            xcodeVersion: "27.0 (27A5218g)",
            accountRepairHandler: { _, _ in .cancel },
            verificationHandler: { [weak self] request in
                guard let self else { return .cancel }
                return await self.handleSideSignVerification(request)
            })

        guard !isAuthenticationCancellationRequested else {
            throw CancellationError()
        }

        // Keep StosSign's types for the existing App ID/signing UI only.
        guard let personID = Int(result.account.identifier) else {
            throw "SideSign returned an unsupported account identifier."
        }
        let accountData = try JSONSerialization.data(withJSONObject: [
            "email": result.account.appleID,
            "personId": personID,
            "dsFirstName": result.account.firstName,
            "dsLastName": result.account.lastName
        ])
        let account = try JSONDecoder().decode(Account.self, from: accountData)
        let session = AppleAPISession(dsid: result.session.dsid, authToken: result.session.authToken,
            anisetteData: try OnDeviceAnisetteHelper.shared.convert(result.session.anisetteData))
        let teams = try await portal.fetchTeams(for: result.account, session: result.session).map { team in
            let type: TeamType
            switch team.type {
            case .free: type = .free
            case .individual: type = .individual
            case .organization: type = .organization
            case .unknown: type = .unknown
            }
            return Team(name: team.name, identifier: team.identifier, type: type, account: account)
        }

        logging("Successfully signed in")

        DataManager.shared.model.account = account
        DataManager.shared.model.session = session
        Keychain.shared.appleIDEmailAddress = appleID
        Keychain.shared.appleIDPassword = password

        guard !teams.isEmpty else { throw "Unable to Fetch Team!" }
        logging("Successfully fetched teams")
        availableTeams = teams

        return true
    }

    private var currentProviderDescription: String {
        if AnisetteSettings.useOnDeviceAnisette { return "on-device" }
        return AnisetteSettings.serverURL?.absoluteString ?? "unset"
    }

    private func prepareForVerification(using handler: @escaping (String?) -> Void) {
        guard !isAuthenticationCancellationRequested else {
            handler(nil)
            return
        }

        verificationCodeHandler = handler
        verificationCode = ""
        needVerificationCode = true
        isVerificationCodeSubmitting = false
    }

    private func handleSideSignVerification(_ request: TwoFactorRequest) async -> TwoFactorResponse {
        guard !isAuthenticationCancellationRequested else { return .cancel }
        switch request {
        case .selectDeliveryMethod(let preferred, let phones):
            if preferred == .sms, let phone = phones.first {
                return .requestSMS(phoneID: phone.id)
            }
            return .requestTrustedDevice
        case .trustedDevice, .sms, .voice:
            if let error = request.error { logs.append("\(error)\n") }
            let code: String? = await withCheckedContinuation { continuation in
                prepareForVerification { continuation.resume(returning: $0) }
            }
            guard let code, !isAuthenticationCancellationRequested else { return .cancel }
            return .verificationCode(code.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
