//
//  GameViewController.swift
//  NFSCarbon
//
//  Root view controller managing boot lifecycle, hardware diagnostic verification,
//  onboarding asset transfer instructions, CADisplayLink ProMotion pacing,
//  Metal presentation, and TouchOverlay input bridging.
//

import UIKit
import MetalKit
import QuartzCore
import UniformTypeIdentifiers

public final class GameViewController: UIViewController, TouchOverlayDelegate {

    // MARK: - Subsystems
    private var metalView: MTKView?
    private var renderer: MetalRenderer?
    private var touchOverlay: TouchOverlayView?
    private var displayLink: CADisplayLink?
    private var bridge: NFSCBridge?

    // MARK: - Onboarding UI Elements
    private var onboardingContainer: UIView?
    private var statusCard: UIView?
    private var missingFilesLabel: UILabel?

    // MARK: - View Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        self.view.backgroundColor = UIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0)

        // 1. Initialize Logger & Install Signal Crash Reporters
        NFSCLogger.shared.logStartupTelemetry()
        NFSCInstallCrashReporter()
        NFSCRedirectStandardOutput()

        // 2. Setup Lifecycle Observers
        setupLifecycleObservers()

        // 3. Scan Documents/NFSC/ Sandbox Directory
        performAssetIntegrityCheck()
    }

    public override var prefersStatusBarHidden: Bool {
        return true
    }

    public override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }

    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .landscape
    }

    public override var shouldAutorotate: Bool {
        return true
    }

    // MARK: - Asset Integrity & Routing

    private func performAssetIntegrityCheck() {
        let report = NFSCLogger.shared.verifyGameAssets()

        if report.isComplete {
            // Assets ready -> Dismiss any onboarding and boot game engine
            onboardingContainer?.removeFromSuperview()
            onboardingContainer = nil
            bootGameEngine(assetPath: report.assetPath)
        } else {
            // Assets missing -> Present guided transfer screen
            renderOnboardingUI(report: report)
        }
    }

    // MARK: - Onboarding Screen (PC Asset Transfer Guide)

    private func renderOnboardingUI(report: NFSCLogger.AssetVerificationReport) {
        if let existing = onboardingContainer {
            existing.removeFromSuperview()
        }

        let container = UIView(frame: view.bounds)
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1.0)
        self.onboardingContainer = container
        view.addSubview(container)

        // Scrollable content for smaller screens/iPhones
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        container.addSubview(scrollView)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.safeAreaLayoutGuide.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.safeAreaLayoutGuide.trailingAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40)
        ])

        // Header: NFS Carbon Logo Title
        let titleLabel = UILabel()
        titleLabel.text = "NEED FOR SPEED: CARBON"
        titleLabel.textColor = UIColor(red: 0.95, green: 0.2, blue: 0.2, alpha: 1.0)
        titleLabel.font = UIFont.systemFont(ofSize: 26, weight: .black)
        stack.addArrangedSubview(titleLabel)

        let editionLabel = UILabel()
        editionLabel.text = "COLLECTOR'S EDITION • iOS NATIVE RECOMPILATION"
        editionLabel.textColor = UIColor(red: 0.9, green: 0.75, blue: 0.25, alpha: 1.0)
        editionLabel.font = UIFont.systemFont(ofSize: 13, weight: .bold)
        stack.addArrangedSubview(editionLabel)

        // Status Card
        let card = UIView()
        card.backgroundColor = UIColor(white: 0.12, alpha: 0.9)
        card.layer.cornerRadius = 12
        card.layer.borderWidth = 1.5
        card.layer.borderColor = UIColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 0.6).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(card)

        let cardStack = UIStackView()
        cardStack.axis = .vertical
        cardStack.spacing = 8
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(cardStack)

        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.92),
            cardStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16)
        ])

        let warningBadge = UILabel()
        warningBadge.text = "⚠️ GAME ASSETS REQUIRED"
        warningBadge.textColor = UIColor(red: 1.0, green: 0.35, blue: 0.35, alpha: 1.0)
        warningBadge.font = UIFont.systemFont(ofSize: 16, weight: .heavy)
        cardStack.addArrangedSubview(warningBadge)

        let missingText = "Missing critical game archives:\n• " + report.missingEssentials.joined(separator: "\n• ")
        let missingLabel = UILabel()
        missingLabel.text = missingText
        missingLabel.textColor = UIColor(white: 0.85, alpha: 1.0)
        missingLabel.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .medium)
        missingLabel.numberOfLines = 0
        cardStack.addArrangedSubview(missingLabel)

        // Instructions
        let instructionsCard = UIView()
        instructionsCard.backgroundColor = UIColor(white: 0.1, alpha: 0.7)
        instructionsCard.layer.cornerRadius = 10
        instructionsCard.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(instructionsCard)

        let instrStack = UIStackView()
        instrStack.axis = .vertical
        instrStack.spacing = 6
        instrStack.translatesAutoresizingMaskIntoConstraints = false
        instructionsCard.addSubview(instrStack)

        NSLayoutConstraint.activate([
            instructionsCard.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.92),
            instrStack.topAnchor.constraint(equalTo: instructionsCard.topAnchor, constant: 14),
            instrStack.bottomAnchor.constraint(equalTo: instructionsCard.bottomAnchor, constant: -14),
            instrStack.leadingAnchor.constraint(equalTo: instructionsCard.leadingAnchor, constant: 14),
            instrStack.trailingAnchor.constraint(equalTo: instructionsCard.trailingAnchor, constant: -14)
        ])

        let instrHeader = UILabel()
        instrHeader.text = "HOW TO TRANSFER ASSETS FROM YOUR PC:"
        instrHeader.textColor = .white
        instrHeader.font = UIFont.systemFont(ofSize: 14, weight: .bold)
        instrStack.addArrangedSubview(instrHeader)

        let steps = [
            "1. Connect iPhone/iPad to Mac/PC or open the iOS 'Files' app.",
            "2. Navigate to: 'On My iPhone' -> 'NFS Carbon' -> 'NFSC'.",
            "3. Copy your PC v1.4 Collector's Edition game files (NFSC.exe, GLOBAL, TRACKS, CARS, etc.) into that folder.",
            "4. Tap 'Re-scan Assets' below when copying completes."
        ]
        for step in steps {
            let stepLabel = UILabel()
            stepLabel.text = step
            stepLabel.textColor = UIColor(white: 0.8, alpha: 1.0)
            stepLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
            stepLabel.numberOfLines = 0
            instrStack.addArrangedSubview(stepLabel)
        }

        // Action Buttons Row
        let buttonsRow = UIStackView()
        buttonsRow.axis = .horizontal
        buttonsRow.spacing = 14
        buttonsRow.distribution = .fillEqually
        buttonsRow.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(buttonsRow)

        NSLayoutConstraint.activate([
            buttonsRow.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: 0.92),
            buttonsRow.heightAnchor.constraint(equalToConstant: 44)
        ])

        let rescanButton = createActionButton(title: "🔄 Re-Scan Assets", color: UIColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 1.0))
        rescanButton.addTarget(self, action: #selector(onRescanTapped), for: .touchUpInside)
        buttonsRow.addArrangedSubview(rescanButton)

        let openFilesButton = createActionButton(title: "📁 Open Files Folder", color: UIColor(white: 0.25, alpha: 1.0))
        openFilesButton.addTarget(self, action: #selector(onOpenFilesTapped), for: .touchUpInside)
        buttonsRow.addArrangedSubview(openFilesButton)

        let logButton = createActionButton(title: "📋 View Logs", color: UIColor(white: 0.2, alpha: 1.0))
        logButton.addTarget(self, action: #selector(onViewLogsTapped), for: .touchUpInside)
        buttonsRow.addArrangedSubview(logButton)
    }

    private func createActionButton(title: String, color: UIColor) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .bold)
        button.backgroundColor = color
        button.layer.cornerRadius = 8
        return button
    }

    @objc private func onRescanTapped() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        NFSCLogger.shared.info("FS", "User initiated manual asset re-scan.")
        performAssetIntegrityCheck()
    }

    @objc private func onOpenFilesTapped() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Present Document Picker pointing to sandbox folder
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let nfscDir = docs.appendingPathComponent("NFSC", isDirectory: true)
        
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        picker.directoryURL = nfscDir
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }

    @objc private func onViewLogsTapped() {
        let logText = NFSCLogger.shared.getLogFileContent() ?? "No log entries found."
        let alert = UIAlertController(title: "Diagnostic Runtime Log", message: String(logText.suffix(2000)), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Copy All", style: .default, handler: { _ in
            UIPasteboard.general.string = logText
        }))
        alert.addAction(UIAlertAction(title: "Close", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Boot Game Engine & Attach Pipeline

    private func bootGameEngine(assetPath: String) {
        NFSCLogger.shared.info("ENGINE", "All asset prerequisites validated. Booting static recompilation core...")

        // 1. Setup MTKView
        let mtkView = MTKView(frame: view.bounds)
        mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(mtkView)
        self.metalView = mtkView

        guard let renderer = MetalRenderer(metalView: mtkView) else {
            NFSCLogger.shared.fatal("METAL", "Fatal error initializing MetalRenderer.")
            return
        }
        self.renderer = renderer

        // 2. Setup Touch Racing HUD Overlay
        let overlay = TouchOverlayView(frame: view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.delegate = self
        view.addSubview(overlay)
        self.touchOverlay = overlay

        // 3. Initialize NFSCBridge Core
        let bridge = NFSCBridge.shared()
        self.bridge = bridge

        var error: NSError?
        let success = bridge.initializeEngine(withAssetPath: assetPath, error: &error)
        if !success {
            NFSCLogger.shared.fatal("ENGINE", "Engine initialization failed: \(error?.localizedDescription ?? "Unknown error")")
            return
        }

        // 4. Configure CADisplayLink with Apple ProMotion (60Hz / 120Hz)
        setupProMotionDisplayLink()

        // 5. Start Engine Main Loop
        bridge.startEngineLoop()
        NFSCLogger.shared.info("ENGINE", "Static recomp engine loop started.")
    }

    private func setupProMotionDisplayLink() {
        let dLink = CADisplayLink(target: self, selector: #selector(onDisplayLinkTick(_:)))
        if #available(iOS 15.0, *) {
            dLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60, optimistic: 120, maximum: 120)
        } else {
            dLink.preferredFramesPerSecond = 120
        }
        dLink.add(to: .main, forMode: .common)
        self.displayLink = dLink
        NFSCLogger.shared.info("DISPLAY", "CADisplayLink configured for 60-120Hz dynamic frame pacing.")
    }

    @objc private func onDisplayLinkTick(_ link: CADisplayLink) {
        // Paced display tick
        bridge?.tickFramePacing()
    }

    // MARK: - TouchOverlayDelegate Input Forwarding

    public func touchOverlayDidUpdateSteering(_ steering: Float) {
        bridge?.setSteering(steering)
    }

    public func touchOverlayDidUpdateThrottle(_ throttle: Float) {
        bridge?.setThrottle(throttle)
    }

    public func touchOverlayDidUpdateBrake(_ brake: Float) {
        bridge?.setBrake(brake)
    }

    public func touchOverlayDidUpdateHandbrake(_ active: Bool) {
        bridge?.setHandbrake(active)
    }

    public func touchOverlayDidUpdateNitrous(_ active: Bool) {
        bridge?.setNitrous(active)
    }

    public func touchOverlayDidUpdateSpeedbreaker(_ active: Bool) {
        bridge?.setSpeedbreaker(active)
    }

    public func touchOverlayDidTriggerShiftUp() {
        bridge?.triggerShiftUp()
    }

    public func touchOverlayDidTriggerShiftDown() {
        bridge?.triggerShiftDown()
    }

    public func touchOverlayDidTriggerCamera() {
        bridge?.triggerCameraToggle()
    }

    public func touchOverlayDidTriggerPause() {
        bridge?.triggerPause()
    }

    public func touchOverlayDidTriggerResetCar() {
        bridge?.triggerResetCar()
    }

    // MARK: - App Lifecycle Observers

    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillTerminate), name: UIApplication.willTerminateNotification, object: nil)
    }

    @objc private func appDidBecomeActive() {
        NFSCLogger.shared.info("LIFECYCLE", "App transitioned to Active state.")
        displayLink?.isPaused = false
        bridge?.pauseEngine(false)
    }

    @objc private func appWillResignActive() {
        NFSCLogger.shared.info("LIFECYCLE", "App will resign active state.")
        displayLink?.isPaused = true
        bridge?.pauseEngine(true)
        NFSCLogger.shared.flush()
    }

    @objc private func appDidEnterBackground() {
        NFSCLogger.shared.info("LIFECYCLE", "App entered background.")
        NFSCLogger.shared.flush()
    }

    @objc private func appWillTerminate() {
        NFSCLogger.shared.info("LIFECYCLE", "App will terminate. Flushing remaining runtime logs.")
        bridge?.stopEngineLoop()
        NFSCLogger.shared.flush()
    }

    public override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        NFSCLogger.shared.warn("SYS", "High Memory Pressure Warning received from iOS kernel.")
    }
}
