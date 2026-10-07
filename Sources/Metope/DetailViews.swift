import SwiftUI
import MetopeCore

struct ConnectionView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.035)).frame(width: 208, height: 208)
                Circle().strokeBorder(Color.accentColor.opacity(0.08), lineWidth: 1).frame(width: 166, height: 166)
                Image(systemName: "iphone.gen3").font(.system(size: 86, weight: .ultraLight)).foregroundStyle(.primary.opacity(0.8))
                Image(systemName: "cable.connector").font(.system(size: 25, weight: .light)).foregroundStyle(.secondary).offset(y: 73)
            }.padding(.bottom, 22)
            Text(model.connecting ? "Connecting…" : model.connectionIssue?.errorDescription ?? "Connect an Android device")
                .font(.system(size: 25, weight: .semibold)).multilineTextAlignment(.center)
            if let suggestion = model.connectionIssue?.recoverySuggestion {
                Text(suggestion)
                    .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(4)
                    .frame(maxWidth: 405).padding(.top, 11)
            }
            HStack(alignment: .top, spacing: 26) {
                step("1", "Connect USB", "Use a data cable")
                step("2", "Unlock", "Keep your phone awake")
                step("3", "File Transfer", "Choose in USB settings")
            }.padding(.top, 32).padding(.bottom, 28)
            if model.connecting { ProgressView().controlSize(.small).frame(height: 28) }
            else { Button("Connect") { Task { await model.connect() } }.buttonStyle(.glassProminent).controlSize(.large) }
            Spacer()
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func step(_ number: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 7) {
            Text(number).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 23, height: 23).background(.quaternary, in: Circle())
            Text(title).font(.system(size: 12, weight: .medium))
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
struct InspectorView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Information").fontWeight(.semibold); Spacer(); Button { model.showInspector = false } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }.buttonStyle(.plain).help("Close inspector") }.padding(18)
            Divider()
            if model.selectedFiles.count == 1, let file = model.selectedFiles.first {
                ScrollView {
                    VStack(spacing: 16) {
                        FileIcon(file: file, size: 76).padding(.top, 30)
                        Text(file.name).font(.system(size: 14, weight: .semibold)).lineLimit(3).truncationMode(.middle).multilineTextAlignment(.center).textSelection(.enabled)
                        Text(file.kind).font(.callout).foregroundStyle(.secondary)
                        Divider().padding(.vertical, 7)
                        VStack(alignment: .leading, spacing: 17) {
                            info("Size", value: file.isFolder ? "—" : byteString(file.size))
                            if let date = file.modified { info("Modified", value: date.formatted(date: .abbreviated, time: .shortened)) }
                            info("Location", value: file.parentPath == "/" ? model.storage?.name ?? "/" : file.parentPath)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if !file.isFolder { Button("Quick Look") { model.preview(file) }.buttonStyle(.glass).disabled(model.busy || model.isDemo).padding(.top, 12) }
                    }.padding(.horizontal, 22)
                }
            } else if model.selectedFiles.count > 1 {
                Spacer(); Image(systemName: "doc.on.doc").font(.system(size: 48, weight: .light)).foregroundStyle(.secondary)
                Text("\(model.selection.count) items selected").font(.headline).padding(.top, 18); Spacer()
            } else {
                Spacer(); Image(systemName: "info.circle").font(.system(size: 32, weight: .light)).foregroundStyle(.tertiary)
                Text("Select a file to see its details.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(20); Spacer()
            }
        }
    }
    private func info(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary); Text(value).font(.system(size: 12)).textSelection(.enabled) }
    }
}
struct TransferShelf: View {
    let job: TransferJob
    let onCancel: () -> Void
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: job.upload ? "arrow.up.doc" : "arrow.down.doc").font(.system(size: 22, weight: .light)).foregroundStyle(.tint).frame(width: 30)
            VStack(alignment: .leading, spacing: 7) {
                HStack { Text("\(job.state.rawValue) \(job.title)").font(.system(size: 12, weight: .medium)).lineLimit(1); Spacer(); if let p = job.progress { Text("\(Int(p.fraction * 100))%").font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary) } }
                if let p = job.progress { ProgressView(value: p.fraction).controlSize(.small) }
                else { ProgressView().progressViewStyle(.linear).controlSize(.small) }
                HStack {
                    Text(job.progress?.name ?? (job.upload ? "To your phone" : "To your Mac")).lineLimit(1)
                    Spacer()
                    if let p = job.progress { Text("\(byteString(p.bulkFileSize.sent)) of \(byteString(p.bulkFileSize.total)) · \(String(format: "%.1f", p.speed)) MB/s").monospacedDigit() }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Button(action: onCancel) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.system(size: 18)) }.buttonStyle(.plain).help("Stop transfer")
        }.padding(.horizontal, 20).padding(.vertical, 15)
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}
struct TransferHistory: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                if !model.jobs.isEmpty { Button("Clear Finished") { model.jobs.removeAll { [.completed, .failed, .cancelled].contains($0.state) } }.font(.caption).buttonStyle(.plain).foregroundStyle(.tint) }
            }.padding(18)
            Divider()
            if model.jobs.isEmpty {
                VStack(spacing: 12) { Image(systemName: "arrow.up.arrow.down").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary); Text("No transfers").font(.callout).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(.vertical, 45)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.jobs) { job in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: job.state == .completed ? "checkmark.circle.fill" : job.state == .failed ? "exclamationmark.circle" : job.upload ? "arrow.up.circle" : "arrow.down.circle")
                                    .foregroundStyle(job.state == .completed ? Color.green : job.state == .failed ? .orange : .secondary).font(.system(size: 22, weight: .light))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(job.title).fontWeight(.medium).lineLimit(1)
                                    Text(job.message ?? job.state.rawValue).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    if let url = job.recoveryURL { Button("Show unfinished download") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path) }.font(.caption).buttonStyle(.link) }
                                    if let url = job.resultURLs.first { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.font(.caption).buttonStyle(.link) }
                                }
                                Spacer(minLength: 0)
                                if job.id == model.activeJobID { Button { model.cancelTransfer() } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).help("Stop transfer") }
                            }.padding(18)
                            Divider().padding(.leading, 52)
                        }
                    }
                }.frame(maxHeight: 360)
            }
        }.frame(width: 380)
    }
}
