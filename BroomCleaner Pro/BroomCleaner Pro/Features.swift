import SwiftUI

// MARK: - Preferences: Exclusions (Whitelist) and Custom Keep Days

public enum CleanPrefs {
    private static let exclusionsKey = "exclusions.rules.v1"
    private static let keepDaysKey = "customKeepDays"

    /// Custom keep-days for user-defined risk level. Non-negative.
    public static var customKeepDays: Int {
        get { max(0, UserDefaults.standard.integer(forKey: keepDaysKey)) }
        set { UserDefaults.standard.set(max(0, newValue), forKey: keepDaysKey) }
    }

    /// Load saved exclusion rules from UserDefaults (JSON-encoded)
    public static func loadExclusions() -> [ExclusionRule] {
        guard let data = UserDefaults.standard.data(forKey: exclusionsKey) else { return [] }
        return (try? JSONDecoder().decode([ExclusionRule].self, from: data)) ?? []
    }

    /// Save exclusion rules to UserDefaults (JSON-encoded)
    public static func saveExclusions(_ rules: [ExclusionRule]) {
        let data = try? JSONEncoder().encode(rules)
        UserDefaults.standard.set(data, forKey: exclusionsKey)
    }
}

/// What to exclude from cleaning. Designed to be simple and fast to check.
public struct ExclusionRule: Identifiable, Codable, Hashable {
    public enum Kind: String, Codable, CaseIterable {
        case exactPath      // Exact path match
        case pathPrefix     // Any path that starts with this prefix
        case bundleID       // Bundle identifier (for app-specific content)
        case glob           // Simple glob with '*' wildcard
    }

    public let id: UUID
    public var kind: Kind
    public var value: String

    public init(id: UUID = UUID(), kind: Kind, value: String) {
        self.id = id
        self.kind = kind
        self.value = value
    }
}

public enum ExclusionsMatcher {
    /// Returns true if url or bundleID matches any saved exclusion rule.
    public static func shouldExclude(url: URL, bundleID: String? = nil) -> Bool {
        let rules = CleanPrefs.loadExclusions()
        let path = url.path
        for r in rules {
            switch r.kind {
            case .exactPath:
                if path == r.value { return true }
            case .pathPrefix:
                if path.hasPrefix(r.value) { return true }
            case .bundleID:
                if let bid = bundleID, bid == r.value { return true }
            case .glob:
                if matchesGlob(path, pattern: r.value) { return true }
            }
        }
        return false
    }

    /// Very small glob matcher supporting '*' wildcard only.
    private static func matchesGlob(_ text: String, pattern: String) -> Bool {
        // Quick path: no wildcard → exact
        guard pattern.contains("*") else { return text == pattern }
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var idx = text.startIndex
        var first = true
        for p in parts {
            if p.isEmpty { first = false; continue }
            if first {
                guard text.hasPrefix(p) else { return false }
                idx = text.index(idx, offsetBy: p.count)
                first = false
            } else if let range = text[idx...].range(of: p) {
                idx = range.upperBound
            } else {
                return false
            }
        }
        // If pattern ends with '*' it's OK, otherwise ensure we've consumed the tail
        if pattern.hasSuffix("*") { return true }
        return idx == text.endIndex
    }
}

// MARK: - Cleaning Metrics (history, monthly totals, series)
public enum CleanMetrics {
    public enum Kind: String, Codable, CaseIterable { case smart, cache, logs, uninstall, big, browsers }

    public struct Event: Codable, Identifiable {
        public let id: UUID
        public let date: Date
        public let bytes: Int64
        public let kind: Kind
        public let source: String? // bundle id or folder label
        public init(id: UUID = UUID(), date: Date = Date(), bytes: Int64, kind: Kind, source: String? = nil) {
            self.id = id; self.date = date; self.bytes = bytes; self.kind = kind; self.source = source
        }
    }

    private static let key = "clean.metrics.events.v1"
    private static let maxEvents = 2000

    public static func log(bytes: Int64, kind: Kind, source: String? = nil) {
        guard bytes > 0 else { return }
        var arr = load()
        arr.append(Event(bytes: bytes, kind: kind, source: source))
        if arr.count > maxEvents { arr.removeFirst(arr.count - maxEvents) }
        save(arr)
    }

