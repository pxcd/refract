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
    private enum Page: String {
        case installed = "Installed"
        case catalog = "Catalog"
    }

    @EnvironmentObject private var studio: StudioStore
    @EnvironmentObject private var models: ModelStore
    @EnvironmentObject private var navigation: ModelManagerNavigation
    @State private var page: Page? = .installed
    @State private var kind: ModelKind?
    @State private var selection: String?
    @State private var query = ""
    @State private var dropTargeted = false
    @State private var importing: String?
    @State private var errorMessage: String?
    @State private var removing: ModelStore.ModelRemoval?

    private var installed: [StudioModel] {
        models.models.filter { model in
            (kind == nil || model.kind == kind) && matches([model.name, model.variant, model.kind.title, model.precision])
        }
    }

    private var catalog: [CatalogModel] {
        ModelStore.catalog.filter { entry in
            (kind == nil || entry.kind == kind) &&
                matches([entry.name, entry.repository, entry.variant, entry.kind.title, entry.precision])
        }
    }

    private func matches(_ fields: [String]) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(String(term)) } }
    }

    private var visibleIDs: [String] {
        page == .catalog ? catalog.map(\.id) : installed.map(\.id)
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                List(selection: $page) {
                    Label("Installed", systemImage: "tray.full").tag(Page.installed)
                    Label("Catalog", systemImage: "square.grid.2x2").tag(Page.catalog)
                }
                .listStyle(.sidebar)
                .frame(width: 165)
                Divider()
                modelList
                    .frame(width: geometry.size.width * 0.46)
                Divider()
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 860, minHeight: 450)
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
            if removal.followsLink {
                Text("Move the weights for \(removal.model.name) to the Trash. Other links or apps using these weights will lose access until you restore them.")
            } else {
                Text("Move the model files for \(removal.model.name) to the Trash.")
            }
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
            if visibleIDs.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleIDs.isEmpty {
                ContentUnavailableView(page == .catalog ? "No catalog entries" : "No models installed",
                                       systemImage: "square.3.layers.3d",
                                       description: Text(page == .catalog ? "Choose another model type or import a local file." : "Browse the catalog or import your own models."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    if page == .catalog {
                        ForEach(catalog) { entry in
                            row(entry.name, kind: entry.kind) {
                                downloadAction(entry).buttonStyle(.borderless)
                                if let model = installedModel(for: entry) {
                                    modelActions(model)
                                }
                            }
                            .tag(entry.id)
                        }
                    } else {
                        ForEach(installed) { model in
                            row(model.name, kind: model.kind) {
                                if isActive(model) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(selection == model.id ? Color.primary : Color.accentColor)
                                        .accessibilityLabel("Active")
                                }
                                modelActions(model)
                            }
                            .tag(model.id)
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
        if page == .catalog, let entry = catalog.first(where: { $0.id == selection }) {
            catalogDetail(entry)
        } else if page != .catalog, let model = installed.first(where: { $0.id == selection }) {
            installedDetail(model)
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

    private func row<Trailing: View>(_ title: String, kind: ModelKind, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: kind.symbol)
                .frame(width: 22)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).lineLimit(1)
                Text(kind.title).font(.caption).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
            trailing()
        }
        .frame(minHeight: 42)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func downloadAction(_ entry: CatalogModel) -> some View {
        if installedModel(for: entry) != nil {
            Label("Installed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        } else if models.downloads[entry.id]?.isRunning == true {
            Button("Cancel") { models.cancelDownload(entry.id) }
        } else if entry.canDownload {
            Button(models.downloads[entry.id] == nil ? "Download" : "Resume") {
                Task {
                    do { try await models.download(entry) }
                    catch is CancellationError {}
                    catch { errorMessage = error.localizedDescription }
                }
            }
        } else {
            Text("Import only").foregroundStyle(.secondary)
        }
    }

    private func installedModel(for entry: CatalogModel) -> StudioModel? {
        models.models.first { $0.id == entry.identity }
    }

    private func modelActions(_ model: StudioModel) -> some View {
        Menu {
            Button("Show in Finder", systemImage: "folder") {
                studio.reveal(URL(fileURLWithPath: model.path))
            }
            Divider()
            Button("Move to Trash…", systemImage: "trash", role: .destructive) {
                removing = models.removal(for: model)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Actions for \(model.name)")
    }

    private func catalogDetail(_ entry: CatalogModel) -> some View {
        detail(entry.name, kind: entry.kind) {
            Text(entry.detail).foregroundStyle(.secondary)
            metadata(entry.precision, bytes: entry.bytes, license: entry.license, memory: entry.memoryEstimate)
            if let transfer = models.downloads[entry.id] {
                if transfer.isRunning { ProgressView(value: min(1, max(0, transfer.fraction))) }
                Text(transfer.message).font(.callout).foregroundStyle(.secondary)
            }
            downloadAction(entry).buttonStyle(.borderedProminent)
            Link("Model source and license", destination: entry.sourceURL)
        }
    }

    private func installedDetail(_ model: StudioModel) -> some View {
        detail(model.name, kind: model.kind) {
            metadata(model.precision, bytes: model.bytes, license: model.license,
                     memory: studio.memorySamples[model.id]?.description ?? model.memoryEstimate)
            if model.kind != .lora && !isActive(model) {
                Button("Use Model") {
                    if model.kind == .generation { studio.activeGenerationID = model.id }
                    else { studio.activeEnhancementID = model.id }
                }
                .buttonStyle(.borderedProminent)
            }
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

    private func metadata(_ precision: String, bytes: Int64, license: String, memory: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if bytes > 0 {
                Text(precision + " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            } else {
                Text(precision)
            }
            Text(license)
            Text(memory)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }

    private func isActive(_ model: StudioModel) -> Bool {
        switch model.kind {
        case .generation: studio.activeGenerationID == model.id
        case .enhancement: studio.activeEnhancementID == model.id
        case .lora: false
        }
    }

    private func openSection() {
        query = ""
        kind = navigation.kind
        let hasModels = models.models.contains(where: { $0.kind == navigation.kind })
        page = hasModels || navigation.kind == .lora ? .installed : .catalog
        selection = visibleIDs.first
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
                page = .installed
                kind = imported.allSatisfy { $0.kind == firstModel.kind } ? firstModel.kind : nil
                selection = firstModel.id
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
