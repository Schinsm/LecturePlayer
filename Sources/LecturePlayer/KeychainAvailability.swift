import Foundation
import Combine
import Security
import Core

enum CredentialAvailability: Equatable, Sendable {
    case checking, available, missing, authorizationRequired, unavailable(Int32)
    var isAvailable: Bool { self == .available }
    var message: String {
        switch self {
        case .checking: return "正在检查凭据…"
        case .available: return "已配置"
        case .missing: return "未保存 API Key"
        case .authorizationRequired: return "需要授权读取钥匙串"
        case .unavailable(let code): return "凭据暂不可用（\(code)）"
        }
    }
    static func keychainStatus(_ status: OSStatus) -> Self {
        switch status {
        case errSecSuccess: return .available
        case errSecItemNotFound: return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled: return .authorizationRequired
        default: return .unavailable(status)
        }
    }
}

@MainActor final class KeychainAvailability: ObservableObject {
    static let shared = KeychainAvailability(stateProbe: { Keychain.availability($0) })
    @Published private(set) var states: [TranslationService: CredentialAvailability] = [:]
    var values: [TranslationService: Bool] { states.compactMapValues { $0 == .checking ? nil : $0.isAvailable } }
    private let probe: @Sendable (TranslationService) -> CredentialAvailability
    private var inFlight: [TranslationService: Task<CredentialAvailability, Never>] = [:]
    private var generations: [TranslationService: Int] = [:]
    init(stateProbe: @escaping @Sendable (TranslationService) -> CredentialAvailability) { probe = stateProbe }
    convenience init(probe: @escaping @Sendable (TranslationService) -> Bool) {
        self.init(stateProbe: { probe($0) ? .available : .missing })
    }
    func state(_ service: TranslationService) -> CredentialAvailability { states[service] ?? .checking }
    func configured(_ service: TranslationService) -> Bool {
        if states[service] == nil { refresh(service) }
        return state(service).isAvailable
    }
    func refresh(_ service: TranslationService) {
        guard inFlight[service] == nil else { return }
        let token = generations[service, default: 0], probe = self.probe
        let work = Task.detached(priority: .utility) { probe(service) }
        inFlight[service] = work
        Task {
            let value = await work.value
            inFlight[service] = nil
            guard token == generations[service, default: 0] else { refresh(service); return }
            if states[service] != value { states[service] = value }
        }
    }
    /// Await a fresh local check before committing import options. No service request.
    func validate(_ service: TranslationService) async -> CredentialAvailability {
        invalidate(service)
        while let work = inFlight[service] {
            _ = await work.value
            await Task.yield()
            if Task.isCancelled { return .checking }
        }
        return state(service)
    }
    func invalidate(_ service: TranslationService) {
        generations[service, default: 0] += 1
        states[service] = .checking
        refresh(service)
    }
    func refreshAll() { for service in TranslationService.allCases { refresh(service) } }
    func authorize(_ service: TranslationService) {
        generations[service, default: 0] += 1
        let token = generations[service, default: 0]
        states[service] = .checking
        Task {
            // User initiated local Keychain prompt; the key is never retained here.
            let result = await Task.detached(priority: .userInitiated) {
                Keychain.availability(service, allowInteraction: true)
            }.value
            guard token == generations[service, default: 0] else { return }
            states[service] = result
        }
    }
}
