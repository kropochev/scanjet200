import SwiftUI
import AppKit
import ScanjetCore

@main
struct Scanjet200App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ScanViewModel()
    @StateObject private var tooltips = TooltipBoard()

    var body: some Scene {
        WindowGroup("Scanjet 200") {
            ContentView()
                .environmentObject(model)
                .environmentObject(tooltips)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            ScanjetAppCommands(model: model)
        }
        Window("Scanjet 200 Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 560, height: 640)
        Window("Calibration Assistant", id: "calibrate") {
            CalibrationAssistantView()
                .environmentObject(model)
        }
        .defaultSize(width: 520, height: 640)
        Window("About Scanjet 200", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

private struct ScanjetAppCommands: Commands {
    @ObservedObject var model: ScanViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Scanjet 200") {
                openWindow(id: "about")
            }
        }
        CommandGroup(after: .appSettings) {
            Menu("Calibrate") {
                Button("Calibration Assistant…") {
                    openWindow(id: "calibrate")
                }
                Divider()
                ForEach(ScanMode.all, id: \.dpi) { mode in
                    Button(model.calibratedDPI.contains(mode.dpi)
                           ? "\(mode.dpi) dpi ✓"
                           : "\(mode.dpi) dpi") {
                        model.calibrate(dpi: mode.dpi)
                    }
                    .help("Scan a blank white sheet at \(mode.dpi) dpi to flatten lamp and sensor variation.")
                    .disabled(model.isBusy || !model.scannerConnected)
                }
            }
            .help("Calibrate the scanner with a clean white sheet. Use the same resolution as later scans.")
        }
        CommandGroup(replacing: .help) {
            Button("Scanjet 200 Help") {
                openWindow(id: "help")
            }
            .keyboardShortcut("?", modifiers: [.command])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
