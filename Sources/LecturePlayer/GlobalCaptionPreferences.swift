import Foundation
import Core

/// UserDefaults is injected so isolated libraries never alter production preferences.
@MainActor final class GlobalCaptionPreferences {
    static let key="videoCaptions.global.v1"
    private let defaults:UserDefaults
    private(set) var value=VideoCaptionPreferences()
    init(defaults:UserDefaults) {self.defaults=defaults}
    func initialize(legacy:VideoCaptionPreferences?) {
        if let data=defaults.data(forKey:Self.key) {
            value=Self.normalized((try? Codec.decode(VideoCaptionPreferences.self,data)) ?? VideoCaptionPreferences())
        } else {save(legacy ?? VideoCaptionPreferences())}
    }
    func save(_ value:VideoCaptionPreferences) {
        self.value=Self.normalized(value)
        if let data=try? Codec.encode(self.value) {defaults.set(data,forKey:Self.key)}
    }
    static func normalized(_ input:VideoCaptionPreferences)->VideoCaptionPreferences {
        var v=input
        if !["双语","英文","中文"].contains(v.mode) {v.mode="双语"}
        v.fontSize=v.fontSize.isFinite ? min(36,max(16,v.fontSize)):22
        if let p=v.position,!["top","center","bottom"].contains(p) {v.position=nil}
        if let m=v.margin {v.margin=m.isFinite ? min(0.15,max(0,m)):nil}
        if let t=v.transparency {v.transparency=t.isFinite ? min(1,max(0,t)):nil}
        return v
    }
}
