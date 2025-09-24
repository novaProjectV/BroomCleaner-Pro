import SwiftUI
import Foundation
import CryptoKit

// MARK: - Model
struct DuplicateGroup: Identifiable, Hashable {
    let id = UUID()
    let files: [URL]
    let sizePerFile: Int64
    var reclaimableBytes: Int64 { max(0, Int64(files.count - 1)) * sizePerFile }
}

// MARK: - Finder
struct DuplicateFinder {
    // Scan roots for duplicate files. Strategy: bucket by size -> partial hash -> full hash.
    func scan(in roots: [URL], includeHidden: Bool, skipPackages: Bool = true) async -> [DuplicateGroup] {
        let fm = FileManager.default
        var sizeBuckets: [Int64: [URL]] = [:]

        // 1) Enumerate files and bucket by size
        for root in roots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if skipPackages, let vals = try? root.resourceValues(forKeys: [.isPackageKey]), vals.isPackage == true {
                    continue
                }
                var opts: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
                if skipPackages { opts.insert(.skipsPackageDescendants) }
                let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
                if let en = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: opts) {
                    while let obj = en.nextObject() as? URL {
                        let url = obj
                        if let vals = try? url.resourceValues(forKeys: Set(keys)), vals.isRegularFile == true {
                            let size = Int64(vals.fileSize ?? 0)
                            guard size > 0 else { continue }
                            sizeBuckets[size, default: []].append(url)
                        }
                    }
                }
            } else {
                if let vals = try? root.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), vals.isRegularFile == true, let s = vals.fileSize, s > 0 {
                    sizeBuckets[Int64(s), default: []].append(root)
                }
            }
        }

        // 2) For each size bucket with 2+ files, compute partial hash (first 128KB)
        var partialBuckets: [String: [URL]] = [:]
        let partialChunk = 128 * 1024
        for (size, urls) in sizeBuckets where urls.count >= 2 {
            for url in urls {
                if let data = try? readPrefix(of: url, length: partialChunk) {
                    let digest = Insecure.MD5.hash(data: data)
                    let key = "\(size)-\(Data(digest).base64EncodedString())"
                    partialBuckets[key, default: []].append(url)
                }
            }
        }

        // 3) For each partial bucket, compute full hash to confirm duplicates
        var groups: [DuplicateGroup] = []
        for (key, urls) in partialBuckets where urls.count >= 2 {
            // Extract size from key
            let comps = key.split(separator: "-")
            let size: Int64 = comps.first.flatMap { Int64($0) } ?? 0
            var fullBuckets: [String: [URL]] = [:]
            for url in urls {
                if let h = try? fullHash(of: url) {
                    fullBuckets[h, default: []].append(url)
                }
            }
            for (_, dupeURLs) in fullBuckets where dupeURLs.count >= 2 {
                groups.append(DuplicateGroup(files: dupeURLs, sizePerFile: size))
            }
        }

        // Sort groups by potential savings desc
        groups.sort { $0.reclaimableBytes > $1.reclaimableBytes }
        return groups
    }

    // MARK: Helpers
    private func readPrefix(of url: URL, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: length) ?? Data()
    }

    private func fullHash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return Data(digest).base64EncodedString()
    }

    static func trash(_ urls: [URL]) -> (removed: Int, failed: Int) {
        var removed = 0
        var failed = 0
        let fm = FileManager.default
        for url in urls {
            do {
                var trashed: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &trashed)
                removed += 1
            } catch {
                failed += 1
            }
        }
        return (removed, failed)
    }
}

// MARK: - UI
struct DuplicatesView: View {
    @State private var includeHidden: Bool = false
    @State private var skipPackages: Bool = true
    @State private var isScanning: Bool = false
    @State private var groups: [DuplicateGroup] = []
    @State private var selection: [UUID: Set<URL>] = [:]
    @State private var status: String = ""

    var roots: [URL]

    init(roots: [URL] = []) {
        if roots.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.roots = [home.appendingPathComponent("Downloads", isDirectory: true)]
        } else {
            self.roots = roots
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Поиск дубликатов файлов").font(.title3.bold())
                Spacer()
                Toggle("Скрытые", isOn: $includeHidden).toggleStyle(.checkbox)
                Toggle("Пропускать пакеты (.app/.bundle)", isOn: $skipPackages).toggleStyle(.checkbox)
                Button(action: { Task { await runScan() } }) {
                    Label(isScanning ? "Сканирую…" : "Сканировать", systemImage: "magnifyingglass")
                }
                .disabled(isScanning)
            }

