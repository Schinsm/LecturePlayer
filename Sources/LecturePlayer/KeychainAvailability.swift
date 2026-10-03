import Foundation
import Combine
import Core

@MainActor final class KeychainAvailability:ObservableObject {
    static let shared=KeychainAvailability()
    @Published private(set) var values:[TranslationService:Bool]=[:]
    private let probe:@Sendable(TranslationService)->Bool
    init(probe:@escaping @Sendable(TranslationService)->Bool = {Keychain.configured($0)}){self.probe=probe}
    private var inFlight=Set<TranslationService>()
    private var generations:[TranslationService:Int]=[:]
    func configured(_ service:TranslationService)->Bool {
        if let value=values[service] {return value}
        refresh(service);return false
    }
    func refresh(_ service:TranslationService) {
        guard inFlight.insert(service).inserted else{return}
        let token=generations[service,default:0],probe=self.probe
        Task {let value=await Task.detached(priority:.utility){probe(service)}.value
            inFlight.remove(service)
            guard token==generations[service,default:0] else {refresh(service);return}
            if values[service] != value {values[service]=value}
        }
    }
    func invalidate(_ service:TranslationService) {generations[service,default:0] += 1;values.removeValue(forKey:service);refresh(service)}
    func refreshAll(){for service in TranslationService.allCases {refresh(service)}}
}