    public static func monthTotal(kind: Kind? = nil, now: Date = Date()) -> Int64 {
        let cal = Calendar.current
        let comp = cal.dateComponents([.year, .month], from: now)
        guard let start = cal.date(from: comp), let end = cal.date(byAdding: .month, value: 1, to: start) else { return 0 }
        return load().filter { (kind == nil || $0.kind == kind!) && $0.date >= start && $0.date < end }.reduce(0) { $0 + $1.bytes }
    }

    /// Daily totals for the last `days` days (default 30). Returns array aligned oldest→newest.
    public static func seriesLastDays(days: Int = 30, kind: Kind? = nil, now: Date = Date()) -> [Int64] {
        let cal = Calendar.current
        let start = cal.startOfDay(for: cal.date(byAdding: .day, value: -days + 1, to: now) ?? now)
        var buckets: [Date: Int64] = [:]
        for i in 0..<days { if let d = cal.date(byAdding: .day, value: i, to: start) { buckets[d] = 0 } }
        for e in load() where kind == nil || e.kind == kind! {
            let d = cal.startOfDay(for: e.date)
            if d >= start, let v = buckets[d] { buckets[d] = v + e.bytes }
        }
        let sorted = buckets.keys.sorted()
        return sorted.map { buckets[$0] ?? 0 }
    }

    /// Top sources (bundle IDs) for given kinds within current month.
    public static func topSources(kinds: [Kind], limit: Int = 6, now: Date = Date()) -> [(String, Int64)] {
        let cal = Calendar.current
        let comp = cal.dateComponents([.year, .month], from: now)
        guard let start = cal.date(from: comp), let end = cal.date(byAdding: .month, value: 1, to: start) else { return [] }
        var agg: [String: Int64] = [:]
        for e in load() where kinds.contains(e.kind) && e.date >= start && e.date < end {
            let key = e.source ?? "Другое"
            agg[key, default: 0] &+= e.bytes
        }
        let sorted = agg.sorted { $0.value > $1.value }
        let top = Array(sorted.prefix(limit))
        let others = sorted.dropFirst(limit).reduce(Int64(0)) { $0 + $1.value }
        if others > 0 { return top + [("Прочее", others)] }
        return top
    }

