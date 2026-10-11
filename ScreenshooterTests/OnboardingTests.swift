import XCTest
@testable import Screenshooter

final class OnboardingTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "onboarding-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Pasos

    func testStepsOrderAndBounds() {
        XCTAssertEqual(OnboardingStep.allCases.count, 5)
        XCTAssertTrue(OnboardingStep.welcome.isFirst)
        XCTAssertTrue(OnboardingStep.strip.isLast)
        XCTAssertNil(OnboardingStep.welcome.previous)
        XCTAssertNil(OnboardingStep.strip.next)
        XCTAssertEqual(OnboardingStep.permission.next, .capture)
        XCTAssertEqual(OnboardingStep.touch.previous, .capture)
    }

    // MARK: - Cuándo se muestra

    func testShownOnFirstLaunch() {
        XCTAssertTrue(OnboardingFlow.shouldShowAtLaunch(seenVersion: 0, resumeStep: nil, isCaptureActive: false))
    }

    func testNotShownOnceSeen() {
        XCTAssertFalse(OnboardingFlow.shouldShowAtLaunch(seenVersion: OnboardingFlow.currentVersion, resumeStep: nil, isCaptureActive: false))
    }

    func testShownAgainToResumeAfterPermissionRestart() {
        XCTAssertTrue(OnboardingFlow.shouldShowAtLaunch(seenVersion: OnboardingFlow.currentVersion, resumeStep: .capture, isCaptureActive: false))
    }

    func testNeverShownDuringACapture() {
        XCTAssertFalse(OnboardingFlow.shouldShowAtLaunch(seenVersion: 0, resumeStep: .capture, isCaptureActive: true))
    }

    // MARK: - Paso inicial

    func testInitialStep() {
        XCTAssertEqual(OnboardingFlow.initialStep(resumeStep: nil, reopenedFromMenu: false, permissionGranted: false), .welcome)
        XCTAssertEqual(OnboardingFlow.initialStep(resumeStep: nil, reopenedFromMenu: false, permissionGranted: true), .welcome)
        XCTAssertEqual(OnboardingFlow.initialStep(resumeStep: nil, reopenedFromMenu: true, permissionGranted: true), .capture)
        XCTAssertEqual(OnboardingFlow.initialStep(resumeStep: nil, reopenedFromMenu: true, permissionGranted: false), .welcome)
        XCTAssertEqual(OnboardingFlow.initialStep(resumeStep: .touch, reopenedFromMenu: true, permissionGranted: true), .touch)
    }

    // MARK: - Persistencia

    func testStoreStartsEmpty() {
        let store = OnboardingStore(defaults: defaults)
        XCTAssertEqual(store.seenVersion, 0)
        XCTAssertNil(store.resumeStep)
    }

    func testResumeStepRoundTrip() {
        let store = OnboardingStore(defaults: defaults)
        store.saveResumeStep(OnboardingFlow.stepAfterPermissionRestart)
        XCTAssertEqual(store.resumeStep, .capture)
        store.clearResumeStep()
        XCTAssertNil(store.resumeStep)
    }

    func testResumeStepWelcomeIsNotConfusedWithMissing() {
        // rawValue 0 no debe leerse como «sin paso»
        let store = OnboardingStore(defaults: defaults)
        store.saveResumeStep(.welcome)
        XCTAssertEqual(store.resumeStep, .welcome)
    }

    func testMarkSeenStoresVersionAndClearsResume() {
        let store = OnboardingStore(defaults: defaults)
        store.saveResumeStep(.capture)
        store.markSeen()
        XCTAssertEqual(store.seenVersion, OnboardingFlow.currentVersion)
        XCTAssertNil(store.resumeStep)
        XCTAssertFalse(OnboardingFlow.shouldShowAtLaunch(seenVersion: store.seenVersion, resumeStep: store.resumeStep, isCaptureActive: false))
    }
}
