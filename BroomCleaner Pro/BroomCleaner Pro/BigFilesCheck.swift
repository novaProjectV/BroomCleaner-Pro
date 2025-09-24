import SwiftUI
import Combine
import AppKit

// MARK: - Model
struct BigFileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let size: Int64
    let isPackage: Bool
}

// Lightweight cache for file icons to reduce UI work
fileprivate final class IconCache {
    static let shared = IconCache()
    private let cache = NSCache<NSURL, NSImage>()
    func icon(for url: URL) -> NSImage {
        let key = url as NSURL
        if let img = cache.object(forKey: key) { return img }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(img, forKey: key)
        return img
    }
}

// MARK: - Scanner
@MainActor
final class BigFilesScanner: ObservableObject {
    @Published var results: [BigFileItem] = []
    @Published var isScanning: Bool = false
    @Published var scannedCount: Int = 0
    @Published var progressHint: String = ""

    private var scanTask: Task<Void, Never>? = nil

    func cancel() {
        scanTask?.cancel()
        isScanning = false
        progressHint = "Отменено"
    }

    func start(scopes: [URL], minBytes: Int64, includeHidden: Bool, skipPackages: Bool, excludeLibrary: Bool, ecoMode: Bool) {
        cancel()
        results.removeAll()
        scannedCount = 0
        isScanning = true
        progressHint = "Подготовка…"

        let fm = FileManager.default
        var keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        if !includeHidden { keys.append(.isHiddenKey) }
        if skipPackages { keys.append(.isPackageKey) }

        scanTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            var appended = 0
            var batch: [BigFileItem] = []
            let batchSize = 128
            var scannedLocal = 0

            for scope in scopes {
                if Task.isCancelled { break }

                await MainActor.run { self.progressHint = scope.path }

                // Быстрый скип, если нет доступа
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: scope.path, isDirectory: &isDir), isDir.boolValue else { continue }

                let options: FileManager.DirectoryEnumerationOptions = {
                    var opts: FileManager.DirectoryEnumerationOptions = []
                    if !includeHidden { opts.insert(.skipsHiddenFiles) }
                    if skipPackages { opts.insert(.skipsPackageDescendants) }
                    return opts
                }()

                let enumerator = fm.enumerator(at: scope,
                                               includingPropertiesForKeys: keys,
                                               options: options,
                                               errorHandler: { _, _ in
                                                   // Пропускаем проблемные узлы, но продолжаем
                                                   return true
                                               })

                while let obj = enumerator?.nextObject() as? URL {
                    if Task.isCancelled { break }

                    do {
                        let values = try obj.resourceValues(forKeys: Set(keys))

                        if values.isDirectory == true {
                            // Скипаем ~/Library по желанию
                            if excludeLibrary, obj.path.hasPrefix(NSHomeDirectory() + "/Library") {
                                enumerator?.skipDescendants()
                            }
                            continue
                        }

                        guard values.isRegularFile == true else { continue }
                        if skipPackages, values.isPackage == true { continue }
                        if includeHidden == false, values.isHidden == true { continue }

                        let size = Int64(values.fileSize ?? 0)
                        if size >= minBytes {
                            let item = BigFileItem(url: obj, size: size, isPackage: values.isPackage ?? false)
                            batch.append(item)
                            appended &+= 1
                            if batch.count >= batchSize {
                                let snapshot = batch            // take a local immutable copy
                                await MainActor.run { self.results.append(contentsOf: snapshot) }
                                batch.removeAll(keepingCapacity: true)
                            }
                            // Cooperative scheduling
                            if appended.isMultiple(of: 500) {
                                await Task.yield()
                            } else if ecoMode, appended.isMultiple(of: 200) {
                                try? await Task.sleep(nanoseconds: 2_000_000)
                            }
                        }

                        scannedLocal &+= 1
                        if scannedLocal.isMultiple(of: 200) {
                            let count = scannedLocal
                            await MainActor.run { self.scannedCount = count }
                        }
                    } catch {
                        // Игнорируем ошибки доступа
                        continue
                    }
                }
            }

            let finalBatch = batch
            let finalScanned = scannedLocal
            await MainActor.run {
                if !finalBatch.isEmpty { self.results.append(contentsOf: finalBatch) }
                self.results.sort { $0.size > $1.size }
                self.scannedCount = finalScanned
                self.isScanning = false
                self.progressHint = "Готово: найдено \(self.results.count) файлов"
            }
        }
    }
}

// MARK: - View
struct BigFilesView: View {
    @StateObject private var scanner = BigFilesScanner()

