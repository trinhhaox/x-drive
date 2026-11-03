import Cocoa
import AuthenticationServices
import CryptoKit
import OrbitCore

// MARK: - BrowserSignIn (ASWebAuthenticationSession OAuth2 PKCE)

@MainActor
public final class BrowserSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var currentSession: ASWebAuthenticationSession?

    public override init() {
        super.init()
    }

    public static func generatePKCE() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = ZK.base64URLEncode(Data(bytes))
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = ZK.base64URLEncode(Data(digest))
        return (verifier, challenge)
    }

    public func startSignIn(
        baseAuthURL: URL = URL(string: "https://www.helumi.app/auth/desktop")!,
        callbackScheme: String = "orbit",
        onComplete: @escaping (Result<(code: String, verifier: String), Error>) -> Void
    ) {
        let pkce = Self.generatePKCE()
        var comps = URLComponents(url: baseAuthURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "redirect_uri", value: "\(callbackScheme)://auth")
        ]
        guard let authURL = comps.url else { return }

        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: callbackScheme
        ) { callbackURL, error in
            if let error {
                onComplete(.failure(error))
                return
            }
            guard let callbackURL,
                  let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems,
                  let code = items.first(where: { $0.name == "code" })?.value else {
                onComplete(.failure(OrbitAPIError.invalidResponse))
                return
            }
            onComplete(.success((code: code, verifier: pkce.verifier)))
        }
        session.presentationContextProvider = self
        session.prefersEphemeralWebBrowserSession = false
        self.currentSession = session
        session.start()
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}

// MARK: - EjectWatcher (Monitors /Volumes/Helumi Mount & Unmount Events)

@MainActor
public final class EjectWatcher {
    private var mountObserver: NSObjectProtocol?
    private var unmountObserver: NSObjectProtocol?

    public init(onVolumeChange: @escaping @MainActor () -> Void) {
        let center = NSWorkspace.shared.notificationCenter
        mountObserver = center.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in onVolumeChange() }
        }
        unmountObserver = center.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in onVolumeChange() }
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        if let mountObserver { center.removeObserver(mountObserver) }
        if let unmountObserver { center.removeObserver(unmountObserver) }
    }
}

