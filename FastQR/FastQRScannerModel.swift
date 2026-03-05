//
//  FastQRScannerModel.swift
//  FastQR
//
//  Created by Codex on 2/28/26.
//

import AVFoundation
import Combine
import Foundation
import QuartzCore

final class FastQRScannerModel: NSObject, ObservableObject {
    @Published private(set) var isCameraAuthorized = true
    @Published private(set) var detectedCode: String?
    @Published private(set) var focusRect: CGRect = .zero

    let session = AVCaptureSession()

    private let metadataOutput = AVCaptureMetadataOutput()
    private let defaultInterestRect = CGRect(x: 0.14, y: 0.20, width: 0.72, height: 0.60)

    private var videoDevice: AVCaptureDevice?
    private var isConfigured = false
    private var hasDeliveredResult = false
    private var lastFocusTimestamp: CFTimeInterval = 0
    private var lastDetectionTimestamp: CFTimeInterval = 0

    func requestPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isCameraAuthorized = true
            configureSessionIfNeeded()
            startSessionIfNeeded()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isCameraAuthorized = granted
                    guard granted else { return }
                    self.configureSessionIfNeeded()
                    self.startSessionIfNeeded()
                }
            }
        case .denied, .restricted:
            isCameraAuthorized = false
        @unknown default:
            isCameraAuthorized = false
        }
    }

    func resetForNextScan() {
        hasDeliveredResult = false
        detectedCode = nil
        focusRect = .zero
        metadataOutput.rectOfInterest = defaultInterestRect
    }

    func stopSession() {
        if session.isRunning {
            session.stopRunning()
        }
    }

    private func configureSessionIfNeeded() {
        guard !isConfigured else { return }

        session.beginConfiguration()
        session.sessionPreset = .vga640x480

        defer {
            session.commitConfiguration()
            isConfigured = true
        }

        guard
            let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: camera),
            session.canAddInput(input)
        else {
            isCameraAuthorized = false
            return
        }

        session.addInput(input)
        videoDevice = camera
        configureDeviceForFastScanning(camera)

        guard session.canAddOutput(metadataOutput) else {
            return
        }

        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
        metadataOutput.metadataObjectTypes = [.qr]
        metadataOutput.rectOfInterest = defaultInterestRect

        if let metadataConnection = metadataOutput.connection(with: .video) {
            if metadataConnection.isVideoRotationAngleSupported(90) {
                metadataConnection.videoRotationAngle = 90
            }
            if metadataConnection.isVideoStabilizationSupported {
                metadataConnection.preferredVideoStabilizationMode = .off
            }
        }
    }

    private func startSessionIfNeeded() {
        resetForNextScan()
        if !session.isRunning {
            session.startRunning()
        }
    }

    private func configureDeviceForFastScanning(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()

            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }

            if device.isSmoothAutoFocusSupported {
                device.isSmoothAutoFocusEnabled = false
            }

            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .near
            }

            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }

            if let fpsRange = device.activeFormat.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
                let cappedFPS = min(Int32(fpsRange.maxFrameRate), 60)
                if cappedFPS >= 30 {
                    let frameDuration = CMTime(value: 1, timescale: cappedFPS)
                    device.activeVideoMinFrameDuration = frameDuration
                    device.activeVideoMaxFrameDuration = frameDuration
                }
            }

            device.unlockForConfiguration()
        } catch {
            return
        }
    }

    private func selectMostLikelyQR(from candidates: [AVMetadataMachineReadableCodeObject]) -> AVMetadataMachineReadableCodeObject? {
        candidates.max { lhs, rhs in
            score(for: lhs.bounds) < score(for: rhs.bounds)
        }
    }

    private func score(for rect: CGRect) -> CGFloat {
        let area = rect.width * rect.height
        let centerDistance = hypot(rect.midX - 0.5, rect.midY - 0.5)
        return (area * 2.0) - (centerDistance * 0.35)
    }

    private func tightenRectOfInterest(around rect: CGRect) {
        let paddedRect = rect.insetBy(dx: -(rect.width * 0.35), dy: -(rect.height * 0.35))
        let boundedRect = paddedRect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

        guard boundedRect.width > 0.18, boundedRect.height > 0.18 else {
            metadataOutput.rectOfInterest = defaultInterestRect
            return
        }

        metadataOutput.rectOfInterest = boundedRect
    }

    private func focus(on metadataRect: CGRect) {
        guard let device = videoDevice else { return }

        let now = CACurrentMediaTime()
        guard now - lastFocusTimestamp > 0.14 else { return }
        lastFocusTimestamp = now

        let point = CGPoint(x: metadataRect.midX, y: metadataRect.midY)

        do {
            try device.lockForConfiguration()

            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
            }
            if device.isFocusModeSupported(.autoFocus) {
                device.focusMode = .autoFocus
            }

            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }

            device.unlockForConfiguration()
        } catch {
            return
        }
    }
}

extension FastQRScannerModel: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        let qrCandidates = metadataObjects
            .compactMap { $0 as? AVMetadataMachineReadableCodeObject }
            .filter { $0.type == .qr }

        guard let bestCandidate = selectMostLikelyQR(from: qrCandidates) else {
            if now - lastDetectionTimestamp > 0.40 {
                focusRect = .zero
                metadataOutput.rectOfInterest = defaultInterestRect
            }
            return
        }

        lastDetectionTimestamp = now
        focusRect = bestCandidate.bounds
        tightenRectOfInterest(around: bestCandidate.bounds)
        focus(on: bestCandidate.bounds)

        guard !hasDeliveredResult else { return }
        guard let payload = bestCandidate.stringValue, !payload.isEmpty else { return }

        hasDeliveredResult = true
        detectedCode = payload
    }
}