    // Storage
    private static func load() -> [Event] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Event].self, from: data)) ?? []
    }
    private static func save(_ arr: [Event]) {
        let data = try? JSONEncoder().encode(arr)
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - Древовидный предпросмотр: App → Kind → Path

/// Универсальный узел предпросмотра. Можно собирать дерево любого уровня (App → Kind → Path).
public struct PreviewNode: Identifiable, Hashable {
    public let id: UUID
    public var title: String           // Отображаемое имя (App / Kind / Путь)
    public var detail: String?         // Доп. подпись (например, Bundle ID или подпояснение)
    public var size: Int64             // Размер собственного узла (для папок можно 0 — сумма считается из детей)
    public var selected: Bool          // Чекбокс: выбран к удалению
    public var children: [PreviewNode]?  // Дочерние узлы (nil — лист)

    public init(id: UUID = UUID(), title: String, detail: String? = nil, size: Int64 = 0, selected: Bool = true, children: [PreviewNode]? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.size = size
        self.selected = selected
        self.children = children
    }

    /// Рекурсивная сумма размеров по всему поддереву
    public var totalSize: Int64 {
        let own = size
        guard let children else { return own }
        return children.reduce(own) { $0 + $1.totalSize }
    }
}

/// Вью для Outline‑предпросмотра с чекбоксами и размерами.
/// Передавай массив узлов верхнего уровня (обычно 1 «App» узел или несколько, если удаляем несколько приложений).
public struct TreePreviewView: View {
    @Binding var nodes: [PreviewNode]

    public init(nodes: Binding<[PreviewNode]>) { self._nodes = nodes }

    public var body: some View {
        OutlineGroup(nodes, children: \.children) { node in
            // Получаем биндинг к конкретному узлу по его id, чтобы чекбокс менял состояние в общем дереве
            let binding = binding(for: node)
            TreePreviewRow(node: binding)
        }
    }

    // MARK: - Поиск и биндинг по id внутри дерева
    private func binding(for node: PreviewNode) -> Binding<PreviewNode> {
        Binding<PreviewNode>(
            get: { findNode(in: nodes, id: node.id) ?? node },
            set: { newValue in updateNode(in: &nodes, newValue) }
        )
    }

    private func findNode(in list: [PreviewNode], id: UUID) -> PreviewNode? {
        for n in list {
            if n.id == id { return n }
            if let c = n.children, let found = findNode(in: c, id: id) { return found }
        }
        return nil
    }

    private func updateNode(in list: inout [PreviewNode], _ newValue: PreviewNode) {
        for i in list.indices {
            if list[i].id == newValue.id {
                list[i] = newValue
                return
            }
            if list[i].children != nil {
                updateNode(in: &list[i].children!, newValue)
            }
        }
    }
}

/// Одна строка дерева с чекбоксом, заголовком и размером. Клик по чекбоксу рекурсивно переключает всех детей.
fileprivate struct TreePreviewRow: View {
    @Binding var node: PreviewNode
    @State private var isExpanded: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            // Чекбокс
            Toggle(isOn: Binding<Bool>(
                get: { node.selected },
                set: { newValue in
                    node.selected = newValue
                    // Рекурсивно применяем выбор к дочерним узлам
                    if var children = node.children {
                        setSelection(&children, newValue)
                        node.children = children
                    }
                }
            )) { EmptyView() }
            .labelsHidden()

            // Название
            VStack(alignment: .leading, spacing: 2) {
                Text(node.title)
                    .font(.body)
                if let detail = node.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            // Размер справа
            Text(FeaturesFormat.formatBytes(node.totalSize))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    private func setSelection(_ nodes: inout [PreviewNode], _ value: Bool) {
        for i in nodes.indices {
            nodes[i].selected = value
            if nodes[i].children != nil {
                setSelection(&nodes[i].children!, value)
            }
        }
    }
}

// MARK: - «Умная прогресс‑кнопка» (кольцо, ETA, пружинка на финише)

public enum SmartButtonState: Equatable {
    case idle(title: String)
    case running(progress: Double, eta: TimeInterval)  // 0...1, ETA в секундах
    case success(bytes: Int64, files: Int, duration: TimeInterval)
}

public struct SmartProgressButton: View {
    @Binding var state: SmartButtonState
    var action: () -> Void

    @State private var hovering = false
    @State private var pressing = false

    public init(state: Binding<SmartButtonState>, action: @escaping () -> Void) {
        self._state = state
        self.action = action
    }

    public var body: some View {
        Button(action: handleTap) {
            ZStack {
                switch state {
                case .idle(let title):
                    Text(title)
                        .font(.headline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .transition(.opacity)

                case .running(let progress, let eta):
                    HStack(spacing: 12) {
                        ProgressRing(progress: progress)
                            .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Идёт очистка…")
                                .font(.headline)
                            Text("ETA: \(FeaturesFormat.formatETA(eta))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .transition(.opacity)

                case .success(let bytes, let files, let duration):
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("−\(FeaturesFormat.formatBytes(bytes)) • \(files) файлов • \(FeaturesFormat.formatETA(duration))")
                            .font(.headline)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(minWidth: 220)
            .background(background)
            .overlay(border)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(radius: hovering ? 10 : 6)
            .scaleEffect(pressing ? 0.98 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.85, blendDuration: 0.1), value: pressing)
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pressAction { isPressed in pressing = isPressed }
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityText)
    }

    private var isDisabled: Bool {
        if case .running = state { return true }
        return false
    }

    private var background: some View {
        Group {
            if #available(macOS 26.0, *) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.thinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white.opacity(hovering ? 0.06 : 0.04))
                    )
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            }
        }
    }

    private var border: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(Color.white.opacity(0.10), lineWidth: 1)
    }

    private var accessibilityText: String {
        switch state {
        case .idle(let title): return title
        case .running: return "Идёт очистка"
        case .success(let bytes, let files, let duration):
            return "Освобождено \(FeaturesFormat.formatBytes(bytes)), файлов: \(files), за \(FeaturesFormat.formatETA(duration))"
        }
    }

    private func handleTap() {
        switch state {
        case .idle:
            pressing = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { pressing = false }
            action()
        default:
            break
        }
    }
}

/// Кольцевой индикатор прогресса без внешних зависимостей.
fileprivate struct ProgressRing: View {
    var progress: Double // 0...1

    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: 1)
                .stroke(Color.primary.opacity(0.15), lineWidth: 4)
                .rotationEffect(.degrees(-90))
            Circle().trim(from: 0, to: max(0.01, min(1.0, progress)))
                .stroke(AngularGradient(gradient: Gradient(colors: [
                    Color.accentColor.opacity(0.9),
                    Color.accentColor.opacity(0.6)
                ]), center: .center), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.25), value: progress)
        }
    }
}