    @State private var minMB: Double = 500 // порог
    @State private var includeHidden = false
    @State private var skipPackages = true
    @State private var excludeLibrary = true
    @State private var ecoMode = true
    @State private var showEcoInfo = false

    @State private var useDesktop = true
    @State private var useDownloads = true
    @State private var useDocuments = false
    @State private var useMovies = true
    @State private var useMusic = false
    @State private var usePictures = false
    @State private var extraScopes: [URL] = []

    @State private var query: String = ""
    @State private var selection = Set<UUID>()
    @State private var deleteStatus: String = ""

    private var thresholdBytes: Int64 { Int64(minMB * 1024 * 1024) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            Divider()
            content
        }
        .animation(.default, value: scanner.isScanning)
        .animation(.default, value: scanner.results)
    }

    // MARK: - Controls
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Label("Минимальный размер", systemImage: "ruler")
                    .foregroundStyle(.secondary)
                Slider(value: $minMB, in: 50...10_000, step: 50) {
                    Text("Размер")
                } minimumValueLabel: {
                    Text("50 МБ").font(.caption)
                } maximumValueLabel: {
                    Text("10 ГБ").font(.caption)
                }
                .frame(maxWidth: 320)
                Text("≥ " + formatBytes(thresholdBytes)).monospacedDigit()
                Spacer()
                if scanner.isScanning {
                    ProgressView("Сканирую…")
                        .controlSize(.small)
                        .padding(.trailing, 6)
                }
                Button(scanner.isScanning ? "Остановить" : "Сканировать", systemImage: scanner.isScanning ? "stop.fill" : "sparkles") {
                    if scanner.isScanning { scanner.cancel() } else { startScan() }
                }
                .buttonStyle(.automatic)
                .keyboardShortcut("b", modifiers: [.command])
                .disabled(scanner.isScanning)
            }

            HStack(spacing: 16) {
                Toggle("Скрытые файлы", isOn: $includeHidden)
                Toggle("Пропускать пакеты (.app, .pkg)", isOn: $skipPackages)
                Toggle("Исключать ~/Library", isOn: $excludeLibrary)
                HStack(spacing: 6) {
                    Toggle("Щадящий режим", isOn: $ecoMode)
                    Button(action: { showEcoInfo.toggle() }) {
                        Image(systemName: "questionmark.circle")
                            .imageScale(.medium)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Щадящий режим снижает нагрузку на систему во время сканирования: вставляет короткие паузы и чаще уступает CPU, из-за чего сканирование идёт чуть медленнее, но интерфейс остаётся плавным.")
                    .popover(isPresented: $showEcoInfo) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: "leaf")
                                    .foregroundStyle(.green)
                                Text("Щадящий режим")
                                    .font(.headline)
                            }
                            Text("Включите, чтобы сделать сканирование менее агрессивным к ресурсам системы.")
                            Text("Что это даёт:")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Вставляет короткие паузы во время обхода файлов", systemImage: "timer")
                                Label("Чаще уступает процессор другим задачам (Task.yield)", systemImage: "cpu")
                                Label("Снижает пиковую нагрузку на диск и CPU", systemImage: "gauge.medium")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            Text("Итог: сканирование может занять немного больше времени, но система остаётся отзывчивой.")
                                .font(.footnote)
                        }
                        .padding(16)
                        .frame(width: 360)
                    }
                }
            }
            .toggleStyle(.switch)

            HStack(spacing: 10) {
                scopeToggle("Рабочий стол", systemImage: "desktopcomputer", binding: $useDesktop)
                scopeToggle("Загрузки", systemImage: "arrow.down.circle", binding: $useDownloads)
                scopeToggle("Документы", systemImage: "doc", binding: $useDocuments)
                scopeToggle("Видео", systemImage: "film", binding: $useMovies)
                scopeToggle("Музыка", systemImage: "music.note", binding: $useMusic)
                scopeToggle("Фото", systemImage: "photo", binding: $usePictures)
                Button("Добавить папку…", systemImage: "folder.badge.plus") { addCustomFolder() }
                    .buttonStyle(.automatic)
                    .help("Добавить произвольную папку в область сканирования")
            }

            HStack(spacing: 12) {
                Button("Удалить выбранные", systemImage: "trash") { deleteSelected() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(selection.isEmpty || scanner.isScanning)
                    .help("Переместить выбранные файлы в Корзину")

                Button("Выбрать все") { selection = Set(scanner.results.map { $0.id }) }
                    .buttonStyle(.bordered)
                    .disabled(scanner.results.isEmpty)

                Button("Снять выбор") { selection.removeAll() }
                    .buttonStyle(.bordered)
                    .disabled(selection.isEmpty)

                Spacer()

                // Summary of selected
                let bytes = selectedBytes(scanner.results)
                if !scanner.results.isEmpty {
                    Text("Выбрано: \(selection.count) • \(formatBytes(bytes))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if !extraScopes.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(extraScopes, id: \.self) { url in
                            HStack(spacing: 6) {
                                Image(systemName: "folder")
                                Text(url.lastPathComponent)
                                Button(role: .destructive) { removeExtra(url) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                        }
                    }
                }
            }

            HStack { Image(systemName: "magnifyingglass"); TextField("Фильтр по имени или пути", text: $query) }
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Content
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            if scanner.results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: scanner.isScanning ? "hourglass" : "internaldrive")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(scanner.isScanning ? "Идёт сканирование…" : "Здесь появятся самые тяжёлые файлы")
                        .foregroundStyle(.secondary)
                    if !scanner.progressHint.isEmpty { Text(scanner.progressHint).font(.caption).foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                let items = filtered(scanner.results)
                Table(items, selection: $selection) {
                    TableColumn("") { item in
                        Toggle(isOn: Binding(
                            get: { selection.contains(item.id) },
                            set: { v in if v { selection.insert(item.id) } else { selection.remove(item.id) } }
                        )) { EmptyView() }
                        .labelsHidden()
                    }
                    .width(28)

                    TableColumn("Имя") { item in
                        HStack(spacing: 8) {
                            Image(nsImage: IconCache.shared.icon(for: item.url))
                                .resizable().frame(width: 16, height: 16)
                                .cornerRadius(3)
                            Text(item.url.lastPathComponent)
                                .lineLimit(1)
                        }
                    }
                    TableColumn("Путь") { item in
                        Text(item.url.deletingLastPathComponent().path)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    TableColumn("Размер") { item in
                        Text(formatBytes(item.size)).monospacedDigit()
                    }
                }
            }
            if !deleteStatus.isEmpty {
                Text(deleteStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers
    private func filtered(_ items: [BigFileItem]) -> [BigFileItem] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return items }
        let q = query.lowercased()
        return items.filter {
            let name = $0.url.lastPathComponent.lowercased()
            let path = $0.url.path.lowercased()
            return name.contains(q) || path.contains(q)
        }
    }

    private func scopeToggle(_ title: String, systemImage: String, binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Label(title, systemImage: systemImage)
        }
        .toggleStyle(.checkbox)
    }

    private func startScan() {
        var scopes: [URL] = []
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        func dir(_ name: String) -> URL { home.appendingPathComponent(name, isDirectory: true) }
        if useDesktop    { scopes.append(dir("Desktop")) }
        if useDownloads  { scopes.append(dir("Downloads")) }
        if useDocuments  { scopes.append(dir("Documents")) }
        if useMovies     { scopes.append(dir("Movies")) }
        if useMusic      { scopes.append(dir("Music")) }
        if usePictures   { scopes.append(dir("Pictures")) }
        scopes.append(contentsOf: extraScopes)
        if scopes.isEmpty { scopes = [home] }

        scanner.start(scopes: scopes,
                      minBytes: thresholdBytes,
                      includeHidden: includeHidden,
                      skipPackages: skipPackages,
                      excludeLibrary: excludeLibrary,
                      ecoMode: ecoMode)
    }

    private func addCustomFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.title = "Добавьте папки для сканирования"
        if p.runModal() == .OK {
            for url in p.urls { if !extraScopes.contains(url) { extraScopes.append(url) } }
        }
    }

    private func removeExtra(_ url: URL) { extraScopes.removeAll { $0 == url } }

    private func selectedBytes(_ items: [BigFileItem]) -> Int64 {
        items.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    private func deleteSelected() {
        guard !selection.isEmpty else { return }
        let fm = FileManager.default
        var removed = 0
        var bytes: Int64 = 0

        let ids = selection
        var remaining: [BigFileItem] = []
        for item in scanner.results {
            if ids.contains(item.id) {
                do {
                    var trashedURL: NSURL?
                    try fm.trashItem(at: item.url, resultingItemURL: &trashedURL)
                    removed += 1
                    bytes += item.size
                } catch {
                    // ignore individual errors and keep item in remaining
                    remaining.append(item)
                }
            } else {
                remaining.append(item)
            }
        }

        scanner.results = remaining
        selection.removeAll()
        deleteStatus = removed > 0
            ? "Перемещено в Корзину: \(removed) файлов. Освобождено \(formatBytes(bytes))."
            : "Не удалось переместить выбранные файлы."
    }
}

// MARK: - Formatting
fileprivate func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
