//
//  TouchOverlayView.swift
//  NFSCarbon
//
//  High-performance, multi-touch racing HUD for iPhone and iPad with dynamic
//  analog thumbstick, steering slider, haptic feedback, and automatic
//  hiding upon GCController (MFi / Bluetooth gamepad) connection.
//

import UIKit
import GameController

public enum SteeringControlMode: Int {
    case analogStick = 0
    case steeringSlider = 1
}

public protocol TouchOverlayDelegate: AnyObject {
    func touchOverlayDidUpdateSteering(_ steering: Float) // -1.0 to 1.0
    func touchOverlayDidUpdateThrottle(_ throttle: Float) // 0.0 to 1.0
    func touchOverlayDidUpdateBrake(_ brake: Float)       // 0.0 to 1.0
    func touchOverlayDidUpdateHandbrake(_ active: Bool)
    func touchOverlayDidUpdateNitrous(_ active: Bool)
    func touchOverlayDidUpdateSpeedbreaker(_ active: Bool)
    func touchOverlayDidTriggerShiftUp()
    func touchOverlayDidTriggerShiftDown()
    func touchOverlayDidTriggerCamera()
    func touchOverlayDidTriggerPause()
    func touchOverlayDidTriggerResetCar()
}

public final class TouchOverlayView: UIView {

    public weak var delegate: TouchOverlayDelegate?
    public var controlMode: SteeringControlMode = .analogStick {
        didSet {
            updateSteeringControlVisibility()
        }
    }

    // MARK: - Haptic Engines
    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let mediumHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let heavyHaptic = UIImpactFeedbackGenerator(style: .heavy)
    private let selectionHaptic = UISelectionFeedbackGenerator()

    // MARK: - Left Controls (Steering)
    private let leftContainer = UIView()
    private let stickBaseView = UIView()
    private let stickKnobView = UIView()
    private var stickCenter: CGPoint = .zero
    private let stickRadius: CGFloat = 65.0
    private var stickTouch: UITouch?

    private let steeringSliderTrack = UIView()
    private let steeringSliderThumb = UIView()
    private var sliderTouch: UITouch?

    // MARK: - Right Controls (Action Cluster)
    private let rightContainer = UIView()
    private let throttleButton = UIButton(type: .custom)
    private let brakeButton = UIButton(type: .custom)
    private let handbrakeButton = UIButton(type: .custom)
    private let nosButton = UIButton(type: .custom)
    private let speedbreakerButton = UIButton(type: .custom)
    private let shiftUpButton = UIButton(type: .custom)
    private let shiftDownButton = UIButton(type: .custom)

    // MARK: - Top Bar Controls
    private let topBar = UIStackView()
    private let pauseButton = UIButton(type: .custom)
    private let cameraButton = UIButton(type: .custom)
    private let modeButton = UIButton(type: .custom)
    private let hideHudButton = UIButton(type: .custom)

    // MARK: - State Tracking
    private var activeTouches: [UITouch: UIView] = [:]
    private var hudOpacity: CGFloat = 0.85
    private var isHiddenByController: Bool = false

    // MARK: - Initialization

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setupViewHierarchy()
        setupControllerObservers()
        prepareHaptics()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViewHierarchy()
        setupControllerObservers()
        prepareHaptics()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func prepareHaptics() {
        lightHaptic.prepare()
        mediumHaptic.prepare()
        heavyHaptic.prepare()
        selectionHaptic.prepare()
    }

    // MARK: - View Layout & Hierarchy

    private func setupViewHierarchy() {
        self.isMultipleTouchEnabled = true
        self.backgroundColor = .clear
        self.alpha = hudOpacity

        addSubview(leftContainer)
        addSubview(rightContainer)
        addSubview(topBar)

        leftContainer.translatesAutoresizingMaskIntoConstraints = false
        rightContainer.translatesAutoresizingMaskIntoConstraints = false
        topBar.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // Left Container (Steering)
            leftContainer.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            leftContainer.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -16),
            leftContainer.widthAnchor.constraint(equalToConstant: 240),
            leftContainer.heightAnchor.constraint(equalToConstant: 220),

