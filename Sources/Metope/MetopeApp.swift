import SwiftUI
import MetopeCore

@main struct MetopeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @AppStorage("appearance") private var appearance = "system"
    var body: some Scene {
        Window("Metope", id: "browser") {
            BrowserView(model: model)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
                .task { delegate.model = model; model.start() }
        }
        .defaultSize(width: 1120, height: 740)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Send Files to Phone…") { model.importPanel() }.keyboardShortcut("u").disabled(!model.connected || model.isDemo)
                Button("Save Selection to Mac…") { model.downloadPanel() }.keyboardShortcut("s").disabled(model.selection.isEmpty || model.isDemo)
            }
            CommandMenu("Go") {
                Button("Back") { model.back() }.keyboardShortcut("[", modifiers: .command).disabled(model.historyIndex == 0 || model.busy)
                Button("Forward") { model.forward() }.keyboardShortcut("]", modifiers: .command).disabled(model.historyIndex + 1 >= model.history.count || model.busy)
                Button("Enclosing Folder") { model.up() }.keyboardShortcut(.upArrow, modifiers: .command).disabled(model.path == "/" || model.busy)
                Divider()
                Button("Open Selection") { model.openSelection() }.keyboardShortcut(.downArrow, modifiers: .command).disabled(model.selectedFiles.count != 1 || model.busy)
                Button("Refresh") { Task { if model.connected { await model.refresh() } else { await model.connect() } } }.keyboardShortcut("r").disabled(model.busy)
                Button("Disconnect") { model.disconnect() }.keyboardShortcut("e").disabled(!model.connected || model.busy)
            }
            CommandGroup(after: .toolbar) {
                Toggle("Show Inspector", isOn: $model.showInspector).keyboardShortcut("i", modifiers: [.command, .option])
                Toggle("Show Hidden Files", isOn: $model.showHidden).keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Transfers") { model.showTransfers.toggle() }.keyboardShortcut("j")
            }
            CommandGroup(replacing: .help) {
                Button(model.isDemo ? "Exit Sample Files" : "Show Sample Files") { model.toggleDemo() }.disabled(model.busy)
                Divider()
                Button("Connection Help") { model.notice = AppNotice(title: "Connect your Android device", message: "1. Use a USB cable that supports data.\n2. Unlock your phone.\n3. Tap its USB notification and choose File Transfer.\n4. Allow access if prompted.\n\nQuit other MTP clients if they’re using the connection. Connect one device at a time.") }
            }
        }
        Settings { SettingsView(model: model) }
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("appearance") private var appearance = "system"
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                Toggle("Show hidden files", isOn: $model.showHidden)
            }
            Section("File transfers") {
                LabeledContent("Existing files", value: "Never overwrite")
                Text("If a name already exists, choose another folder or rename the file. Downloaded file sizes are checked before saving.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Metope", value: "0.1.0")
                Button("Open acknowledgments") {
                    if let url = Bundle.main.url(forResource: "ACKNOWLEDGMENTS", withExtension: "txt") { NSWorkspace.shared.open(url) }
                }
            }
        }.formStyle(.grouped).frame(width: 460, height: 410)
    }
}
