//
//  FastQRScannerView.swift
//  FastQR
//
//  Created by Codex on 2/28/26.
//

import AVFoundation
import SwiftUI
import UIKit

struct FastQRScannerScreen: View {
    @Binding var lastScannedCode: String?
    var showCloseButton: Bool = true
    var dismissOnDetection: Bool = true

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var scannerModel = FastQRScannerModel()
    @State private var lastAutoOpenedURL: URL?
    @State private var lastAutoOpenedAt: Date = .distantPast

    var body: some View {
        ZStack {
            CameraPreview(session: scannerModel.session, focusRect: scannerModel.focusRect)
                .ignoresSafeArea()
                .overlay {
                    ScannerMask()
                        .ignoresSafeArea()
                }

            VStack {
                topBar
                Spacer()
                bottomPanel
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 26)

            if !scannerModel.isCameraAuthorized {
                permissionOverlay
            }
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            scannerModel.requestPermissionAndStart()
        }
        .onDisappear {
            scannerModel.stopSession()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !dismissOnDetection else { return }
            scannerModel.requestPermissionAndStart()
        }
        .onChange(of: scannerModel.detectedCode) { _, newValue in
            guard let newValue, !newValue.isEmpty else { return }
            lastScannedCode = newValue

            if let url = browserURL(from: newValue), shouldAutoOpen(url) {
                lastAutoOpenedURL = url
                lastAutoOpenedAt = Date()
                scannerModel.stopSession()
                openURL(url)
                if dismissOnDetection {
                    dismiss()
                }
                return
            }

            if dismissOnDetection {
                dismiss()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    scannerModel.resetForNextScan()
                }
            }
        }
    }

    private func shouldAutoOpen(_ url: URL) -> Bool {
        if lastAutoOpenedURL == url, Date().timeIntervalSince(lastAutoOpenedAt) < 5 {
            return false
        }
        return true
    }

    private func browserURL(from payload: String) -> URL? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            (scheme == "http" || scheme == "https"),
            url.host != nil
        {
            return url
        }

        if !trimmed.contains(" "), trimmed.contains(".") {
            let normalized = "https://\(trimmed)"
            if let url = URL(string: normalized), url.host != nil {
                return url
            }
        }

        return nil
    }

    private var topBar: some View {
        HStack {
            if showCloseButton {
                Button {
                    dismiss()
                } label: {
                    Label("Close", systemImage: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.5), in: Capsule())
                        .foregroundStyle(.white)
                }
            } else {
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 16, weight: .bold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.5), in: Capsule())
                    .foregroundStyle(.white)
            }

            Spacer()

            Text("Fast Scanner")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.5), in: Capsule())
        }
    }

    private var bottomPanel: some View {
        VStack(spacing: 10) {
            Text("Point the camera at a QR code")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("FastQR narrows search to the most likely QR area and shifts autofocus onto that rectangle.")
                .font(.system(size: 14, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
    }

    private var permissionOverlay: some View {
        VStack(spacing: 14) {
            Text("Camera Access Required")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("Allow camera access so the action button can launch the fast QR scanner.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)

            Button {
                guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(settingsURL)
            } label: {
                Text("Open Settings")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color(red: 0.55, green: 0.95, blue: 0.92), in: Capsule())
            }
        }
        .padding(22)
        .frame(maxWidth: 340)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 20))
        .padding(24)
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let focusRect: CGRect

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {
        uiView.previewLayer.session = session
        uiView.updateFocusRect(focusRect)
    }
}

private final class CameraPreviewView: UIView {
    private let focusLayer = CAShapeLayer()

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            return AVCaptureVideoPreviewLayer()
        }
        return layer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupFocusLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupFocusLayer()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    func updateFocusRect(_ metadataRect: CGRect) {
        guard metadataRect != .zero else {
            focusLayer.path = nil
            return
        }

        let convertedRect = previewLayer.layerRectConverted(fromMetadataOutputRect: metadataRect)
        focusLayer.path = UIBezierPath(roundedRect: convertedRect, cornerRadius: 10).cgPath
    }

    private func setupFocusLayer() {
        focusLayer.strokeColor = UIColor.systemTeal.cgColor
        focusLayer.fillColor = UIColor.clear.cgColor
        focusLayer.lineWidth = 3
        focusLayer.shadowColor = UIColor.systemTeal.cgColor
        focusLayer.shadowOpacity = 0.7
        focusLayer.shadowRadius = 8
        focusLayer.shadowOffset = .zero
        layer.addSublayer(focusLayer)
    }
}

private struct ScannerMask: View {
    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width * 0.76, 320)
            let height = width
            let frame = CGRect(
                x: (proxy.size.width - width) / 2,
                y: (proxy.size.height - height) / 2 - 48,
                width: width,
                height: height
            )

            ZStack {
                Rectangle()
                    .fill(.black.opacity(0.35))

                RoundedRectangle(cornerRadius: 22)
                    .frame(width: frame.width, height: frame.height)
                    .blendMode(.destinationOut)
                    .overlay {
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(.white.opacity(0.65), lineWidth: 2)
                    }
                    .position(x: frame.midX, y: frame.midY)
            }
            .compositingGroup()
        }
        .allowsHitTesting(false)
    }
}
