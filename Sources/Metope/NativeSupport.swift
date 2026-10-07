import AppKit
import SwiftUI
import QuickLookUI

@MainActor final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource {
    private var url: NSURL?
    func show(_ url: URL) {
        self.url = url as NSURL
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self; panel.reloadData(); panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { url }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { model?.prepareToQuit() == false ? .terminateCancel : .terminateNow }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct FileIcon: View {
    let file: MetopeCore.RemoteFile
    var size: CGFloat = 28
    var body: some View {
        Group {
            if file.isFolder {
                Image(systemName: "folder.fill").symbolRenderingMode(.palette)
                    .foregroundStyle(.cyan.gradient, .blue.gradient)
                    .overlay { if file.symbol != "folder.fill" { Image(systemName: file.symbol).font(.system(size: size * 0.3, weight: .semibold)).foregroundStyle(.white.opacity(0.8)).offset(y: size * 0.09) } }
            } else {
                Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data)).resizable().scaledToFit()
            }
        }.font(.system(size: size)).frame(width: size + 6, height: size + 6).accessibilityHidden(true)
    }
}
import MetopeCore
import UniformTypeIdentifiers
