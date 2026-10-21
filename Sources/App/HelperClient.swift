import Foundation
import AppKit

// Côté app de la liaison XPC avec le helper root, plus son installation.
//
// Installation : SMJobBless est déprécié et exige un certificat
// Developer ID. Ici on reste sur le même modèle launchd (binaire dans
// /Library/PrivilegedHelperTools + plist dans /Library/LaunchDaemons) mais posé
// par un script lancé via « do shell script … with administrator privileges » :
// macOS affiche sa propre demande de mot de passe administrateur.

@MainActor
final class HelperClient: ObservableObject {
    enum State: Equatable {
        case notInstalled
        case connecting
        case connected(version: String)
        case outdated(version: String)
        case error(String)
    }

    @Published private(set) var state: State = .connecting
    @Published private(set) var status: HelperStatus?
    @Published var lastError: String?

    private var connection: NSXPCConnection?
    /// Mode développement : helper lancé comme LaunchAgent utilisateur (pas de root).
    private let devUserDomain = UserDefaults.standard.bool(forKey: "devUserHelper")

    var isInstalled: Bool {
        devUserDomain || FileManager.default.fileExists(atPath: HelperConstants.launchdPlist)
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    // MARK: Connexion

    private func proxy(_ onError: @escaping (Error) -> Void) -> PlafondHelperProtocol? {
        if connection == nil {
            // .privileged : recherche du service dans le domaine SYSTÈME uniquement,
            // pour qu'un agent utilisateur ne puisse pas se faire passer pour le helper.
            let c = NSXPCConnection(machServiceName: HelperConstants.machService,
                                    options: devUserDomain ? [] : .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: PlafondHelperProtocol.self)
            // Validation réciproque : le helper doit être signé par NOTRE certificat.
            c.setCodeSigningRequirement(BuildConfig.helperRequirement)
            c.invalidationHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            c.interruptionHandler = { [weak self] in
                Task { @MainActor in self?.connection = nil }
            }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler { error in
            Task { @MainActor in onError(error) }
        } as? PlafondHelperProtocol
    }

    func refresh() {
        guard isInstalled else { state = .notInstalled; status = nil; return }
        let p = proxy { [weak self] error in
            self?.state = .error(error.localizedDescription)
            self?.status = nil
        }
        p?.getVersion { [weak self] version in
            Task { @MainActor in
                guard let self else { return }
                self.state = version == HelperConstants.version ? .connected(version: version) : .outdated(version: version)
            }
        }
        p?.getStatus { [weak self] data in
            let s = try? JSONDecoder().decode(HelperStatus.self, from: data)
            Task { @MainActor in self?.status = s }
        }
    }

    func update(_ change: (inout HelperPolicy) -> Void) {
        // Sans statut reçu, on écraserait la politique du helper par les valeurs par défaut.
        guard var policy = status?.policy else {
            lastError = "Statut de l'assistant pas encore reçu, réessaie dans un instant."
            refresh()
            return
        }
        change(&policy)
        guard let data = try? JSONEncoder().encode(policy) else { return }
        let p = proxy { [weak self] error in self?.lastError = error.localizedDescription }
        p?.setPolicy(data) { [weak self] reply, error in
            let s = reply.flatMap { try? JSONDecoder().decode(HelperStatus.self, from: $0) }
            Task { @MainActor in
                if let error { self?.lastError = error }
                if let s { self?.status = s }
            }
        }
    }

    // MARK: Installation / désinstallation

    private var scriptPath: String? {
        Bundle.main.path(forResource: "helper-install", ofType: "sh")
    }

    func install() {
        guard let script = scriptPath else { lastError = "script d'installation absent du bundle"; return }
        let bundle = Bundle.main.bundlePath
        runAdmin("/bin/bash \(shellQuote(script)) install \(shellQuote(bundle))")
        connection?.invalidate(); connection = nil
        state = .connecting
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
    }

    func uninstall() {
        if isConnected {
            let p = proxy { [weak self] e in self?.lastError = e.localizedDescription }
            p?.uninstall { _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.connection = nil
                self?.refresh()
            }
        } else if let script = scriptPath {
            runAdmin("/bin/bash \(shellQuote(script)) uninstall")
            refresh()
        }
    }

    private func runAdmin(_ command: String) {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with prompt \"Plafond doit installer son assistant privilégié pour piloter le SMC.\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {   // -128 = annulé par l'utilisateur
            lastError = error[NSAppleScript.errorMessage] as? String ?? "échec de l'installation"
        }
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
