import Foundation
import Testing
@testable import Core
@testable import LecturePlayer

@Suite("0.8.8 onboarding", .serialized) @MainActor
struct V088OnboardingTests {
    private func preferences() throws -> (UserDefaults, String) {
        let name = "LP088-onboarding-" + UUID().uuidString
        return (try #require(UserDefaults(suiteName: name)), name)
    }
    @Test func freshInstallOffersOnceAndClosingRetainsStep() throws {
        let (defaults, name) = try preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let tutorial = OnboardingPresentation(defaults: defaults)
        tutorial.presentIfNeeded(library: Library())
        #expect(tutorial.showing)
        tutorial.advance(completed: true)
        #expect(tutorial.progress.step == .service)
        tutorial.close()
        let restart = OnboardingPresentation(defaults: defaults)
        restart.presentIfNeeded(library: Library())
        #expect(!restart.showing)
        restart.open()
        #expect(restart.showing && restart.progress.step == .service)
        #expect(restart.progress.completed == [.directory])
    }
    @Test func existingLibraryUpgradeDoesNotOfferOrModifyLibrary() throws {
        let (defaults, name) = try preferences(); defer { defaults.removePersistentDomain(forName: name) }
        var library = Library(); library.directoryRoot = "/example/Lectures"
        library.courses = [Course(name: "Existing course")]
        let before = try Codec.encode(library)
        let tutorial = OnboardingPresentation(defaults: defaults)
        tutorial.presentIfNeeded(library: library)
        #expect(!tutorial.showing)
        #expect(try Codec.encode(library) == before)
        tutorial.open(); #expect(tutorial.showing)
        #expect(tutorial.progress.step == .directory)
    }
    @Test func previouslyConfiguredEmptyLibraryIsNotTreatedAsNewInstall() throws {
        let (defaults, name) = try preferences(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("azure", forKey: "translationService")
        defaults.set("australiaeast", forKey: "azureRegion")
        let tutorial = OnboardingPresentation(defaults: defaults)
        tutorial.presentIfNeeded(library: Library())
        #expect(!tutorial.showing)
        tutorial.open(); tutorial.advance(completed: false); tutorial.advance(completed: false)
        #expect(defaults.string(forKey: "translationService") == "azure")
        #expect(defaults.string(forKey: "azureRegion") == "australiaeast")
    }
    @Test func skipBackAndCompletionPersistOnlyProgress() throws {
        let (defaults, name) = try preferences(); defer { defaults.removePersistentDomain(forName: name) }
        let tutorial = OnboardingPresentation(defaults: defaults)
        tutorial.open()
        tutorial.advance(completed: false)
        tutorial.advance(completed: false)
        tutorial.back()
        #expect(tutorial.progress.step == .service)
        tutorial.advance(completed: true)
        #expect(tutorial.progress.completed.contains(.service))
        #expect(!tutorial.progress.skipped.contains(.service))
        tutorial.advance(completed: false)
        tutorial.finish()
        let saved = OnboardingPresentation(defaults: defaults)
        #expect(saved.progress.finished && !saved.showing)
        #expect(saved.progress.completed == [.service, .watching])
        #expect(saved.progress.skipped == [.directory, .importing])
        let domain = try #require(defaults.persistentDomain(forName: name))
        #expect(Set(domain.keys) == [OnboardingPresentation.key])
        let data = try #require(defaults.data(forKey: OnboardingPresentation.key))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["step", "automaticOfferHandled", "completed", "skipped", "finished"])
    }
    @Test func corruptProgressKeepsExistingSetupAndDoesNotStartWork() throws {
        let (defaults, name) = try preferences(); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("invalid".utf8), forKey: OnboardingPresentation.key)
        var library = Library(); library.courses = [Course(name: "IM")]
        let tutorial = OnboardingPresentation(defaults: defaults)
        tutorial.presentIfNeeded(library: library)
        #expect(!tutorial.showing)
        #expect(tutorial.progress.step == .directory)
        #expect(tutorial.progress.completed.isEmpty)
    }
}
