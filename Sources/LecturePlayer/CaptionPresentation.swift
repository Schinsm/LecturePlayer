import Foundation
import Combine
import Core

/// Lightweight live preview. Only final appearance edits reach the library database.
@MainActor final class CaptionPresentation: ObservableObject {
    @Published private(set) var value=VideoCaptionPreferences()
    private(set) var lessonID:UUID?
    private var pending=false
    private var editing=false
    private var timer:Task<Void,Never>?
    var save:((UUID,VideoCaptionPreferences)->Void)?
    func configure(_ id:UUID?,value:VideoCaptionPreferences) {
        flush();editing=false;lessonID=id;self.value=value
    }
    func update(_ change:(inout VideoCaptionPreferences)->Void) {
        guard lessonID != nil else{return}
        var next=value;change(&next);guard next != value else{return}
        value=next;pending=true;timer?.cancel()
        guard !editing else {return}
        timer=Task { [weak self] in
            do {try await Task.sleep(for:.milliseconds(350))} catch {return}
            self?.flush()
        }
    }
    func setEditing(_ active:Bool) {
        editing=active
        if active {timer?.cancel();timer=nil} else {flush()}
    }
    func flush() {
        timer?.cancel();timer=nil
        guard pending,let lessonID else{return}
        pending=false;save?(lessonID,value)
    }
    deinit {timer?.cancel()}
}
