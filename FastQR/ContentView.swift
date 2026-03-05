//
//  ContentView.swift
//  FastQR
//
//  Created by Oskar Zhang on 2/28/26.
//

import SwiftUI

struct ContentView: View {
    @State private var lastScannedCode: String?

    var body: some View {
        FastQRScannerScreen(
            lastScannedCode: $lastScannedCode,
            showCloseButton: false,
            dismissOnDetection: false
        )
    }
}

#Preview {
    ContentView()
}
