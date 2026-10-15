import Foundation
import Core

/// Value input to the native canvas. Media changes invalidate presentation even
/// when the AVPlayer instances and the user's layout are unchanged.
struct VideoPresentationSnapshot: Equatable {
    let generation: UUID
    let lessonID: UUID?
    let sources: [MediaSource]
    let sizes: [UUID: CGSize]
    let items: [UUID: ObjectIdentifier]
    let missing: Set<UUID>
    let ended: Set<UUID>
    let beforeStart: Set<UUID>
    let ready: Bool
}