            if isScanning {
                ProgressView().padding(.vertical, 6)
            }

            if groups.isEmpty && !isScanning {
                Text("Нет групп дубликатов. Выберите другие папки или попробуйте позже.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            if !isScanning {
                Text("Удаление выполняется через Корзину. В каждой группе по умолчанию сохраняется один файл.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            List {
                ForEach(groups) { group in
                    Section(header: groupHeader(group)) {
                        let files = group.files
                        ForEach(files, id: \.self) { url in
                            HStack {
                                Toggle(isOn: Binding(get: {
                                    selection[group.id, default: defaultSelection(for: group)].contains(url)
                                }, set: { newVal in
                                    var set = selection[group.id] ?? defaultSelection(for: group)
                                    if newVal { set.insert(url) } else { set.remove(url) }
                                    selection[group.id] = set
                                })) {
                                    Text(url.path)
                                        .lineLimit(2)
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
            }

            HStack {
                let total = totalReclaimable()
                Text("Можно освободить: \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) { removeSelected() } label: {
                    Label("Удалить выбранные", systemImage: "trash")
                }
                .disabled(total == 0)
            }

            if !status.isEmpty {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .onAppear { Task { await runScan() } }
    }

    private func groupHeader(_ group: DuplicateGroup) -> some View {
        HStack {
            Text("Группа (\(group.files.count))")
                .font(.headline)
            Spacer()
            Text("Размер файла: \(ByteCountFormatter.string(fromByteCount: group.sizePerFile, countStyle: .file))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func defaultSelection(for group: DuplicateGroup) -> Set<URL> {
        // По умолчанию оставляем первый файл, остальные выбираем на удаление
        Set(group.files.dropFirst())
    }

    private func totalReclaimable() -> Int64 {
        groups.reduce(0) { acc, g in
            let selected = selection[g.id] ?? defaultSelection(for: g)
            return acc + Int64(selected.count) * g.sizePerFile
        }
    }

    private func removeSelected() {
        var toTrash: [URL] = []
        for g in groups {
            let sel = selection[g.id] ?? defaultSelection(for: g)
            toTrash.append(contentsOf: sel)
        }
        let res = DuplicateFinder.trash(toTrash)
        status = "Удалено: \(res.removed), не удалось: \(res.failed)."
        // Удаляем из групп
        groups = groups.map { g in
            let sel = selection[g.id] ?? defaultSelection(for: g)
            let remain = g.files.filter { !sel.contains($0) }
            return DuplicateGroup(files: remain, sizePerFile: g.sizePerFile)
        }.filter { $0.files.count > 1 }
        selection.removeAll()
    }

    private func runScan() async {
        isScanning = true
        status = ""
        let finder = DuplicateFinder()
        let found = await finder.scan(in: roots, includeHidden: includeHidden, skipPackages: skipPackages)
        groups = found
        selection = Dictionary(uniqueKeysWithValues: found.map { ($0.id, defaultSelection(for: $0)) })
        isScanning = false
    }
}

#Preview("Duplicates") {
    DuplicatesView()
}


// MARK: - CleaningCore: Browser caches cleaner
extension CleaningCore {
    /// Clean caches for popular browsers (Safari, Chrome, Edge, Firefox).
    /// - Parameters:
    ///   - includeHidden: include hidden files while enumerating cache folders
    ///   - riskMode: respects keepDays (skip recently modified files)
    ///   - aggressive: if true, additionally clears Code Cache / GPUCache / Service Worker caches where applicable
    /// - Returns: aggregated CleanResult
    static func cleanBrowserCaches(includeHidden: Bool, riskMode: RiskMode, aggressive: Bool = false) -> CleanResult {
        var result = CleanResult()
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let keepDays = max(riskMode.keepDays, CleanPrefs.customKeepDays)
        let cutoff: Date? = keepDays > 0 ? Calendar.current.date(byAdding: .day, value: -keepDays, to: Date()) : nil

        // Helper: size approximation (files + directories)
        func approximateSize(_ url: URL) -> Int64 {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
            if !isDir.boolValue {
                if let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) {
                    return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                }
                return 0
            }
            var total: Int64 = 0
            var opts: FileManager.DirectoryEnumerationOptions = []
            if !includeHidden { opts.insert(.skipsHiddenFiles) }
            if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey], options: opts) {
                while let obj = en.nextObject() as? URL {
                    if let values = try? obj.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]), values.isRegularFile == true {
                        total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                    }
                }
            }
            return total
        }

        // Helper: trash children of directory with filters
        func trashChildren(of dir: URL) -> CleanResult {
            var r = CleanResult()
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return r }
            let opts: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: opts) else { return r }
            for item in items {
                if let cutoff {
                    if let v = try? item.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]) {
                        if v.isDirectory != true, let m = v.contentModificationDate, m > cutoff {
                            continue
                        }
                    }
                }
                let sz = approximateSize(item)
                do {
                    var trashedURL: NSURL?
                    try fm.trashItem(at: item, resultingItemURL: &trashedURL)
                    r.items += 1
                    r.bytes += sz
                    if let t = trashedURL as URL? {
                        r.trashed.append(.init(originalPath: item.path, trashedPath: t.path))
                    }
                } catch {
                    r.failed += 1
                }
            }
            return r
        }