// MARK: - Утилиты форматирования и жесты
fileprivate enum FeaturesFormat {
    static func formatBytes(_ bytes: Int64) -> String {
        let unit: Double = 1024
        let b = Double(bytes)
        if b < unit { return String(format: "%.0f Б", b) }
        let exp = Int(log(b) / log(unit))
        let units = ["КБ", "МБ", "ГБ", "ТБ", "ПБ"]
        let value = b / pow(unit, Double(exp))
        let suffix = units[min(exp-1, units.count-1)]
        return String(format: "%.2f %@", value, suffix)
    }

    static func formatETA(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }
}

fileprivate struct PressActionModifier: ViewModifier {
    let onChanged: (Bool) -> Void
    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in onChanged(true) }
                    .onEnded { _ in onChanged(false) }
            )
    }
}

fileprivate extension View {
    func pressAction(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(PressActionModifier(onChanged: action))
    }
}

// MARK: - Exclusions quick preview
#Preview("Exclusions Match") {
    VStack(alignment: .leading, spacing: 8) {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Downloads/test.dmg")
        let rules = [
            ExclusionRule(kind: .pathPrefix, value: NSHomeDirectory() + "/Downloads"),
            ExclusionRule(kind: .glob, value: "*/Caches/*"),
            ExclusionRule(kind: .bundleID, value: "com.example.app")
        ]
        Text("Should exclude Downloads/test.dmg → \(ExclusionsMatcher.shouldExclude(url: url) ? "YES" : "NO")")
            .font(.footnote)
            .onAppear { CleanPrefs.saveExclusions(rules) }
    }
    .padding()
}

// MARK: - Превью
#Preview("Tree + Smart Button") {
    StatefulPreview()
        .frame(width: 560, height: 420)
        .padding()
}

fileprivate struct StatefulPreview: View {
    @State var nodes: [PreviewNode] = [
        PreviewNode(title: "MyApp.app", detail: "com.example.myapp", children: [
            PreviewNode(title: "Caches", size: 0, children: [
                PreviewNode(title: "~/Library/Caches/com.example.myapp", size: 420_000_000),
                PreviewNode(title: "~/Library/Group Containers/…/Library/Caches", size: 180_000_000)
            ]),
            PreviewNode(title: "Logs", size: 0, children: [
                PreviewNode(title: "~/Library/Logs/com.example.myapp", size: 30_000_000)
            ]),
            PreviewNode(title: "Application Support", size: 0, children: [
                PreviewNode(title: "~/Library/Application Support/com.example.myapp", size: 2_100_000_000)
            ])
        ])
    ]

    @State var buttonState: SmartButtonState = .idle(title: "Очистить выбранное")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TreePreviewView(nodes: $nodes)
                .frame(minHeight: 220)

            SmartProgressButton(state: $buttonState) {
                // Демка: идём от 0 до 100% с ETA
                simulateRun()
            }
        }
    }

    func simulateRun() {
        var p: Double = 0
        let total: TimeInterval = 6
        let step: TimeInterval = 0.1
        var elapsed: TimeInterval = 0
        buttonState = .running(progress: 0, eta: total)
        Timer.scheduledTimer(withTimeInterval: step, repeats: true) { t in
            elapsed += step
            p = min(1.0, elapsed / total)
            buttonState = .running(progress: p, eta: max(0, total - elapsed))
            if p >= 1.0 {
                t.invalidate()
                let bytes = nodes.filter { $0.selected }.reduce(0) { $0 + $1.totalSize }
                let files = Int.random(in: 500...1800)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    buttonState = .success(bytes: bytes, files: files, duration: total)
                }
                // Автовозврат к idle по желанию:
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                    buttonState = .idle(title: "Очистить выбранное")
                }
            }
        }
    }
}

