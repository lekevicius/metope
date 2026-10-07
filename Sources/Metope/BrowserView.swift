import SwiftUI
import UniformTypeIdentifiers
import MetopeCore

struct BrowserView: View {
    @Bindable var model: AppModel
    @State private var sortOrder = [KeyPathComparator(\RemoteFile.name, comparator: .localizedStandard)]
    @State private var nameDialog: NameDialog?
    @State private var isDropTarget = false
    private var sorted: [RemoteFile] {
        let result = model.visibleFiles.sorted(using: sortOrder)
        return result.filter(\.isFolder) + result.filter { !$0.isFolder }
    }
    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 190, ideal: 218, max: 290)
        } detail: {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if model.connected { fileBrowser; pathBar }
                    else { ConnectionView(model: model) }
                }.safeAreaInset(edge: .bottom, spacing: 0) {
                    if let job = model.activeJob {
                        TransferShelf(job: job, onCancel: model.cancelTransfer)
                            .padding(.horizontal, 18).padding(.bottom, 12)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .textBackgroundColor).backgroundExtensionEffect())
            .overlay { if isDropTarget && model.connected { RoundedRectangle(cornerRadius: 10).strokeBorder(.tint, lineWidth: 3).padding(6).allowsHitTesting(false) } }
            .onDrop(of: [.fileURL], isTargeted: $isDropTarget, perform: acceptDrop)
            .navigationTitle(model.connected ? (model.path == "/" ? model.storage?.name ?? "Files" : (model.path as NSString).lastPathComponent) : "Metope")
            .navigationSubtitle(model.isDemo && !model.isScreenshot ? "Demo · Read-only" : model.device?.name ?? "")
            .toolbar { toolbar }
            .searchable(text: $model.search, placement: .toolbar, prompt: "Search this folder")
            .inspector(isPresented: $model.showInspector) {
                InspectorView(model: model).inspectorColumnWidth(min: 220, ideal: 260, max: 340)
            }
        }
        .frame(minWidth: 840, minHeight: 540)
        .sheet(item: $nameDialog) { dialog in
            NameSheet(title: dialog.file == nil ? "New Folder" : "Rename", initialName: dialog.file?.name ?? "untitled folder") { name in
                if let file = dialog.file { model.rename(file, to: name) } else { model.createFolder(name) }
            }
        }
        .alert(item: $model.notice) { notice in Alert(title: Text(notice.title), message: Text(notice.message), dismissButton: .default(Text("OK"))) }
        .onChange(of: model.search) { _, _ in model.selection.formIntersection(Set(model.visibleFiles.map(\.id))) }
        .onChange(of: model.showHidden) { _, value in UserDefaults.standard.set(value, forKey: "showHidden") }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            if model.activeJobID != nil { model.cancelTransfer() } else { model.service.transport.stop(); model.clearConnection() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in Task { await model.connect() } }
    }
    private var sidebar: some View {
        List(selection: Binding<String?>(get: {
            guard let sid = model.storageID else { return nil }
            return "\(sid)|\(model.path)"
        }, set: { value in
            guard let value else { return }
            if value == "transfers" { model.showTransfers.toggle(); return }
            let parts = value.split(separator: "|", maxSplits: 1)
            if parts.count == 2, let sid = UInt32(parts[0]) { model.navigate(String(parts[1]), storage: sid) }
        })) {
            Section {
                HStack(spacing: 11) {
                    Image(systemName: "iphone.gen3").font(.system(size: 28, weight: .light)).foregroundStyle(model.connected ? Color.primary : Color.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.device?.name ?? "Android device").fontWeight(.semibold)
                        HStack(spacing: 4) {
                            Circle().fill(model.connected ? .green : Color.secondary.opacity(0.4)).frame(width: 5, height: 5)
                            Text(model.isDemo ? (model.isScreenshot ? "USB file transfer" : "Demo device") : model.connected ? "Connected via USB" : "Not connected").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }.padding(.vertical, 10)
            }
            Section("Locations") {
                if model.storages.isEmpty {
                    Label("Internal storage", systemImage: "internaldrive").foregroundStyle(.tertiary)
                }
                ForEach(model.storages) { storage in
                    Label(storage.name, systemImage: "internaldrive")
                        .padding(.vertical, 4).tag("\(storage.id)|/")
                }
            }
            if model.connected {
                Section("Favorites") {
                    favorite("Camera", path: "/DCIM", symbol: "camera")
                    favorite("Pictures", path: "/Pictures", symbol: "photo.on.rectangle")
                    favorite("Downloads", path: "/Download", symbol: "arrow.down.circle")
                    favorite("Music", path: "/Music", symbol: "music.note")
                    favorite("Documents", path: "/Documents", symbol: "doc.text")
                }
            }
            Section {
                HStack { Label("Transfers", systemImage: "arrow.up.arrow.down"); Spacer(); if !model.jobs.isEmpty { Text("\(model.jobs.count)").font(.caption).foregroundStyle(.secondary) } }.tag("transfers")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 9) {
                if let storage = model.storage {
                    HStack { Text("\(byteString(Int64(clamping: storage.Info.FreeSpaceInBytes))) available"); Spacer() }.font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: storage.usedFraction).tint(.secondary).controlSize(.mini)
                    HStack {
                        Text(model.isDemo && !model.isScreenshot ? "Demonstration" : "USB connection").font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                        Button { model.disconnect() } label: { Image(systemName: "eject") }.buttonStyle(.plain).help("Disconnect device").disabled(model.busy)
                    }
                }
            }.padding(18)
        }
    }
    @ViewBuilder private func favorite(_ title: String, path: String, symbol: String) -> some View {
        if model.rootFolders.contains(path), let sid = model.storageID {
            Label(title, systemImage: symbol).padding(.vertical, 3).tag("\(sid)|\(path)")
        }
    }
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(action: model.back) { Image(systemName: "chevron.left") }.help("Back (⌘[)").disabled(model.busy || model.historyIndex == 0)
            Button(action: model.forward) { Image(systemName: "chevron.right") }.help("Forward (⌘])").disabled(model.busy || model.historyIndex + 1 >= model.history.count)
        }
        if model.connected {
            ToolbarItem(placement: .primaryAction) {
                Picker("View", selection: $model.iconView) {
                    Label("List", systemImage: "list.bullet").tag(false)
                    Label("Icons", systemImage: "square.grid.2x2").tag(true)
                }.pickerStyle(.segmented).frame(width: 86).help("List or icon view")
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.importPanel() } label: { Label("Send", systemImage: "arrow.up.to.line") }
                    .help("Send files to phone (⌘U)").disabled(model.isDemo || model.storage?.writable != true || (model.busy && model.activeJobID == nil))
                Button { model.downloadPanel() } label: { Label("Save", systemImage: "arrow.down.to.line") }
                    .help("Save selection to Mac (⌘S)").disabled(model.isDemo || model.selection.isEmpty || (model.busy && model.activeJobID == nil))
                Button { nameDialog = NameDialog(file: nil) } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                    .help("New folder").disabled(!model.canMutate)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { Task { if model.connected { await model.refresh() } else { await model.connect() } } } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }.disabled(model.busy).help("Refresh (⌘R)")
            Button { model.showTransfers.toggle() } label: { Label("Transfers", systemImage: "arrow.down.circle") }
                .popover(isPresented: $model.showTransfers, arrowEdge: .bottom) { TransferHistory(model: model) }
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button { withAnimation { model.showInspector.toggle() } } label: { Label("Inspector", systemImage: "sidebar.right") }
                .help("Show inspector (⌥⌘I)").disabled(!model.connected)
        }
    }
    @ViewBuilder private var fileBrowser: some View {
        if sorted.isEmpty {
            ContentUnavailableView {
                Label(model.search.isEmpty ? "This folder is empty" : "No matching files", systemImage: model.search.isEmpty ? "folder" : "magnifyingglass")
            } description: { Text(model.search.isEmpty ? "Drop files here to send them to your phone." : "Try another name. Search looks in the current folder.") }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.iconView {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 125, maximum: 150), spacing: 18)], spacing: 22) {
                    ForEach(sorted) { file in
                        VStack(spacing: 9) {
                            FileIcon(file: file, size: 56).frame(height: 66)
                            Text(file.name).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.center).frame(height: 32, alignment: .top)
                            Text(file.isFolder ? "Folder" : byteString(file.size)).font(.system(size: 10)).foregroundStyle(.secondary)
                        }.padding(10).frame(maxWidth: .infinity)
                            .background(model.selection.contains(file.id) ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.selection = [file.id]; model.openSelection() }
                            .onTapGesture { if NSEvent.modifierFlags.contains(.command) { if model.selection.contains(file.id) { model.selection.remove(file.id) } else { model.selection.insert(file.id) } } else { model.selection = [file.id] } }
                            .contextMenu { contextActions(file) }
                            .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
                    }
                }.padding(24)
            }
        } else {
            Table(sorted, selection: $model.selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { file in
                    HStack(spacing: 9) {
                        FileIcon(file: file, size: 16).frame(width: 22, height: 16)
                        Text(file.name).lineLimit(1)
                    }.frame(height: 16)
                }.width(min: 220, ideal: 340)
                TableColumn("Date Modified", value: \.dateAdded) { file in
                    if let date = file.modified { Text(date, format: .dateTime.month(.abbreviated).day().year()).foregroundStyle(.secondary) }
                    else { Text("—").foregroundStyle(.tertiary) }
                }.width(min: 115, ideal: 135)
                TableColumn("Size", value: \.size) { file in Text(file.isFolder ? "—" : byteString(file.size)).foregroundStyle(.secondary).monospacedDigit() }.width(85)
                TableColumn("Kind", value: \.kind) { file in Text(file.kind).foregroundStyle(.secondary) }.width(min: 80, ideal: 95)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: String.self) { ids in
                if let file = model.files.first(where: { ids.contains($0.id) }) {
                    Button(file.isFolder ? "Open" : "Quick Look") { model.selection = ids; model.openSelection() }.disabled(ids.count != 1 || model.busy)
                    Button("Save to Mac…") { model.selection = ids; model.downloadPanel() }.disabled(model.isDemo)
                    Divider()
                    Button("Rename…") { nameDialog = NameDialog(file: file) }.disabled(ids.count != 1 || !model.canMutate)
                    Button("Delete…", role: .destructive) { model.selection = ids; model.deleteSelection() }.disabled(!model.canMutate)
                }
            } primaryAction: { ids in model.selection = ids; model.openSelection() }
            .onKeyPress(.space) { model.openSelection(); return .handled }
            .onKeyPress(.return) { if model.canMutate, model.selectedFiles.count == 1 { nameDialog = NameDialog(file: model.selectedFiles[0]) }; return .handled }
            .onDeleteCommand { model.deleteSelection() }
        }
    }
    @ViewBuilder private func contextActions(_ file: RemoteFile) -> some View {
        Button(file.isFolder ? "Open" : "Quick Look") { model.selection = [file.id]; model.openSelection() }.disabled(model.busy)
        Button("Save to Mac…") { model.selection = [file.id]; model.downloadPanel() }.disabled(model.isDemo)
        Divider()
        Button("Rename…") { nameDialog = NameDialog(file: file) }.disabled(!model.canMutate)
        Button("Delete…", role: .destructive) { model.selection = [file.id]; model.deleteSelection() }.disabled(!model.canMutate)
    }
    private var pathBar: some View {
        HStack(spacing: 7) {
                Button { model.navigate("/") } label: { Image(systemName: "internaldrive"); Text(model.storage?.name ?? "Storage") }.buttonStyle(.plain)
                ForEach(Array(model.path.split(separator: "/").enumerated()), id: \.offset) { index, component in
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    Button(String(component)) { model.navigate("/" + model.path.split(separator: "/").prefix(index + 1).joined(separator: "/")) }.buttonStyle(.plain)
                }
                Spacer(minLength: 12)
                Text(model.selection.isEmpty ? "\(model.visibleFiles.count) items" : "\(model.selection.count) selected").foregroundStyle(.secondary)
        }.font(.system(size: 11)).padding(.horizontal, 18).frame(height: 35).disabled(model.busy)
    }
    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard model.connected, !model.isDemo, model.storage?.writable == true else { return false }
        let group = DispatchGroup(), lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else { url = item as? URL }
                if let url, url.isFileURL { lock.lock(); urls.append(url); lock.unlock() }
            }
        }
        group.notify(queue: .main) { model.enqueueUpload(urls) }
        return true
    }
}
struct NameDialog: Identifiable { let id = UUID(); var file: RemoteFile? }
struct NameSheet: View {
    let title: String
    let initialName: String
    let commit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool
    var valid: Bool { (try? TransferSafety.validateName(name)) != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title3.bold())
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).focused($focused).onSubmit(save)
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button(title == "Rename" ? "Rename" : "Create", action: save).keyboardShortcut(.defaultAction).disabled(!valid) }
        }.padding(24).frame(width: 380).onAppear { name = initialName; focused = true }
    }
    func save() { guard valid else { return }; commit(name); dismiss() }
}