        // Safari
        let safariCaches = [
            home.appendingPathComponent("Library/Caches/com.apple.Safari", isDirectory: true),
            home.appendingPathComponent("Library/Caches/com.apple.WebKit.Networking", isDirectory: true),
            home.appendingPathComponent("Library/Caches/com.apple.WebKit.WebContent", isDirectory: true)
        ]
        for dir in safariCaches { result.add(trashChildren(of: dir)) }

        // Chrome (all profiles)
        let chromeSupport = home.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
        let chromeCaches = home.appendingPathComponent("Library/Caches/Google/Chrome", isDirectory: true)
        result.add(trashChildren(of: chromeCaches))
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: chromeSupport.path, isDirectory: &isDir), isDir.boolValue {
            if let profiles = try? fm.contentsOfDirectory(at: chromeSupport, includingPropertiesForKeys: nil, options: includeHidden ? [] : [.skipsHiddenFiles]) {
                for p in profiles where (try? p.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let targets = [
                        p.appendingPathComponent("Cache", isDirectory: true),
                        p.appendingPathComponent("Code Cache", isDirectory: true),
                        p.appendingPathComponent("GPUCache", isDirectory: true),
                        aggressive ? p.appendingPathComponent("Service Worker/CacheStorage", isDirectory: true) : nil
                    ].compactMap { $0 }
                    for t in targets { result.add(trashChildren(of: t)) }
                }
            }
        }

        // Microsoft Edge (all profiles)
        let edgeSupport = home.appendingPathComponent("Library/Application Support/Microsoft Edge", isDirectory: true)
        let edgeCaches = home.appendingPathComponent("Library/Caches/Microsoft Edge", isDirectory: true)
        result.add(trashChildren(of: edgeCaches))
        isDir = false
        if fm.fileExists(atPath: edgeSupport.path, isDirectory: &isDir), isDir.boolValue {
            if let profiles = try? fm.contentsOfDirectory(at: edgeSupport, includingPropertiesForKeys: nil, options: includeHidden ? [] : [.skipsHiddenFiles]) {
                for p in profiles where (try? p.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let targets = [
                        p.appendingPathComponent("Cache", isDirectory: true),
                        p.appendingPathComponent("Code Cache", isDirectory: true),
                        p.appendingPathComponent("GPUCache", isDirectory: true),
                        aggressive ? p.appendingPathComponent("Service Worker/CacheStorage", isDirectory: true) : nil
                    ].compactMap { $0 }
                    for t in targets { result.add(trashChildren(of: t)) }
                }
            }
        }

        // Firefox (all profiles)
        let firefoxCaches = home.appendingPathComponent("Library/Caches/Firefox", isDirectory: true)
        result.add(trashChildren(of: firefoxCaches))
        let firefoxProfiles = home.appendingPathComponent("Library/Application Support/Firefox/Profiles", isDirectory: true)
        isDir = false
        if fm.fileExists(atPath: firefoxProfiles.path, isDirectory: &isDir), isDir.boolValue {
            if let profiles = try? fm.contentsOfDirectory(at: firefoxProfiles, includingPropertiesForKeys: nil, options: includeHidden ? [] : [.skipsHiddenFiles]) {
                for p in profiles where (try? p.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let cache2 = p.appendingPathComponent("cache2", isDirectory: true)
                    result.add(trashChildren(of: cache2))
                }
            }
        }

        return result
    }
}

