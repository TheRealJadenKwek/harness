import Foundation
import AuthenticationServices

// Native Sign in with Apple → Supabase id_token grant. App Store guideline 4.8
// requires this alongside Google. Supabase-side config: Auth → Providers →
// Apple → add the bundle id to "Authorized Client IDs" (no secret needed for
// the native flow).
final class AppleSignIn: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    static let shared = AppleSignIn()
    private var completion: ((Bool) -> Void)?

    func start(completion: @escaping (Bool) -> Void) {
        self.completion = completion
        let req = ASAuthorizationAppleIDProvider().createRequest()
        req.requestedScopes = [.email]
        let ctrl = ASAuthorizationController(authorizationRequests: [req])
        ctrl.delegate = self
        ctrl.presentationContextProvider = self
        ctrl.performRequests()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let cred = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else { finish(false); return }
        Task {
            var req = URLRequest(url: URL(string: Backend.supa + "/auth/v1/token?grant_type=id_token")!)
            req.httpMethod = "POST"
            req.setValue(Backend.anon, forHTTPHeaderField: "apikey")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["provider": "apple", "id_token": idToken])
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let at = j["access_token"] as? String, let rt = j["refresh_token"] as? String else { self.finish(false); return }
            Backend.session = Backend.Session(accessToken: at, refreshToken: rt,
                                              expiresAt: Date().addingTimeInterval(((j["expires_in"] as? Double) ?? 3600) - 60))
            self.finish(true)
        }
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) { finish(false) }
    private func finish(_ ok: Bool) { DispatchQueue.main.async { self.completion?(ok); self.completion = nil } }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
    }
}