            // Right Container (Action Pedals & Pads)
            rightContainer.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            rightContainer.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -16),
            rightContainer.widthAnchor.constraint(equalToConstant: 320),
            rightContainer.heightAnchor.constraint(equalToConstant: 240),

            // Top Bar
            topBar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            topBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 36)
        ])

        setupLeftStick()
        setupLeftSlider()
        setupRightActionCluster()
        setupTopBar()
        updateSteeringControlVisibility()
    }

    // MARK: - Left Screen: Thumbstick & Slider

    private func setupLeftStick() {
        stickBaseView.frame = CGRect(x: 20, y: 20, width: stickRadius * 2, height: stickRadius * 2)
        stickBaseView.layer.cornerRadius = stickRadius
        stickBaseView.layer.borderColor = UIColor(white: 0.8, alpha: 0.35).cgColor
        stickBaseView.layer.borderWidth = 2.0
        stickBaseView.backgroundColor = UIColor(white: 0.1, alpha: 0.45)
        stickBaseView.isUserInteractionEnabled = false

        let knobRadius: CGFloat = 32.0
        stickKnobView.frame = CGRect(x: stickRadius - knobRadius, y: stickRadius - knobRadius, width: knobRadius * 2, height: knobRadius * 2)
        stickKnobView.layer.cornerRadius = knobRadius
        stickKnobView.backgroundColor = UIColor(red: 0.9, green: 0.15, blue: 0.15, alpha: 0.85)
        stickKnobView.layer.borderColor = UIColor.white.cgColor
        stickKnobView.layer.borderWidth = 1.5
        stickKnobView.layer.shadowColor = UIColor.red.cgColor
        stickKnobView.layer.shadowOpacity = 0.6
        stickKnobView.layer.shadowRadius = 8
        stickKnobView.layer.shadowOffset = .zero
        stickKnobView.isUserInteractionEnabled = false

        stickBaseView.addSubview(stickKnobView)
        leftContainer.addSubview(stickBaseView)
    }

    private func setupLeftSlider() {
        steeringSliderTrack.frame = CGRect(x: 10, y: 120, width: 220, height: 48)
        steeringSliderTrack.layer.cornerRadius = 24
        steeringSliderTrack.layer.borderWidth = 1.5
        steeringSliderTrack.layer.borderColor = UIColor(white: 0.8, alpha: 0.4).cgColor
        steeringSliderTrack.backgroundColor = UIColor(white: 0.1, alpha: 0.5)
        steeringSliderTrack.isUserInteractionEnabled = false

        steeringSliderThumb.frame = CGRect(x: 86, y: 4, width: 48, height: 40)
        steeringSliderThumb.layer.cornerRadius = 20
        steeringSliderThumb.backgroundColor = UIColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 0.85)
        steeringSliderThumb.layer.borderColor = UIColor.white.cgColor
        steeringSliderThumb.layer.borderWidth = 1.5
        steeringSliderThumb.isUserInteractionEnabled = false

        steeringSliderTrack.addSubview(steeringSliderThumb)
        leftContainer.addSubview(steeringSliderTrack)
    }

    private func updateSteeringControlVisibility() {
        switch controlMode {
        case .analogStick:
            stickBaseView.isHidden = false
            steeringSliderTrack.isHidden = true
            modeButton.setTitle("STICK", for: .normal)
        case .steeringSlider:
            stickBaseView.isHidden = true
            steeringSliderTrack.isHidden = false
            modeButton.setTitle("SLIDER", for: .normal)
        }
    }

    // MARK: - Right Screen: Action Cluster

    private func setupRightActionCluster() {
        // 1. Throttle / Gas Pedal (Tall Vertical Action Pad)
        configurePedal(throttleButton, title: "GAS", color: UIColor(red: 0.15, green: 0.8, blue: 0.25, alpha: 0.75), frame: CGRect(x: 230, y: 20, width: 75, height: 180))
        
        // 2. Foot Brake / Reverse Pedal
        configurePedal(brakeButton, title: "BRAKE", color: UIColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 0.75), frame: CGRect(x: 145, y: 60, width: 70, height: 140))

        // 3. Handbrake (E-Brake)
        configureRoundButton(handbrakeButton, title: "E-BRK", color: UIColor(red: 0.95, green: 0.55, blue: 0.05, alpha: 0.85), frame: CGRect(x: 65, y: 130, width: 68, height: 68))

        // 4. Nitrous (NOS) - Cyan Purge Styling
        configureRoundButton(nosButton, title: "NOS", color: UIColor(red: 0.0, green: 0.75, blue: 0.95, alpha: 0.9), frame: CGRect(x: 70, y: 50, width: 62, height: 62))
        nosButton.layer.shadowColor = UIColor.cyan.cgColor
        nosButton.layer.shadowOpacity = 0.8
        nosButton.layer.shadowRadius = 10

        // 5. Speedbreaker - Tactical Amber Styling
        configureRoundButton(speedbreakerButton, title: "SPEED\nBRK", color: UIColor(red: 0.95, green: 0.85, blue: 0.1, alpha: 0.85), frame: CGRect(x: 0, y: 90, width: 58, height: 58))
        speedbreakerButton.titleLabel?.numberOfLines = 2
        speedbreakerButton.titleLabel?.textAlignment = .center
        speedbreakerButton.titleLabel?.font = UIFont.systemFont(ofSize: 10, weight: .black)

        // 6. Paddle Shifters (Manual Mode)
        configureSmallButton(shiftUpButton, title: "UP +", frame: CGRect(x: 230, y: 0, width: 75, height: 26))
        configureSmallButton(shiftDownButton, title: "DN -", frame: CGRect(x: 145, y: 30, width: 70, height: 26))

        rightContainer.addSubview(throttleButton)
        rightContainer.addSubview(brakeButton)
        rightContainer.addSubview(handbrakeButton)
        rightContainer.addSubview(nosButton)
        rightContainer.addSubview(speedbreakerButton)
        rightContainer.addSubview(shiftUpButton)
        rightContainer.addSubview(shiftDownButton)
    }

    private func configurePedal(_ button: UIButton, title: String, color: UIColor, frame: CGRect) {
        button.frame = frame
        button.backgroundColor = color
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .heavy)
        button.layer.cornerRadius = 16
        button.layer.borderWidth = 2
        button.layer.borderColor = UIColor.white.cgColor
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.5
        button.layer.shadowRadius = 6
        button.isUserInteractionEnabled = false // Touches handled via view hit-testing
    }

    private func configureRoundButton(_ button: UIButton, title: String, color: UIColor, frame: CGRect) {
        button.frame = frame
        button.backgroundColor = color
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .black)
        button.layer.cornerRadius = frame.width / 2.0
        button.layer.borderWidth = 2
        button.layer.borderColor = UIColor.white.cgColor
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.5
        button.layer.shadowRadius = 6
        button.isUserInteractionEnabled = false
    }

    private func configureSmallButton(_ button: UIButton, title: String, frame: CGRect) {
        button.frame = frame
        button.backgroundColor = UIColor(white: 0.15, alpha: 0.75)
        button.setTitle(title, for: .normal)
        button.setTitleColor(UIColor(white: 0.9, alpha: 1.0), for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 11, weight: .bold)
        button.layer.cornerRadius = 8
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor(white: 0.6, alpha: 0.5).cgColor
        button.isUserInteractionEnabled = false
    }

    // MARK: - Top Bar

    private func setupTopBar() {
        topBar.axis = .horizontal
        topBar.spacing = 12
        topBar.distribution = .fillEqually
        topBar.alignment = .center

        configureTopBarButton(pauseButton, title: "PAUSE", action: #selector(onPauseTapped))
        configureTopBarButton(cameraButton, title: "CAM", action: #selector(onCameraTapped))
        configureTopBarButton(modeButton, title: "STICK", action: #selector(onModeTapped))
        configureTopBarButton(hideHudButton, title: "HIDE", action: #selector(onHideHudTapped))

        topBar.addArrangedSubview(pauseButton)
        topBar.addArrangedSubview(cameraButton)
        topBar.addArrangedSubview(modeButton)
        topBar.addArrangedSubview(hideHudButton)
    }

    private func configureTopBarButton(_ button: UIButton, title: String, action: Selector) {
        button.backgroundColor = UIColor(white: 0.1, alpha: 0.6)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .bold)
        button.layer.cornerRadius = 8
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor(white: 0.7, alpha: 0.3).cgColor
        button.contentEdgeInsets = UIEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    @objc private func onPauseTapped() {
        mediumHaptic.impactOccurred()
        delegate?.touchOverlayDidTriggerPause()
    }

    @objc private func onCameraTapped() {
        selectionHaptic.selectionChanged()
        delegate?.touchOverlayDidTriggerCamera()
    }

    @objc private func onModeTapped() {
        selectionHaptic.selectionChanged()
        controlMode = (controlMode == .analogStick) ? .steeringSlider : .analogStick
    }

    @objc private func onHideHudTapped() {
        UIView.animate(withDuration: 0.25) {
            self.hudOpacity = (self.hudOpacity > 0.3) ? 0.2 : 0.85
            self.alpha = self.hudOpacity
        }
    }

    // MARK: - Multi-Touch Engine

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let pointInView = touch.location(in: self)
            let pointInLeft = touch.location(in: leftContainer)
            let pointInRight = touch.location(in: rightContainer)

            // 1. Left Steering Area
            if leftContainer.bounds.contains(pointInLeft) {
                if controlMode == .analogStick {
                    stickTouch = touch
                    activeTouches[touch] = stickKnobView
                    updateStick(with: pointInLeft)
                } else {
                    sliderTouch = touch
                    activeTouches[touch] = steeringSliderThumb
                    updateSlider(with: pointInLeft)
                }
                lightHaptic.impactOccurred(intensity: 0.5)
                continue
            }

            // 2. Right Action Cluster
            if let hitControl = hitTestRightCluster(point: pointInRight) {
                activeTouches[touch] = hitControl
                handleButtonDown(hitControl)
                continue
            }
        }
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if touch == stickTouch {
                updateStick(with: touch.location(in: leftContainer))
            } else if touch == sliderTouch {
                updateSlider(with: touch.location(in: leftContainer))
            } else if let hitControl = activeTouches[touch] {
                // Check if finger slipped out of right control
                let pointInRight = touch.location(in: rightContainer)
                let frame = hitControl.frame
                if !frame.insetBy(dx: -15, dy: -15).contains(pointInRight) {
                    handleButtonUp(hitControl)
                    activeTouches.removeValue(forKey: touch)
                }
            }
        }
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if touch == stickTouch {
                resetStick()
                stickTouch = nil
                activeTouches.removeValue(forKey: touch)
            } else if touch == sliderTouch {
                resetSlider()
                sliderTouch = nil
                activeTouches.removeValue(forKey: touch)
            } else if let hitControl = activeTouches[touch] {
                handleButtonUp(hitControl)
                activeTouches.removeValue(forKey: touch)
            }
        }
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }

    // MARK: - Steering Calculations

    private func updateStick(with point: CGPoint) {
        let center = CGPoint(x: stickBaseView.frame.midX, y: stickBaseView.frame.midY)
        let dx = point.x - center.x
        let dy = point.y - center.y
        let distance = sqrt(dx * dx + dy * dy)
        let maxDist = stickRadius

        let clampedDist = min(distance, maxDist)
        let angle = atan2(dy, dx)
        let knobX = (center.x - stickBaseView.frame.minX) + clampedDist * cos(angle) - stickKnobView.frame.width / 2.0
        let knobY = (center.y - stickBaseView.frame.minY) + clampedDist * sin(angle) - stickKnobView.frame.height / 2.0
        stickKnobView.frame.origin = CGPoint(x: knobX, y: knobY)

        let normalizedX = Float(dx / maxDist)
        let clampedNormalizedX = max(-1.0, min(1.0, normalizedX))
        delegate?.touchOverlayDidUpdateSteering(clampedNormalizedX)
    }

    private func resetStick() {
        UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut]) {
            let knobRadius: CGFloat = 32.0
            self.stickKnobView.frame = CGRect(x: self.stickRadius - knobRadius, y: self.stickRadius - knobRadius, width: knobRadius * 2, height: knobRadius * 2)
        }
        delegate?.touchOverlayDidUpdateSteering(0.0)
    }

    private func updateSlider(with point: CGPoint) {
        let trackMinX = steeringSliderTrack.frame.minX
        let trackWidth = steeringSliderTrack.frame.width
        let relativeX = max(0, min(trackWidth, point.x - trackMinX))
        let thumbWidth = steeringSliderThumb.frame.width
        steeringSliderThumb.frame.origin.x = relativeX - (thumbWidth / 2.0)

        let normalized = Float((relativeX / trackWidth) * 2.0 - 1.0) // -1.0 to 1.0
        delegate?.touchOverlayDidUpdateSteering(normalized)
    }

    private func resetSlider() {
        UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut]) {
            let thumbWidth = self.steeringSliderThumb.frame.width
            self.steeringSliderThumb.frame.origin.x = (self.steeringSliderTrack.frame.width - thumbWidth) / 2.0
        }
        delegate?.touchOverlayDidUpdateSteering(0.0)
    }

    // MARK: - Right Button Action Handlers

    private func hitTestRightCluster(point: CGPoint) -> UIView? {
        let buttons = [throttleButton, brakeButton, handbrakeButton, nosButton, speedbreakerButton, shiftUpButton, shiftDownButton]
        for b in buttons {
            if b.frame.contains(point) {
                return b
            }
        }
        return nil
    }

    private func handleButtonDown(_ control: UIView) {
        UIView.animate(withDuration: 0.08) {
            control.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
            control.alpha = 1.0
        }

        switch control {
        case throttleButton:
            lightHaptic.impactOccurred()
            delegate?.touchOverlayDidUpdateThrottle(1.0)
        case brakeButton:
            lightHaptic.impactOccurred()
            delegate?.touchOverlayDidUpdateBrake(1.0)
        case handbrakeButton:
            mediumHaptic.impactOccurred()
            delegate?.touchOverlayDidUpdateHandbrake(true)
        case nosButton:
            heavyHaptic.impactOccurred()
            delegate?.touchOverlayDidUpdateNitrous(true)
        case speedbreakerButton:
            mediumHaptic.impactOccurred()
            delegate?.touchOverlayDidUpdateSpeedbreaker(true)
        case shiftUpButton:
            selectionHaptic.selectionChanged()
            delegate?.touchOverlayDidTriggerShiftUp()
        case shiftDownButton:
            selectionHaptic.selectionChanged()
            delegate?.touchOverlayDidTriggerShiftDown()
        default:
            break
        }
    }

    private func handleButtonUp(_ control: UIView) {
        UIView.animate(withDuration: 0.08) {
            control.transform = .identity
            control.alpha = 0.85
        }

        switch control {
        case throttleButton:
            delegate?.touchOverlayDidUpdateThrottle(0.0)
        case brakeButton:
            delegate?.touchOverlayDidUpdateBrake(0.0)
        case handbrakeButton:
            delegate?.touchOverlayDidUpdateHandbrake(false)
        case nosButton:
            delegate?.touchOverlayDidUpdateNitrous(false)
        case speedbreakerButton:
            delegate?.touchOverlayDidUpdateSpeedbreaker(false)
        default:
            break
        }
    }

    // MARK: - Game Controller Auto-Hide Observers

    private func setupControllerObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onControllerConnected(_:)),
            name: .GCControllerDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onControllerDisconnected(_:)),
            name: .GCControllerDidDisconnect,
            object: nil
        )

        // Check if a controller is already connected
        if !GCController.controllers().isEmpty {
            applyControllerConnectedState(connected: true, animated: false)
        }
    }

    @objc private func onControllerConnected(_ notification: Notification) {
        applyControllerConnectedState(connected: true, animated: true)
    }

    @objc private func onControllerDisconnected(_ notification: Notification) {
        let anyConnected = !GCController.controllers().isEmpty
        applyControllerConnectedState(connected: anyConnected, animated: true)
    }

    private func applyControllerConnectedState(connected: Bool, animated: Bool) {
        isHiddenByController = connected
        let targetAlpha: CGFloat = connected ? 0.0 : hudOpacity
        let targetInteraction = !connected

        if animated {
            UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut]) {
                self.alpha = targetAlpha
            } completion: { _ in
                self.isUserInteractionEnabled = targetInteraction
            }
        } else {
            self.alpha = targetAlpha
            self.isUserInteractionEnabled = targetInteraction
        }
    }
}
