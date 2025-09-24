import SwiftUI

/// Окно настроек приложения (⌘ + ,)
struct SettingsView: View {
    @AppStorage("accentColor") private var accentColorRaw: String = "blue"
    @AppStorage("riskMode") private var riskModeRaw: String = RiskMode.safe.rawValue
    @AppStorage("includeHidden") private var includeHidden: Bool = false

    @State private var customKeepDays: Int = CleanPrefs.customKeepDays
    @State private var rules: [ExclusionRule] = CleanPrefs.loadExclusions()
    @State private var newRuleKind: ExclusionRule.Kind = .pathPrefix
    @State private var newRuleValue: String = ""

    private var accentPalette: [String] { ["blue", "purple", "pink", "orange", "green", "teal"] }

    private func color(from name: String) -> Color {
        switch name {
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "orange": return .orange
        case "green": return .green
        case "teal": return .teal
        default: return .accentColor
        }
    }

    private func localizedName(for name: String) -> String {
        switch name {
        case "blue": return "Синий"
        case "purple": return "Фиолетовый"
        case "pink": return "Розовый"
        case "orange": return "Оранжевый"
        case "green": return "Зелёный"
        case "teal": return "Бирюзовый"
        default: return name
        }
    }

    private var riskMode: RiskMode { RiskMode(rawValue: riskModeRaw) ?? .safe }

    var body: some View {
        Form {
            Section(header: Text("Акцентный цвет")) {
                HStack(spacing: 12) {
                    ForEach(accentPalette, id: \.self) { name in
                        let c = color(from: name)
                        Button {
                            accentColorRaw = name
                        } label: {
                            Circle()
                                .fill(c)
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: accentColorRaw == name ? 3 : 1)
                                )
                                .shadow(radius: accentColorRaw == name ? 4 : 0)
                        }
                        .buttonStyle(.plain)
                        .help(localizedName(for: name))
                    }
                }
            }

            Section(header: Text("Режим очистки")) {
                Picker("Режим", selection: $riskModeRaw) {
                    ForEach(RiskMode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text(riskMode.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(header: Text("Давность файлов")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Не трогать последние")
                        Stepper(value: $customKeepDays, in: 0...365) {
                            Text("\(customKeepDays) дн.")
                                .monospacedDigit()
                        }
                        Spacer()
                        Button("Сброс") { customKeepDays = 0 }
                            .buttonStyle(.bordered)
                            .disabled(customKeepDays == 0)
                    }
                    Text("Это значение дополняет выбранный режим риска. Если вы укажете больше дней, мы будем уважать более щадящую настройку.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        let month = CleanMetrics.monthTotal()
                        Label("Освобождено за месяц: \(formatBytes(month))", systemImage: "chart.line.uptrend.xyaxis")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer()
                        MetricsSparkline(series: CleanMetrics.seriesLastDays())
                            .frame(width: 120, height: 18)
                    }
                }
            }

            Section(header: Text("Исключения (Whitelist)"), footer: Text("Эти пути/маски и bundle id будут пропущены при очистке. Поддерживаются типы: Точный путь, Префикс пути, Bundle ID, Маска (*).")) {
                // Add rule row
                HStack(spacing: 8) {
                    Picker("Тип", selection: $newRuleKind) {
                        ForEach(ExclusionRule.Kind.allCases, id: \.self) { k in
                            Text(kindTitle(k)).tag(k)
                        }
                    }
                    .pickerStyle(.menu)
                    TextField(placeholderFor(newRuleKind), text: $newRuleValue)
                    Button("Добавить") { addRule() }
                        .disabled(newRuleValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                // Rules list
                if rules.isEmpty {
                    Text("Пока нет исключений.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(rules, id: \.id) { rule in
                        HStack {
                            Text(kindTitle(rule.kind)).font(.subheadline).foregroundStyle(.secondary)
                            Text(rule.value).font(.body).textSelection(.enabled)
                            Spacer()
                            Button(role: .destructive) { removeRule(rule) } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain)
                                .help("Удалить правило")
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section {
                Toggle(isOn: $includeHidden) {
                    Label("Включать скрытые файлы и папки", systemImage: "eye")
                }
                .toggleStyle(.switch)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: customKeepDays, perform: { newValue in
            CleanPrefs.customKeepDays = newValue
        })
        .onChange(of: rules.map { $0.id }) { _ in
            CleanPrefs.saveExclusions(rules)
        }
    }

    private func kindTitle(_ kind: ExclusionRule.Kind) -> String {
        switch kind {
        case .exactPath: return "Точный путь"
        case .pathPrefix: return "Префикс пути"
        case .bundleID: return "Bundle ID"
        case .glob: return "Маска (*)"
        }
    }

    private func placeholderFor(_ kind: ExclusionRule.Kind) -> String {
        switch kind {
        case .exactPath: return "/полный/путь/до/файла_или_папки"
        case .pathPrefix: return "/путь/начинается/с/этого"
        case .bundleID: return "com.example.app"
        case .glob: return "*/Library/Caches/*"
        }
    }

    private func addRule() {
        let value = newRuleValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        rules.append(ExclusionRule(kind: newRuleKind, value: value))
        newRuleValue = ""
    }

    private func removeRule(_ rule: ExclusionRule) {
        rules.removeAll { $0.id == rule.id }
    }

    private struct MetricsSparkline: View {
        var series: [Int64]
        var body: some View {
            GeometryReader { geo in
                let values = series.map { Double($0) }
                let maxV = max(values.max() ?? 1, 1)
                let points = values.enumerated().map { idx, v in
                    CGPoint(x: geo.size.width * CGFloat(Double(idx) / Double(max(series.count-1, 1))),
                            y: geo.size.height * CGFloat(1 - v / maxV))
                }
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    for pt in points.dropFirst() { p.addLine(to: pt) }
                }
                .stroke(Color.accentColor.opacity(0.8), lineWidth: 1.5)
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

