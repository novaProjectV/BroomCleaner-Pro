// AppDrag.swift
import SwiftUI
import UniformTypeIdentifiers
import AppKit

// Модель строки предпросмотра
private struct CandidatePath: Identifiable {
    var id: String            // was 'let id'; make it 'var' to satisfy ForEach with bindings
    let url: URL
    let size: Int64
    var selected: Bool
}

/// Перетащи .app → увидишь, что удалим, и сколько освободим
struct AppDragTarget: View {
    @State private var isTargeted = false
    @State private var isWorking = false
    @State private var status: String = "Перетащите приложение (.app) сюда для сканирования."

    @State private var appName: String = ""
    @State private var bundleID: String? = nil
    @State private var appIcon: NSImage? = nil
    @State private var candidates: [CandidatePath] = []

    // Hover states
    @State private var hoveredRowID: String?

    var body: some View {
        ZStack {
            content
            // Подсветка рамкой — не перехватывает события
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: backgroundGradientColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ).opacity(isTargeted ? 0.10 : 0.06)
                )
                .overlay(
                    AnimatedDashedBorder(
                        isActive: isTargeted,
                        color: .blue.opacity(isTargeted ? 0.55 : 0.25),
                        cornerRadius: 16
                    )
                )
                .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL, UTType.url, UTType.application, UTType.package, UTType.data], isTargeted: $isTargeted, perform: handleDrop(providers:))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Область перетаскивания приложения")
    }

    // MARK: - Визуал
    private var content: some View {
        Group {
            if #available(macOS 26.0, *) {
                inner
                    .padding(16)
                    .glassEffect(in: .rect(cornerRadius: 16))
            } else {
                inner
                    .padding(16)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private var inner: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Text(status)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if !candidates.isEmpty {
                Divider()

                totalsBar

                foldersPreview
                    .padding(.top, 6)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach($candidates) { $item in
                            candidateRow(item: $item)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 240)

                footerButtons
            } else {
                emptyState
            }
        }
    }

    private var foldersPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Будут удалены папки:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            let items = candidates.filter { isDirectory($0.url) }
            ForEach(items.prefix(12), id: \.id) { item in
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(displayPath(item.url))
                        .font(.footnote.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            if candidates.count > 12 {
                Text("и ещё \(candidates.count - 12)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .cornerRadius(6)
                } else {
                    Image(systemName: "shippingbox")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.blue)
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle).font(.headline)
                if let id = bundleID, !id.isEmpty {
                    Text(id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }

            Spacer()
            if isWorking { ProgressView().controlSize(.small) }
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.app.fill")
                    .foregroundStyle(.secondary)
                Text("Перетащите .app сюда. Поддерживаются и alias/ярлыки.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
            Button("Выбрать .app…", systemImage: "folder") { pickApp() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut("o", modifiers: [.command])
        }
    }

    private var totalsBar: some View {
        HStack(spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Выбрано: \(selectedCount) из \(candidates.count)")
                        .font(.subheadline)
                    Text(verbatim: "Итого: \(formatBytes(selectedTotal))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "sum")
                    .imageScale(.medium)
                    .foregroundStyle(.blue)
            }

            Spacer()

            HStack(spacing: 6) {
                Button("Выбрать все") { setSelection(true) }
                    .controlSize(.small)
                Button("Снять выбор") { setSelection(false) }
                    .controlSize(.small)
            }
            .buttonStyle(.bordered)
        }
    }

    private func candidateRow(item: Binding<CandidatePath>) -> some View {
        let rowID = item.id.wrappedValue
        let value = item.wrappedValue
        let url = value.url
        let size = value.size
        return HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: item.selected) { EmptyView() }
                .labelsHidden()
                .accessibilityLabel("Выбрать «\(rowID)»")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: iconName(for: url))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)

                    Text(url.path)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)

                    Spacer(minLength: 8)

                    Text(formatBytes(size))
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }

                // Простая полоска относительного размера
                GeometryReader { geo in
                    let w = max(0, min(1, relativeSize(size)))
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(LinearGradient(colors: [.blue.opacity(0.35), .blue.opacity(0.15)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(w), height: 6, alignment: .leading)
                        .animation(.easeOut(duration: 0.25), value: size)
                        .accessibilityHidden(true)
                }
                .frame(height: 6)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(hoveredRowID == rowID ? Color.primary.opacity(0.06) : Color.primary.opacity(0.03))
        )
        .onHover { inside in
            hoveredRowID = inside ? rowID : (hoveredRowID == rowID ? nil : hoveredRowID)
        }
        .contextMenu {
            Button("Показать в Finder", systemImage: "magnifyingglass") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Button("Скопировать путь", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
        }
    }

    private var footerButtons: some View {
        HStack(spacing: 12) {
            Button("Удалить выбранное", systemImage: "trash") { deleteSelected() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.return)
                .disabled(isWorking || candidates.allSatisfy { !$0.selected })
                .help("Переместить выбранные элементы в Корзину")

            Button("Сброс", systemImage: "arrow.counterclockwise") { reset() }
                .buttonStyle(.bordered)
                .disabled(isWorking)

            Button("Открыть /Applications", systemImage: "folder") { openApplicationsLocal() }
                .buttonStyle(.bordered)
                .controlSize(.small)

            Button("Открыть Корзину", systemImage: "trash") { openTrashLocal() }
                .buttonStyle(.bordered)
                .controlSize(.small)

            Spacer()

            Button("Выбрать .app…", systemImage: "folder") { pickApp() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    private var headerTitle: String {
        if let id = bundleID, !appName.isEmpty { return "\(appName) (\(id))" }
        if !appName.isEmpty { return appName }
        return "Удаление приложения с корнями"
    }

    // MARK: - Drop
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        // Принимаем common-типы: file-url, url, application bundle, package, data
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ||
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) ||
            $0.hasItemConformingToTypeIdentifier(UTType.application.identifier) ||
            $0.hasItemConformingToTypeIdentifier(UTType.package.identifier) ||
            $0.hasItemConformingToTypeIdentifier(UTType.data.identifier)
        }) else {
            return false
        }

        isWorking = true
        status = "Сканирую приложение…"
        candidates.removeAll()

        extractURL(from: provider) { url in
            DispatchQueue.main.async {
                guard let url = url else {
                    self.isWorking = false
                    self.status = "Не удалось получить путь к приложению. Попробуйте кнопкой ‘Выбрать .app…’."
                    return
                }
                self.scan(appURL: self.resolveAppURL(from: url))
            }
        }

        return true
    }

    /// Универсально достаём URL из NSItemProvider разными путями
    private func extractURL(from provider: NSItemProvider, completion: @escaping (URL?) -> Void) {
        // 1) Пробуем напрямую через NSURL
        if provider.canLoadObject(ofClass: NSURL.self) {
            provider.loadObject(ofClass: NSURL.self) { object, _ in
                if let nsurl = object as? NSURL, let url = nsurl as URL? {
                    completion(url)
                    return
                }
                attemptFileURLData()
            }
        } else {
            attemptFileURLData()
        }

        // 2) Пытаемся вытащить строку file://
        func attemptFileURLData() {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                if let data, let str = String(data: data, encoding: .utf8),
                   let url = URL(string: str.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    completion(url)
                } else {
                    attemptURLData()
                }
            }
        }

        // 3) Пытаемся вытащить обычный URL (вдруг пришёл public.url)
        func attemptURLData() {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.url.identifier) { data, _ in
                if let data, let str = String(data: data, encoding: .utf8),
                   let url = URL(string: str.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    completion(url)
                } else {
                    attemptLoadItem()
                }
            }
        }

        // 4) Фолбэк через loadItem (application/package)
        func attemptLoadItem() {
            let typeIDs = [UTType.application.identifier, UTType.package.identifier]
            loadItem(from: typeIDs, index: 0)
        }

        func loadItem(from ids: [String], index: Int) {
            guard index < ids.count else { completion(nil); return }
            provider.loadItem(forTypeIdentifier: ids[index], options: nil) { item, _ in
                if let url = item as? URL {
                    completion(url)
                } else if let nsurl = item as? NSURL, let url = nsurl as URL? {
                    completion(url)
                } else if let data = item as? Data,
                          let str = String(data: data, encoding: .utf8),
                          let url = URL(string: str.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    completion(url)
                } else {
                    loadItem(from: ids, index: index + 1)
                }
            }
        }
    }

    // MARK: - Scan & Delete
    private func scan(appURL: URL) {
        guard appURL.pathExtension.lowercased() == "app" else {
            isWorking = false
            status = "Это не .app. Перетащите файл приложения (AppName.app)."
            return
        }

        // Security-scoped доступ (на случай песочницы)
        var stopAccess = false
        if appURL.startAccessingSecurityScopedResource() { stopAccess = true }
        defer { if stopAccess { appURL.stopAccessingSecurityScopedResource() } }

        let bundle = Bundle(url: appURL)
        let id = bundle?.bundleIdentifier
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? appURL.deletingPathExtension().lastPathComponent

        self.bundleID = id
        self.appName  = name

        // Иконка приложения
        self.appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
        self.appIcon?.size = NSSize(width: 28, height: 28)

        // Кандидатные пути
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        var urls: [URL] = []
        func addIfExists(_ url: URL) {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir) { urls.append(url) }
        }

        if let id = id {
            addIfExists(home.appendingPathComponent("Library/Application Support/\(id)", isDirectory: true))
            addIfExists(home.appendingPathComponent("Library/Caches/\(id)", isDirectory: true))
            addIfExists(home.appendingPathComponent("Library/Preferences/\(id).plist", isDirectory: false))
            addIfExists(home.appendingPathComponent("Library/Logs/\(id)", isDirectory: true))
            addIfExists(home.appendingPathComponent("Library/Saved Application State/\(id).savedState", isDirectory: true))
            addIfExists(home.appendingPathComponent("Library/WebKit/\(id)", isDirectory: true))
            addIfExists(home.appendingPathComponent("Library/Containers/\(id)", isDirectory: true))
        }

        // Часто встречающиеся имена по названию приложения
        addIfExists(home.appendingPathComponent("Library/Application Support/\(name)", isDirectory: true))
        addIfExists(home.appendingPathComponent("Library/Logs/\(name)", isDirectory: true))
        addIfExists(home.appendingPathComponent("Library/Caches/\(name)", isDirectory: true))

        // Group Containers — эвристика по подстроке
        let groupsRoot = home.appendingPathComponent("Library/Group Containers", isDirectory: true)
        if let children = try? fm.contentsOfDirectory(at: groupsRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for child in children {
                let lowered = child.lastPathComponent.lowercased()
                if let id = id?.lowercased(), lowered.contains(id) || lowered.contains(name.lowercased()) {
                    urls.append(child)
                }
            }
        }

        // Добавляем сам .app (если он в HOME — тоже удалим)
        urls.append(appURL)

        // Не выходим за пределы HOME, кроме самого .app
        urls = urls.filter { $0.path.hasPrefix(home.path) || $0 == appURL }

        // Подсчёт размеров и формирование списка
        var rows: [CandidatePath] = []
        for u in urls {
            let sz = approximateSize(of: u)
            rows.append(CandidatePath(id: u.path, url: u, size: sz, selected: true))
        }
        rows.sort { $0.size > $1.size }

        candidates = rows
        status = rows.isEmpty ? "Следы приложения не найдены в вашем профиле."
                              : "Отметьте, что удалить, и нажмите «Удалить выбранное»."
        isWorking = false
    }

    private func deleteSelected() {
        guard !candidates.isEmpty else { return }
        isWorking = true
        status = "Перемещаю в Корзину…"

        let fm = FileManager.default
        var removed = 0
        var bytes: Int64 = 0

        for item in candidates where item.selected {
            bytes += item.size
            do {
                try fm.trashItem(at: item.url, resultingItemURL: nil)
                removed += 1
            } catch {
                // игнорируем частные ошибки и идём дальше
            }
        }

        status = "Перемещено в Корзину: \(removed) объектов. Освобождено примерно \(formatBytes(bytes))."
        isWorking = false
    }

    private func reset() {
        appName = ""
        bundleID = nil
        appIcon = nil
        candidates.removeAll()
        status = "Перетащите приложение (.app) сюда для сканирования."
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.title = "Выберите приложение (.app)"
        // Use content types instead of deprecated allowedFileTypes
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            isWorking = true
            status = "Сканирую приложение…"
            candidates.removeAll()
            scan(appURL: resolveAppURL(from: url))
        }
    }

    // MARK: - Утилиты

    private func openApplicationsLocal() {
        let url = URL(fileURLWithPath: "/Applications", isDirectory: true)
        NSWorkspace.shared.open(url)
    }

    private func openTrashLocal() {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash", isDirectory: true)
        NSWorkspace.shared.open(url)
    }
    private func resolveAppURL(from url: URL) -> URL {
        if url.pathExtension.lowercased() == "app" { return url }
        if let vals = try? url.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey]),
           (vals.isAliasFile == true || vals.isSymbolicLink == true),
           let resolved = try? URL(resolvingAliasFileAt: url) {
            return resolved
        }
        return url
    }

    private func approximateSize(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            if let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) {
                return Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
            }
            return 0
        }
        var total: Int64 = 0
        if let en = fm.enumerator(at: url,
                                  includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey],
                                  options: [.skipsHiddenFiles]) {
            for case let f as URL in en {
                if let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]),
                   v.isRegularFile == true {
                    total += Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
                }
            }
        }
        return total
    }

    private var selectedTotal: Int64 {
        candidates.filter { $0.selected }.reduce(0) { $0 + $1.size }
    }

    private var selectedCount: Int {
        candidates.reduce(0) { $0 + ($1.selected ? 1 : 0) }
    }

    private func relativeSize(_ size: Int64) -> Double {
        guard let max = candidates.map(\.size).max(), max > 0 else { return 0 }
        return Double(size) / Double(max)
    }

    private func setSelection(_ value: Bool) {
        for i in candidates.indices {
            candidates[i].selected = value
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = url.path
        if p.hasPrefix(home) {
            let tail = p.dropFirst(home.count)
            return "~" + tail
        }
        return p
    }

    private func iconName(for url: URL) -> String {
        if url.pathExtension.lowercased() == "app" { return "app" }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return "folder"
        }
        return "doc"
    }

    private var backgroundGradientColors: [Color] {
        isTargeted
        ? [Color.blue.opacity(0.25), Color.purple.opacity(0.18)]
        : [Color.primary.opacity(0.04), Color.primary.opacity(0.02)]
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let unit: Double = 1024
        let b = Double(bytes)
        if b < unit { return String(format: "%.0f Б", b) }
        let exp = Int(log(b) / log(unit))
        let units = ["КБ", "МБ", "ГБ", "ТБ", "ПБ"]
        let value = b / pow(unit, Double(exp))
        let suffix = units[min(exp-1, units.count-1)]
        return String(format: "%.2f %@", value, suffix)
    }
}

// MARK: - Animated dashed border
private struct AnimatedDashedBorder: View {
    var isActive: Bool
    var color: Color
    var cornerRadius: CGFloat

    @State private var phase: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(style: StrokeStyle(lineWidth: isActive ? 2 : 1, dash: [6, 3], dashPhase: phase))
            .foregroundStyle(color)
            .onAppear { start() }
            .onChange(of: isActive) { _ in start() }
            .animation(.easeOut(duration: 0.2), value: isActive)
    }

    private func start() {
        // Only animate when active to avoid extra work
        guard isActive else { return }
        withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
            phase = 18 // any positive value makes the dash move
        }
    }
}

#Preview {
    AppDragTarget()
        .frame(width: 560, height: 260)
        .padding()
}
