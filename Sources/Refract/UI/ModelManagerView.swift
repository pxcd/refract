import AppKit
import SwiftUI

@MainActor final class ModelManagerNavigation: ObservableObject {
    @Published private(set) var kind: ModelKind = .generation
    @Published private(set) var request = UUID()

    func show(_ kind: ModelKind) {
        self.kind = kind
        request = UUID()
    }
}

struct OpenModelManager<Title: View>: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var navigation: ModelManagerNavigation
    let kind: ModelKind
    @ViewBuilder var title: () -> Title

    var body: some View {
        Button {
            navigation.show(kind)
            openWindow(id: "models")
        } label: {
            title()
        }
    }
}

private extension ModelKind {
    var title: String {
        switch self {
        case .generation: "Generation"
        case .enhancement: "Enhancement"
        case .lora: "LoRAs"
        }
    }

    var symbol: String {
        switch self {
        case .generation: "sparkles"
        case .enhancement: "wand.and.stars"
        case .lora: "slider.horizontal.3"
        }
    }
}

struct ModelManagerView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var studio: StudioStore
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var navigation: ModelManagerNavigation
    @State private var kind: ModelKind?
    @State private var selection: ModelCatalogRow.ID?
    @State private var query = ""
    @State private var dropTargeted = false
    @State private var importing: String?
    @State private var errorMessage: String?
    @State private var removing: ModelStore.ModelRemoval?

    private var rows: [ModelCatalogRow] {
        ModelCatalogRow.make(catalog: ModelStore.catalog, localModels: models.models)
    }

    private var visibleRows: [ModelCatalogRow] {
        rows.filter { row in
            guard kind == nil || row.kind == kind else { return false }
            let fields = [row.name, row.kind.title, row.entry?.repository, row.entry?.variant,
                          row.entry?.precision, row.model?.name, row.model?.variant, row.model?.precision]
            return matches(fields.compactMap { $0 })
        }
    }

    private func matches(_ fields: [String]) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(String(term)) } }
    }

    private var visibleIDs: [ModelCatalogRow.ID] { visibleRows.map(\.id) }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                modelList
                    .frame(width: geometry.size.width * 0.60)
                Divider()
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 700, minHeight: 450)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: chooseFiles) { Label("Import…", systemImage: "plus") }
                    .help("Import or drag model files into this window")
                    .disabled(importing != nil)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard importing == nil, !urls.isEmpty else { return false }
            importFiles(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { openSection() }
        .onChange(of: navigation.request) { _, _ in openSection() }
        .onChange(of: visibleIDs) { _, ids in
            if selection.map(ids.contains) != true { selection = ids.first }
        }
        .alert("Models", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("Move model to Trash?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { removal in
            Button("Move to Trash", role: .destructive) {
                do { try models.remove(removal) } catch { errorMessage = error.localizedDescription }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { removal in
            Text("Move the model files for \(removal.model.name) to the Trash.")
        }
    }

    private var modelList: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                searchField
                ModelTypeFilter(selection: $kind)
                    .frame(maxWidth: .infinity)
            }
            .padding(12)
            Divider()
            if let notice = models.notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .padding(12)
            }
            let matches = visibleRows
            if matches.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if matches.isEmpty {
                ContentUnavailableView("No models", systemImage: "square.3.layers.3d",
                                       description: Text("Choose another model type or import a local file."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let yourModels = matches.filter { $0.model != nil }
                let catalogModels = matches.filter { $0.model == nil }
                List(selection: $selection) {
                    if !yourModels.isEmpty {
                        Section("Your Models") {
                            ForEach(yourModels, content: row)
                        }
                    }
                    if !catalogModels.isEmpty {
                        Section("Catalog") {
                            ForEach(catalogModels, content: row)
                        }
                    }
                }
                .listStyle(.inset)
            }
            if let importing {
                Divider()
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking " + importing).lineLimit(1)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(12)
            }
        }
    }

    @ViewBuilder private var detailPane: some View {
        if let item = visibleRows.first(where: { $0.id == selection }) {
            modelDetail(item)
        } else {
            ContentUnavailableView("Select a model", systemImage: "square.3.layers.3d")
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search Models", text: $query)
                .textFieldStyle(.plain)
                .frame(maxWidth: .infinity)
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }

    private func row(_ item: ModelCatalogRow) -> some View {
        let useLightIcon = selection == item.id || colorScheme == .dark
        let iconColor: Color
        switch item.model?.managed {
        case .some(true):
            iconColor = useLightIcon ? Color(red: 1.0, green: 0.83, blue: 0.28)
                                     : Color(red: 0.61, green: 0.40, blue: 0.03)
        case .some(false):
            iconColor = useLightIcon ? Color(red: 0.40, green: 0.91, blue: 0.80)
                                     : Color(red: 0.00, green: 0.45, blue: 0.42)
        case nil:
            iconColor = .secondary
        }
        return HStack(spacing: 10) {
            Image(systemName: item.kind.symbol)
                .fontWeight(item.model != nil ? .semibold : .regular)
                .frame(width: 22)
                .foregroundStyle(iconColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(1)
                Text(item.kind.title).font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let model = item.model {
                Text(model.managed ? "Installed" : "Linked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                modelActions(model)
            } else if let entry = item.entry, let transfer = models.downloads[entry.id], transfer.isRunning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(transfer.isCancelling ? "Canceling download" : "Downloading")
            }
        }
        .frame(minHeight: 42)
        .fixedSize(horizontal: false, vertical: true)
        .tag(item.id)
    }

    @ViewBuilder private func downloadAction(_ entry: CatalogModel) -> some View {
        if models.downloads[entry.id]?.isCancelling == true {
            Button("Canceling…") {}.disabled(true)
        } else if models.downloads[entry.id]?.isRunning == true {
            cancelDownloadButton(entry)
        } else if entry.canDownload {
            let canResume = models.hasPartialDownload(entry)
            HStack {
                Button(canResume ? "Resume" : "Download") {
                    Task {
                        do { try await models.download(entry) }
                        catch is CancellationError {}
                        catch { errorMessage = error.localizedDescription }
                    }
                }
                if canResume {
                    cancelDownloadButton(entry).buttonStyle(.bordered)
                }
            }
        } else {
            Text("Import only").foregroundStyle(.secondary)
        }
    }

    private func cancelDownloadButton(_ entry: CatalogModel) -> some View {
        Button("Cancel", role: .destructive) {
            do { try models.cancelDownload(entry) }
            catch { errorMessage = error.localizedDescription }
        }
        .help("Discard the incomplete download")
    }

    private func modelActions(_ model: StudioModel) -> some View {
        Menu {
            Button("Show in Finder", systemImage: "folder") {
                studio.reveal(URL(fileURLWithPath: model.path))
            }
            Divider()
            if let removal = models.removal(for: model) {
                Button("Move to Trash…", systemImage: "trash", role: .destructive) {
                    removing = removal
                }
            } else if !model.managed {
                Button("Unlink from Refract", systemImage: "minus.circle") {
                    do { try models.unlink(model) } catch { errorMessage = error.localizedDescription }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Actions for \(model.name)")
    }

    private func modelDetail(_ item: ModelCatalogRow) -> some View {
        detail(item.name, kind: item.kind) {
            if let entry = item.entry { Text(entry.detail).foregroundStyle(.secondary) }
            if let model = item.model {
                metadata(model.precision, bytes: model.bytes, license: item.entry?.license ?? model.license)
                memoryDetails(kind: model.kind, variant: model.variant)
                if model.kind != .lora {
                    Button("Use Model") {
                        if model.kind == .generation { studio.activeGenerationID = model.id }
                        else { studio.activeEnhancementID = model.id }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if let entry = item.entry {
                metadata(entry.precision, bytes: entry.bytes, license: entry.license)
                memoryDetails(kind: entry.kind, variant: entry.variant)
                if let transfer = models.downloads[entry.id] {
                    if transfer.isRunning && !transfer.isCancelling {
                        ProgressView(value: min(1, max(0, transfer.fraction)))
                    }
                    Text(transfer.message).font(.callout).foregroundStyle(.secondary)
                }
                downloadAction(entry).buttonStyle(.borderedProminent)
            }
            if let entry = item.entry { Link("Model source and license", destination: entry.sourceURL) }
        }
    }

    private func detail<Content: View>(_ title: String, kind: ModelKind, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: kind.symbol).font(.system(size: 27)).foregroundStyle(.tint)
                Text(title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
        }
    }

    private func metadata(_ precision: String, bytes: Int64, license: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if bytes > 0 {
                Text(precision + " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            } else {
                Text(precision)
            }
            Text(license)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    private func memoryDetails(kind: ModelKind, variant: String) -> some View {
        let macMemoryGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return VStack(alignment: .leading, spacing: 5) {
            if kind == .lora {
                Text("Memory needs depend on the generation model.")
                    .foregroundStyle(.secondary)
            } else if let guidance = RefractCatalog.memoryGuidance(for: variant) {
                let meetsRecommendation = macMemoryGB >= guidance.recommendedGB
                let size = guidance.referenceSize
                Text("\(guidance.recommendedGB) GB unified memory recommended").fontWeight(.semibold)
                Text(meetsRecommendation
                     ? "This Mac has \(macMemoryGB) GB and meets the recommendation."
                     : "This Mac has \(macMemoryGB) GB, below the recommendation.")
                    .foregroundStyle(meetsRecommendation ? Color.secondary : Color.orange)
                Text("Estimate for \(size.width) × \(size.height) output. Larger images may need more memory.")
                    .foregroundStyle(.secondary)
            } else {
                Text("No verified memory recommendation for this model.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private func openSection() {
        query = ""
        kind = navigation.kind
        let options = visibleRows
        selection = (options.first { $0.model != nil } ?? options.first)?.id
    }

    private func chooseFiles() {
        let urls = StudioPanels.choose("Import Models", directories: true, multiple: true)
        if !urls.isEmpty { importFiles(urls) }
    }

    private func importFiles(_ urls: [URL]) {
        guard let first = urls.first, importing == nil else { return }
        importing = first.lastPathComponent
        Task {
            var failures: [String] = []
            var imported: [StudioModel] = []
            for url in urls {
                importing = url.lastPathComponent
                do { imported.append(try await models.importModel(at: url)) }
                catch { failures.append(url.lastPathComponent + " — " + error.localizedDescription) }
            }
            importing = nil
            if let firstModel = imported.first {
                query = ""
                kind = imported.allSatisfy { $0.kind == firstModel.kind } ? firstModel.kind : nil
                selection = rows.first { $0.model?.id == firstModel.id }?.id
            }
            if !failures.isEmpty {
                errorMessage = failures.prefix(4).joined(separator: "\n\n")
                if failures.count > 4 { errorMessage?.append("\n\n\(failures.count - 4) more files could not be imported.") }
            }
        }
    }
}


private struct ModelTypeFilter: NSViewRepresentable {
    private static let kinds: [ModelKind?] = [nil] + ModelKind.allCases.map(Optional.some)
    @Binding var selection: ModelKind?

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: Self.kinds.map { $0?.title ?? "All" },
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectSegment(_:))
        )
        control.controlSize = .small
        control.segmentDistribution = .fillEqually
        control.setAccessibilityLabel("Model type")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = Self.kinds.firstIndex(of: selection) ?? 0
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: nsView.intrinsicContentSize.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<ModelKind?>

        init(selection: Binding<ModelKind?>) {
            self.selection = selection
        }

        @objc func selectSegment(_ control: NSSegmentedControl) {
            let index = control.selectedSegment
            guard ModelTypeFilter.kinds.indices.contains(index) else { return }
            selection.wrappedValue = ModelTypeFilter.kinds[index]
        }
    }
}
