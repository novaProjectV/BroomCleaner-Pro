import SwiftUI

// Centralized app settings screen to keep ContentView lightweight.
// Persists options with @AppStorage so existing views can read them without tight coupling.

struct AppSettingsView: View {
    // Appearance
    @AppStorage("accentColor") private var accentColorRaw: String = "blue"

    // Cleaning safety
    @AppStorage("riskMode") private var riskModeRaw: String = RiskMode.safe.rawValue
    @AppStorage("hidePermissionHint") private var hidePermissionHint: Bool = false

    // Duplicates tool
    @AppStorage("duplicates.includeHidden") private var dupIncludeHidden: Bool = false
    @AppStorage("duplicates.skipPackages") private var dupSkipPackages: Bool = true
    @AppStorage("duplicates.minSizeBytes") private var dupMinSizeBytes: Int = 64 * 1024

    private var accentPalette: [String] { ["blue", "purple", "pink", "orange", "green", "teal"] }

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 16) {
            Text("Настройки").font(.title2.bold())
            Divider()
            appearanceSection
            cleaningSection
            duplicatesSection
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 520, minHeight: 380)
        #else
        List {
            appearanceSection
            cleaningSection
            duplicatesSection
        }
        .navigationTitle("Настройки")
        #endif
    }

    // MARK: Sections
    private var appearanceSection: some View {
        Section {
            HStack(spacing: 12) {
                Text("Цвет акцента")
                Spacer()
                AccentPickerSidebar(palette: accentPalette, selected: $accentColorRaw)
            }
        } header: {
            Text("Внешний вид")
        }
    }

    private var cleaningSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.fill").imageScale(.small)
                Picker("Режим", selection: $riskModeRaw) {
                    ForEach(RiskMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }
            Toggle("Скрывать подсказку о доступе", isOn: $hidePermissionHint)
        } header: {
            Text("Очистка")
        } footer: {
            Text("Режим 'Безопасно' пропускает недавно изменённые файлы. Подсказку о системных запросах доступа можно скрыть навсегда.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var duplicatesSection: some View {
        Section {
            Toggle("Показывать скрытые файлы при сканировании", isOn: $dupIncludeHidden)
            Toggle("Пропускать пакеты (.app/.bundle)", isOn: $dupSkipPackages)
            HStack(spacing: 8) {
                Text("Минимальный размер файла")
                Spacer()
                TextField("", value: $dupMinSizeBytes, format: .number)
                    .frame(width: 100)
                Text("байт").foregroundStyle(.secondary)
            }
        } header: {
            Text("Дубликаты")
        } footer: {
            Text("Рекомендуем порог ≥ 64 КБ для ускорения поиска. Пакеты приложений лучше пропускать, чтобы не трогать содержимое .app/.bundle.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview("Settings") {
    AppSettingsView()
}
