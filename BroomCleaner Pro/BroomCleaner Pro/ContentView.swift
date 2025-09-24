import SwiftUI
#if os(macOS)
import AppKit
#endif

// Make the result type visible in the view without repeating the long name.
typealias CleanResult = CleaningCore.CleanResult

enum RiskMode: String, CaseIterable, Identifiable {
    case safe, standard, advanced
    var id: String { rawValue }
    var title: String {
        switch self { case .safe: "Безопасно"; case .standard: "Стандарт"; case .advanced: "Продвинуто" }
    }
    var note: String {
        switch self {
        case .safe: "Не трогаем файлы, изменённые за последние 7 дней."
        case .standard: "Пропускаем последние 3 дня, скрытые — по настройке."
        case .advanced: "Максимально агрессивно. Без ограничений по давности."
        }
    }
    var keepDays: Int { self == .safe ? 7 : self == .standard ? 3 : 0 }
}

enum Tool: String, CaseIterable, Identifiable {
    case smart = "Быстрая очистка"
    case cache = "Очистить кэш"
    case logs  = "Очистить логи"
    case uninstall = "Удалить приложение"
    case big = "Большие файлы"
    case duplicates = "Дубликаты"
    case browsers = "Кэш браузеров"
    case emptyTrash = "Очистить Корзину"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .smart: return "sparkles"
        case .cache: return "trash"
        case .logs:  return "doc.text"
        case .uninstall: return "shippingbox"
        case .big: return "externaldrive"
        case .duplicates: return "square.on.square"
        case .browsers: return "globe"
        case .emptyTrash: return "trash.slash"
        }
    }
}

struct CleanerView: View {
    @State private var selection: Tool = .smart
    @State private var isWorking = false
    @State private var status: String = ""
    @State private var showPermissionHint = true
    @State private var includeHidden = false
    @State private var lastResult: CleanResult?
    // Undo/Restore window (15 minutes)
    @State private var undoItems: [CleaningCore.TrashedItem] = []
    @State private var undoRemaining: Int = 0
    @State private var undoTimer: Timer?
    // Hover‑состояние для фолбэк‑сайдбара
    @State private var hoveredTool: Tool?
    // Для предпросмотра и удаления приложений
    @State private var previewNodes: [PreviewNode] = []
    @State private var uninstallBtnState: SmartButtonState = .idle(title: "Удалить выбранное")
    @State private var smartProgress: Double = 0
    @State private var smartFreedBytes: Int64 = 0
    @State private var smartFiles: Int = 0
    @State private var smartDuration: TimeInterval = 0
    @State private var showAssistant: Bool = false

    @State private var pulseGlow: Bool = false
    @State private var hoverSmartButton: Bool = false

    @State private var showReport: Bool = false
    @State private var justFinished: Bool = false
    @State private var showEmptyTrashConfirm: Bool = false
    @State private var automationDenied: Bool = false

    // Выбираемый пользователем акцентный цвет (сохраняется между запусками)
    @AppStorage("accentColor") private var accentColorRaw: String = "blue"
    @AppStorage("riskMode") private var riskModeRaw: String = RiskMode.safe.rawValue
    @AppStorage("hidePermissionHint") private var hidePermissionHint: Bool = false
    private var riskMode: RiskMode { RiskMode(rawValue: riskModeRaw) ?? .safe }

    private var accent: Color { color(from: accentColorRaw) }
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

    private var appBackplate: some View {
        ZStack {
            RadialGradient(colors: [accent.opacity(0.25), .clear], center: .topLeading, startRadius: 80, endRadius: 600)
                .blur(radius: 60)
            RadialGradient(colors: [.purple.opacity(0.18), .clear], center: .bottomTrailing, startRadius: 80, endRadius: 700)
                .blur(radius: 80)
        }
        .ignoresSafeArea()
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                liquidLayout
            } else {
                fallbackLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: selection)
        .animation(.easeOut(duration: 0.15), value: isWorking)
        .animation(.easeOut(duration: 0.2), value: showPermissionHint)
        .background(appBackplate)
        .tint(accent)
        .sheet(isPresented: $showReport) {
            MonthlyReportSheet(undoItems: $undoItems, onUndo: { restoreFromUndo() })
        }
        .sheet(isPresented: $showAssistant) {
            AssistantPanel(actions: AssistantActions(
                runSmartClean: { runSmartClean() },
                cleanCaches: { perform(.cache) },
                cleanLogs: { perform(.logs) },
                showMonthlyReport: { showReport = true }
            ))
        }
        .alert("Очистить Корзину?", isPresented: $showEmptyTrashConfirm) {
            Button("Отмена", role: .cancel) {}
            Button("Очистить", role: .destructive) { emptyTrash() }
        } message: {
            Text("Все элементы будут удалены без возможности восстановления.")
        }
    }
}

@available(macOS 26.0, *)
private extension CleanerView {
    var liquidLayout: some View {
        GlassEffectContainer(spacing: 0) {
            liquidRootStack
        }
    }

    private var liquidRootStack: some View {
        HStack(spacing: 0) {
            liquidSidebar
            liquidContent
        }
    }

    private var liquidSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(accent)
                Text("BroomCleaner Pro")
                    .font(.headline)
            }
            .padding(.bottom, 2)

            Text("Инструменты")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ForEach(Tool.allCases) { tool in
                if selection == tool {
                    Button { selection = tool } label: {
                        HStack {
                            Label(tool.rawValue, systemImage: tool.icon)
                            Spacer()
                            if let badge = metricBadge(for: tool) {
                                Text(badge)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(GlassProminentButtonStyle())
                    .keyboardShortcut(shortcut(for: tool), modifiers: [.command])
                    .help(help(for: tool))
                } else {
                    Button { selection = tool } label: {
                        HStack {
                            Label(tool.rawValue, systemImage: tool.icon)
                            Spacer()
                            if let badge = metricBadge(for: tool) {
                                Text(badge)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(GlassButtonStyle())
                    .keyboardShortcut(shortcut(for: tool), modifiers: [.command])
                    .help(help(for: tool))
                }
            }

            Divider().padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 8) {
                Text("Цвет акцента")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                AccentPickerSidebar(palette: accentPalette, selected: $accentColorRaw)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 240, alignment: .topLeading)
        .frame(maxHeight: .infinity)
        .glassEffect(in: .rect())
    }

    private var liquidContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(for: selection))
                        .font(.title2.bold())
                    Text(description(for: selection))
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Spacer()
                // Assistant chip button
                Button { showAssistant = true } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Color.mint).frame(width: 6, height: 6)
                        Circle().fill(Color.indigo).frame(width: 6, height: 6)
                        Text("Assistant")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Открыть ассистента")
                if isWorking { ProgressView().controlSize(.small) }
            }

            CleaningControlsView(riskModeRaw: $riskModeRaw, includeHidden: $includeHidden)

            if showPermissionHint && !hidePermissionHint {
                PermissionHintView(show: $showPermissionHint, hidePermanently: $hidePermissionHint, accent: accent)
            }

            if selection == .uninstall {
                Divider().padding(.vertical, 4)
                Text("Удаление приложения с корнями").font(.headline)
                AppDragTarget()
                    .frame(minHeight: 160)
                    .help("Перетащите приложение (.app) для анализа его следов и удаления.")

                if !previewNodes.isEmpty {
                    TreePreviewView(nodes: $previewNodes)
                        .frame(minHeight: 220)

                    SmartProgressButton(state: $uninstallBtnState) {
                        runUninstallFromPreview()
                    }
                }

                HStack(spacing: 12) {
                    Button(action: { openApplications() }) {
                        Label("Открыть /Applications", systemImage: "folder")
                    }
                    .buttonStyle(GlassButtonStyle())
                    .help("Открыть папку приложений в Finder.")

                    Button(action: { openTrash() }) {
                        Label("Открыть Корзину", systemImage: "trash")
                    }
                    .buttonStyle(GlassButtonStyle())
                    .keyboardShortcut("t", modifiers: [.command])
                    .help("Открыть Корзину в Finder.")
                }
            } else if selection == .smart {
                VStack(spacing: 20) {
                    HStack(spacing: 16) {
                        Text("Быстрый, безопасный, красивый.")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    // Сводка сверху: объём, файлы, длительность (показываем во время и после)
                    if isWorking || smartFiles > 0 || smartFreedBytes > 0 {
                        HStack(spacing: 10) {
                            Image(systemName: isWorking ? "hourglass" : "checkmark.circle.fill")
                                .foregroundStyle(isWorking ? Color.secondary : Color.green)
                            Button { showReport = true } label: {
                                Label("Освобождено за месяц: \(formatBytes(CleanMetrics.monthTotal()))", systemImage: "chart.line.uptrend.xyaxis")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            Text("−\(formatBytes(smartFreedBytes)) • \(smartFiles) файлов • \(formatETA(smartDuration))")
                                .font(.subheadline)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }

                    // Круглая кнопка с кольцевым прогрессом вокруг
                    Button(action: { runSmartClean() }) {
                        ZStack {
                            // Pulsating glow ring (idle only)
                            if !isWorking {
                                Circle()
                                    .stroke(accent.opacity(0.22), lineWidth: 8)
                                    .scaleEffect(pulseGlow ? 1.06 : 0.94)
                                    .opacity(pulseGlow ? 0.65 : 0.25)
                                    .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulseGlow)
                            }

                            // Внешнее кольцо прогресса
                            Circle()
                                .stroke(Color.primary.opacity(0.12), lineWidth: 10)
                            Circle()
                                .trim(from: 0, to: CGFloat(max(0.01, min(1.0, smartProgress))))
                                .stroke(AngularGradient(gradient: Gradient(colors: [
                                    Color.accentColor.opacity(0.9),
                                    Color.accentColor.opacity(0.5)
                                ]), center: .center), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .animation(.easeInOut(duration: 0.25), value: smartProgress)

                            // Внутренний круг и контент
                            Circle()
                                .fill(LinearGradient(colors: [accent.opacity(0.55), accent.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .padding(10)
                                .overlay(
                                    Circle().stroke(AngularGradient(gradient: Gradient(colors: [accent.opacity(0.9), .clear, accent.opacity(0.9)]), center: .center), lineWidth: 3)
                                        .opacity(0.6)
                                )
                                .shadow(radius: 18)

                            VStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .font(.system(size: 36, weight: .semibold))
                                Text(isWorking ? "Сканирую…" : (justFinished ? "Повторить" : "Сканировать"))
                                    .font(.title3.weight(.semibold))
                            }
                        }
                        .frame(width: 180, height: 180)
                    }
                    .scaleEffect(hoverSmartButton ? 1.02 : 1.0)
                    .onHover { hoverSmartButton = $0 }
                    .accessibilityValue(isWorking ? "Сканирование, прогресс \(Int(smartProgress * 100))%" : "Готовность")
                    .buttonStyle(.plain)
                    .disabled(isWorking)
                    .help("Запустить умную очистку: кэш + логи")
                    .onAppear { pulseGlow = true }
                    .overlay {
                        if justFinished && !isWorking {
                            CelebrationOverlay(accent: accent)
                                .transition(.scale.combined(with: .opacity))
                                .allowsHitTesting(false)
                        }
                    }

                    HStack(spacing: 16) {
                        FeaturePillView(title: "Кэш", systemImage: "trash", accent: accent)
                        FeaturePillView(title: "Логи", systemImage: "doc.text", accent: accent)
                        FeaturePillView(title: "Безопасно", systemImage: "checkmark.shield", accent: accent)
                    }
                    .padding(.top, 4)

                    MetricsFooterView(showReport: $showReport)
                }
            } else if selection == .emptyTrash {
                VStack(spacing: 12) {
                    Text("Удаление из Корзины — безвозвратно.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Очистить Корзину") { showEmptyTrashConfirm = true }
                        .buttonStyle(GlassProminentButtonStyle())
                        .keyboardShortcut("e", modifiers: [.command])
                        .help("Окончательно удалить элементы из Корзины.")

                    Button("Через Finder") { emptyTrashViaFinder() }
                        .buttonStyle(GlassButtonStyle())
                        .help("Попросить Finder очистить Корзину (требуется доступ к Автоматизации).")

                    if automationDenied {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("Разрешите Автоматизацию: Системные настройки → Конфиденциальность и безопасность → Автоматизация → BroomCleaner Pro → Finder")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 12) {
                        Button(action: { openTrash() }) {
                            Label("Открыть Корзину", systemImage: "trash")
                        }
                        .buttonStyle(GlassButtonStyle())
                        .keyboardShortcut("t", modifiers: [.command])
                        .help("Открыть Корзину в Finder.")
                    }
                }
            } else if selection == .big {
                BigFilesView()
            } else if selection == .duplicates {
                DuplicatesView()
            } else {
                summaryView
                    .glassEffect(in: .rect(cornerRadius: 12))

                HStack(spacing: 12) {
                    Button(primaryButtonTitle(for: selection)) { perform(selection) }
                        .buttonStyle(GlassProminentButtonStyle())
                        .disabled(isWorking)
                        .keyboardShortcut("r", modifiers: [.command])
                        .help(primaryHelp(for: selection))

                    Button(action: { openTrash() }) {
                        Label("Открыть Корзину", systemImage: "trash")
                    }
                    .buttonStyle(GlassButtonStyle())
                    .keyboardShortcut("t", modifiers: [.command])
                    .help("Открыть Корзину в Finder.")

                    Button(action: { openLibrary() }) {
                        Label("Открыть ~/Library", systemImage: "folder")
                    }
                    .buttonStyle(GlassButtonStyle())
                    .help("Открыть вашу папку Library в Finder.")
                }
            }

            if !status.isEmpty {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                    .accessibilityLabel("Статус")
            }
            
            if undoRemaining > 0 && !undoItems.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Файлы в Корзине. Вернуть (\(formattedRemaining(undoRemaining)))")
                        .font(.footnote)
                    Spacer()
                    Button("Вернуть") { restoreFromUndo() }
                        .buttonStyle(GlassButtonStyle())
                }
                .padding(10)
                .glassEffect(in: .rect(cornerRadius: 10))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(in: .rect(cornerRadius: 24))
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: [accent.opacity(0.10), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LinearGradient(colors: [accent.opacity(0.9), accent.opacity(0.3), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(height: 3)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }
    
    @ViewBuilder
    private var summaryView: some View {
        HStack(spacing: 16) {
            StatRow(value: lastResult?.items ?? 0, label: "Удалено", systemImage: "checkmark.circle.fill", tint: .green)
            StatRow(value: lastResultBytesString, label: "Освобождено", systemImage: "internaldrive", tint: .blue)
            StatRow(value: lastResult?.failed ?? 0, label: "Не удалось", systemImage: "exclamationmark.triangle.fill", tint: .orange)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

struct MonthlyReportSheet: View {
    @Binding var undoItems: [CleaningCore.TrashedItem]
    var onUndo: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Отчёт за месяц").font(.headline)
                Spacer()
                Button("Закрыть") { dismiss() }
            }
            let total = CleanMetrics.monthTotal()
            Text("Итого за месяц: " + ByteCountFormatter.string(fromByteCount: total, countStyle: .file))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            HStack {
                Spacer()
                if !undoItems.isEmpty {
                    Button("Откатить последние \(undoItems.count)") {
                        onUndo()
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 240)
    }
}

private extension CleanerView {
    var fallbackLayout: some View {
        HStack(spacing: 0) {
            // Sidebar — фолбэк материал, тоже вплотную к левому краю
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(accent)
                    Text("BroomCleaner Pro")
                        .font(.headline)
                }
                .padding(.bottom, 2)

                Text("Инструменты")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                ForEach(Tool.allCases) { tool in
                    Button {
                        selection = tool
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: tool.icon)
                            Text(tool.rawValue)
                            Spacer()
                            if let badge = metricBadge(for: tool) {
                                Text(badge)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                            }
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(
                                    selection == tool
                                    ? Color.primary.opacity(0.08)
                                    : (hoveredTool == tool ? Color.primary.opacity(0.05) : .clear)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(shortcut(for: tool), modifiers: [.command])
                    .help(help(for: tool))
                    .onHover { inside in
                        hoveredTool = inside ? tool : (hoveredTool == tool ? nil : hoveredTool)
                    }
                }

                Divider().padding(.vertical, 6)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Цвет акцента")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    AccentPickerSidebar(palette: accentPalette, selected: $accentColorRaw)
                }
                Spacer()
            }
            .padding(12)
            .frame(width: 240, alignment: .topLeading)
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial)

            // Content — обычная карточка
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title(for: selection))
                            .font(.title2.bold())
                        Text(description(for: selection))
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    Spacer()
                    Button { showAssistant = true } label: {
                        HStack(spacing: 6) {
                            Circle().fill(Color.mint).frame(width: 6, height: 6)
                            Circle().fill(Color.indigo).frame(width: 6, height: 6)
                            Text("Assistant")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help("Открыть ассистента")
                    if isWorking {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                CleaningControlsView(riskModeRaw: $riskModeRaw, includeHidden: $includeHidden)

                // Подсказка про системный запрос доступа (фолбэк)
                if showPermissionHint && !hidePermissionHint {
                    PermissionHintView(show: $showPermissionHint, hidePermanently: $hidePermissionHint, accent: accent)
                }

                if selection == .uninstall {
                    Divider().padding(.vertical, 4)
                    Text("Удаление приложения с корнями").font(.headline)
                    AppDragTarget()
                        .frame(minHeight: 160)
                        .help("Перетащите приложение (.app) для анализа его следов и удаления.")

                    if !previewNodes.isEmpty {
                        TreePreviewView(nodes: $previewNodes)
                            .frame(minHeight: 220)

                        SmartProgressButton(state: $uninstallBtnState) {
                            runUninstallFromPreview()
                        }
                    }

                    HStack(spacing: 12) {
                        Button(action: { openApplications() }) {
                            Label("Открыть /Applications", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .help("Открыть папку приложений в Finder.")

                        Button(action: { openTrash() }) {
                            Label("Открыть Корзину", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut("t", modifiers: [.command])
                        .help("Открыть Корзину в Finder.")
                    }
                } else if selection == .smart {
                    VStack(spacing: 16) {
                        // Сводка сверху: объём, файлы, длительность (показываем во время и после)
                        if isWorking || smartFiles > 0 || smartFreedBytes > 0 {
                            HStack(spacing: 10) {
                                Image(systemName: isWorking ? "hourglass" : "checkmark.circle.fill")
                                    .foregroundStyle(isWorking ? Color.secondary : Color.green)
                                Button { showReport = true } label: {
                                    Label("Освобождено за месяц: \(formatBytes(CleanMetrics.monthTotal()))", systemImage: "chart.line.uptrend.xyaxis")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                Spacer()
                                Text("−\(formatBytes(smartFreedBytes)) • \(smartFiles) файлов • \(formatETA(smartDuration))")
                                    .font(.subheadline)
                                    .monospacedDigit()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                        }

                        Button(action: { runSmartClean() }) {
                            ZStack {
                                // Pulsating glow ring (idle only)
                                if !isWorking {
                                    Circle()
                                        .stroke(accent.opacity(0.20), lineWidth: 8)
                                        .scaleEffect(pulseGlow ? 1.06 : 0.94)
                                        .opacity(pulseGlow ? 0.6 : 0.25)
                                        .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: pulseGlow)
                                }

                                // Внешнее кольцо прогресса
                                Circle()
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 10)
                                Circle()
                                    .trim(from: 0, to: CGFloat(max(0.01, min(1.0, smartProgress))))
                                    .stroke(AngularGradient(gradient: Gradient(colors: [
                                        Color.accentColor.opacity(0.9),
                                        Color.accentColor.opacity(0.5)
                                    ]), center: .center), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .animation(.easeInOut(duration: 0.25), value: smartProgress)

                                // Внутренний круг и контент
                                Circle().fill(accent.opacity(0.25))
                                    .padding(10)

                                VStack(spacing: 6) {
                                    Image(systemName: "sparkles").font(.system(size: 30, weight: .semibold))
                                    Text(isWorking ? "Сканирую…" : "Сканировать")
                                        .font(.headline)
                                }
                            }
                            .frame(width: 160, height: 160)
                        }
                        .scaleEffect(hoverSmartButton ? 1.02 : 1.0)
                        .onHover { hoverSmartButton = $0 }
                        .buttonStyle(.plain)
                        .disabled(isWorking)
                        .help("Запустить умную очистку: кэш + логи")
                        .onAppear { pulseGlow = true }
                        .overlay {
                            if justFinished && !isWorking {
                                CelebrationOverlay(accent: accent)
                                    .transition(.scale.combined(with: .opacity))
                                    .allowsHitTesting(false)
                            }
                        }

                        HStack(spacing: 12) {
                            FeaturePillView(title: "Кэш", systemImage: "trash", accent: accent)
                            FeaturePillView(title: "Логи", systemImage: "doc.text", accent: accent)
                            FeaturePillView(title: "Безопасно", systemImage: "checkmark.shield", accent: accent)
                        }

                        MetricsFooterView(showReport: $showReport)
                    }
                } else if selection == .emptyTrash {
                    VStack(spacing: 12) {
                        Text("Удаление из Корзины — безвозвратно.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Очистить Корзину") { showEmptyTrashConfirm = true }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut("e", modifiers: [.command])
                            .help("Окончательно удалить элементы из Корзины.")

                        Button("Через Finder") { emptyTrashViaFinder() }
                            .buttonStyle(.bordered)
                            .help("Попросить Finder очистить Корзину (требуется доступ к Автоматизации).")

                        if automationDenied {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                Text("Разрешите Автоматизацию: Системные настройки → Конфиденциальность и безопасность → Автоматизация → BroomCleaner Pro → Finder")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack(spacing: 12) {
                            Button(action: { openTrash() }) {
                                Label("Открыть Корзину", systemImage: "trash")
                            }
                            .buttonStyle(.bordered)
                            .keyboardShortcut("t", modifiers: [.command])
                            .help("Открыть Корзину в Finder.")
                        }
                    }
                } else if selection == .big {
                    BigFilesView()
                } else if selection == .duplicates {
                    DuplicatesView()
                } else {
                    HStack(spacing: 16) {
                        StatRow(value: lastResult?.items ?? 0, label: "Удалено", systemImage: "checkmark.circle.fill", tint: .green)
                        StatRow(value: lastResultBytesString, label: "Освобождено", systemImage: "internaldrive", tint: .blue)
                        StatRow(value: lastResult?.failed ?? 0, label: "Не удалось", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )

                    HStack(spacing: 12) {
                        Button(primaryButtonTitle(for: selection)) {
                            perform(selection)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking)
                        .keyboardShortcut("r", modifiers: [.command])
                        .help(primaryHelp(for: selection))

                        Button(action: { openTrash() }) {
                            Label("Открыть Корзину", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .keyboardShortcut("t", modifiers: [.command])
                        .help("Открыть Корзину в Finder.")

                        Button(action: { openLibrary() }) {
                            Label("Открыть ~/Library", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .help("Открыть вашу папку Library в Finder.")
                    }
                }

                if !status.isEmpty {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                        .accessibilityLabel("Статус")
                }

                if undoRemaining > 0 && !undoItems.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("Файлы в Корзине. Вернуть (\(formattedRemaining(undoRemaining)))")
                            .font(.footnote)
                        Spacer()
                        Button("Вернуть") { restoreFromUndo() }
                            .buttonStyle(.bordered)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .padding([.trailing], 8) // лёгкий «воздух» справа
        }
    }

    // Общее свойство для обоих макетов
    private var lastResultBytesString: String {
        if let r = lastResult { return formatBytes(r.bytes) }
        return "0 Б"
    }

    // MARK: - Helpers
    func shortcut(for tool: Tool) -> KeyEquivalent {
        switch tool {
        case .smart: return "s"
        case .cache: return "1"
        case .logs:  return "2"
        case .uninstall: return "3"
        case .big: return "4"
        case .duplicates: return "6"
        case .browsers: return "7"
        case .emptyTrash: return "5"
        }
    }

    func help(for tool: Tool) -> String {
        switch tool {
        case .smart: return "Умная очистка: кэш + логи одним нажатием."
        case .cache: return "Очистка временных файлов и кеша пользователя."
        case .logs:  return "Удаление пользовательских лог‑файлов и отчётов."
        case .uninstall: return "Полное удаление приложения вместе с его данными."
        case .big: return "Поиск и удаление крупных файлов по выбранным папкам."
        case .duplicates: return "Поиск и удаление дубликатов файлов в выбранных папках."
        case .browsers: return "Очистка кэшей Safari, Chrome, Edge и Firefox."
        case .emptyTrash: return "Очистить содержимое Корзины без возможности восстановления."
        }
    }

    func primaryHelp(for tool: Tool) -> String {
        switch tool {
        case .smart: return "Просканировать систему и удалить кэш и логи."
        case .cache: return "Сканировать и переместить кэш в Корзину."
        case .logs:  return "Сканировать и переместить логи в Корзину."
        case .uninstall: return "Удаление приложений выполняется через область перетаскивания."
        case .big: return "Просканировать выбранные папки и найти крупные файлы."
        case .duplicates: return "Просканировать папки и удалить дубликаты (в Корзину)."
        case .browsers: return "Очистить кэши браузеров (в Корзину)."
        case .emptyTrash: return "Окончательно удалить элементы из Корзины."
        }
    }

    func title(for tool: Tool) -> String {
        switch tool {
        case .smart: return "Быстрая очистка"
        case .cache: return "Очистить кэш"
        case .logs:  return "Очистить логи"
        case .uninstall: return "Удалить приложение"
        case .big: return "Большие файлы"
        case .duplicates: return "Дубликаты"
        case .browsers: return "Кэш браузеров"
        case .emptyTrash: return "Очистить Корзину"
        }
    }

    func description(for tool: Tool) -> String {
        switch tool {
        case .smart:
            return "Один клик, чтобы найти и удалить кэш и логи пользователя. Безопасно — всё уходит в Корзину."
        case .cache:
            return "Удаление временных файлов и кеша приложений пользователя."
        case .logs:
            return "Удаление лог‑файлов пользователя из стандартных директорий."
        case .uninstall:
            return "Перетащите приложение сюда для полного удаления вместе с его данными."
        case .big:
            return "Найдём тяжёлые файлы в выбранных папках. Удаление — в Корзину."
        case .duplicates:
            return "Найдём одинаковые файлы и поможем безопасно удалить копии."
        case .browsers:
            return "Удалим временные файлы браузеров: Safari, Chrome, Edge, Firefox. Всё переместится в Корзину. В безопасных режимах пропускаем свежие файлы."
        case .emptyTrash:
            return "Окончательно удалить элементы из Корзины. Восстановление будет невозможно."
        }
    }

    func primaryButtonTitle(for tool: Tool) -> String {
        switch tool {
        case .smart: return "Сканировать"
        case .cache: return "Очистить кэш"
        case .logs:  return "Удалить логи"
        case .uninstall: return "Удалить приложение"
        case .big: return "Сканировать"
        case .duplicates: return "Сканировать"
        case .browsers: return "Очистить"
        case .emptyTrash: return "Очистить Корзину"
        }
    }

    func perform(_ tool: Tool) {
        isWorking = true
        status = "Сканирую…"
        Task.detached { [includeHidden, riskMode] in
            let result: CleanResult
            switch tool {
            case .smart:
                let r1 = CleaningCore.cleanCaches(includeHidden: includeHidden, riskMode: riskMode)
                let r2 = CleaningCore.cleanLogs(includeHidden: includeHidden, riskMode: riskMode)
                var merged = CleanResult(); merged.add(r1); merged.add(r2)
                result = merged
            case .big:
                result = CleanResult()
            case .cache:
                result = CleaningCore.cleanCaches(includeHidden: includeHidden, riskMode: riskMode)
            case .logs:
                result = CleaningCore.cleanLogs(includeHidden: includeHidden, riskMode: riskMode)
            case .uninstall:
                result = CleanResult()
            case .emptyTrash:
                result = CleanResult()
            case .duplicates:
                result = CleanResult()
            case .browsers:
                result = CleaningCore.cleanBrowserCaches(includeHidden: includeHidden, riskMode: riskMode)
            }
            let finalResult = result
            await MainActor.run {
                self.isWorking = false
                self.lastResult = finalResult
                var text = "Удалено \(finalResult.items) объектов, освобождено \(formatBytes(finalResult.bytes)). Все перемещено в Корзину."
                if finalResult.failed > 0 { text += " Не удалось переместить \(finalResult.failed) элементов." }
                self.status = text
                if !finalResult.trashed.isEmpty {
                    self.undoItems = finalResult.trashed
                    self.startUndoCountdown(seconds: 15 * 60)
                }
                if tool == .emptyTrash {
                    self.showEmptyTrashConfirm = true
                }
                // Log metrics
                switch tool {
                case .smart:
                    CleanMetrics.log(bytes: finalResult.bytes, kind: .smart)
                case .cache:
                    CleanMetrics.log(bytes: finalResult.bytes, kind: .cache)
                case .logs:
                    CleanMetrics.log(bytes: finalResult.bytes, kind: .logs)
                case .uninstall:
                    CleanMetrics.log(bytes: finalResult.bytes, kind: .uninstall)
                case .big:
                    CleanMetrics.log(bytes: finalResult.bytes, kind: .big)
                case .emptyTrash:
                    break
                case .duplicates:
                    break
                case .browsers:
                    CleanMetrics.log(bytes: finalResult.bytes, kind: .browsers)
                }
            }
        }
    }

    func runSmartClean() {
        guard !isWorking else { return }
        isWorking = true
        status = "Сканирую…"
        smartProgress = 0
        smartFreedBytes = 0
        smartFiles = 0
        smartDuration = 0

        let includeHiddenLocal = includeHidden
        let riskModeLocal = riskMode
        let start = Date()

        Task.detached { [includeHiddenLocal, riskModeLocal] in
            // First phase: caches
            let r1 = CleaningCore.cleanCaches(includeHidden: includeHiddenLocal, riskMode: riskModeLocal)
            let elapsed1 = Date().timeIntervalSince(start)
            await MainActor.run {
                smartProgress = 0.5
                smartFreedBytes = r1.bytes
                smartFiles = r1.items
                smartDuration = elapsed1
            }

            // Second phase: logs
            let r2 = CleaningCore.cleanLogs(includeHidden: includeHiddenLocal, riskMode: riskModeLocal)
            var merged = CleanResult(); merged.add(r1); merged.add(r2)
            let duration = Date().timeIntervalSince(start)

            let mergedResult = merged
            let finalDuration = duration

            await MainActor.run {
                isWorking = false
                lastResult = mergedResult
                smartProgress = 1.0
                smartFreedBytes = mergedResult.bytes
                smartFiles = mergedResult.items
                smartDuration = finalDuration

                var text = "Удалено \(mergedResult.items) объектов, освобождено \(formatBytes(mergedResult.bytes)). Все перемещено в Корзину."
                if mergedResult.failed > 0 { text += " Не удалось переместить \(mergedResult.failed) элементов." }
                status = text
                if !mergedResult.trashed.isEmpty {
                    undoItems = mergedResult.trashed
                    startUndoCountdown(seconds: 15 * 60)
                }
                CleanMetrics.log(bytes: mergedResult.bytes, kind: .smart)
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    justFinished = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation(.easeOut(duration: 0.35)) {
                        justFinished = false
                    }
                }
            }
        }
    }

    // Pretty formatting for bytes (UI-side)
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

    private func formatETA(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }

    // MARK: - Helpers (Finder/Trash)

    private func openApplications() {
        #if os(macOS)
        let url = URL(fileURLWithPath: "/Applications")
        NSWorkspace.shared.open(url)
        #endif
    }

    private func openTrash() {
        #if os(macOS)
        let url = URL(fileURLWithPath: ("~/.Trash" as NSString).expandingTildeInPath)
        NSWorkspace.shared.open(url)
        #endif
    }

    private func emptyTrash() {
        #if os(macOS)
        let fm = FileManager.default

        // Collect all trash URLs for the current user from all accessible volumes
        var trashURLs = fm.urls(for: .trashDirectory, in: .userDomainMask)

        // Fallback to legacy home trash if API returns nothing (shouldn't happen, but be safe)
        let legacyHomeTrash = URL(fileURLWithPath: ("~/.Trash" as NSString).expandingTildeInPath, isDirectory: true)
        if !trashURLs.contains(legacyHomeTrash) {
            trashURLs.append(legacyHomeTrash)
        }

        var totalBytes: Int64 = 0
        var removedItems = 0
        var failedItems = 0

        // Helper to compute approximate size similar to CleaningCore.approximateSize
        func approximateSize(_ url: URL) -> Int64 {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
                if !isDir.boolValue {
                    if let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) {
                        return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                    }
                    return 0
                } else {
                    var total: Int64 = 0
                    if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey], options: [.skipsHiddenFiles]) {
                        for case let f as URL in en {
                            if let values = try? f.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]), values.isRegularFile == true {
                                total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                            }
                        }
                    }
                    return total
                }
            }
            return 0
        }

        for trashURL in trashURLs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: trashURL.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if let items = try? fm.contentsOfDirectory(at: trashURL, includingPropertiesForKeys: nil, options: []) {
                for item in items {
                    totalBytes += approximateSize(item)
                    do {
                        try fm.removeItem(at: item)
                        removedItems += 1
                    } catch {
                        failedItems += 1
                    }
                }
            }
        }

        let freed = formatBytes(totalBytes)
        if removedItems == 0 && failedItems == 0 {
            status = "Корзина уже пуста."
            automationDenied = false
        } else if failedItems == 0 {
            status = "Корзина очищена: удалено \(removedItems) объектов, освобождено \(freed)."
            automationDenied = false
        } else {
            status = "Корзина очищена частично: удалено \(removedItems), не удалось \(failedItems). Освобождено \(freed). Попробуйте \"Через Finder\" и дайте доступ к Автоматизации."
            automationDenied = false
        }
        #endif
    }
    
    private func emptyTrashViaFinder() {
        #if os(macOS)
        let scriptSource = "tell application \"Finder\" to empty the trash"
        if let script = NSAppleScript(source: scriptSource) {
            var errorDict: NSDictionary?
            _ = script.executeAndReturnError(&errorDict)
            if let err = errorDict, let code = err[NSAppleScript.errorNumber] as? Int {
                // -1743: Not authorized to send Apple events to Finder (Automation permission denied)
                if code == -1743 {
                    automationDenied = true
                    status = "Нет доступа к Автоматизации. Разрешите управлять Finder в Системных настройках."
                } else {
                    automationDenied = false
                    status = "Не удалось попросить Finder очистить Корзину (ошибка \(code))."
                }
            } else {
                automationDenied = false
                // If Finder did it, we can clear status accordingly
                status = "Корзина очищена через Finder."
            }
        } else {
            status = "Не удалось создать сценарий для Finder."
        }
        #endif
    }

    // MARK: - Undo helpers
    private func startUndoCountdown(seconds: Int) {
        undoTimer?.invalidate()
        undoRemaining = seconds
        undoTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in
            if undoRemaining > 0 {
                undoRemaining -= 1
            } else {
                t.invalidate()
                undoItems.removeAll()
            }
        }
    }

    private func formattedRemaining(_ sec: Int) -> String {
        let m = sec / 60
        let s = sec % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func restoreFromUndo() {
        guard !undoItems.isEmpty else { return }
        var restored = 0
        for item in undoItems {
            let original = URL(fileURLWithPath: item.originalPath)
            let trashed = URL(fileURLWithPath: item.trashedPath)
            do {
                let parent = original.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: original.path) {
                    var tmp: NSURL?
                    try FileManager.default.trashItem(at: original, resultingItemURL: &tmp)
                }
                try FileManager.default.moveItem(at: trashed, to: original)
                restored += 1
            } catch {
                // ignore individual errors
            }
        }
        undoTimer?.invalidate()
        undoItems.removeAll()
        undoRemaining = 0
        status = "Восстановлено \(restored) объектов из Корзины."
    }
    
    private func openLibrary() {
        #if os(macOS)
        let url = URL(fileURLWithPath: ("~/Library" as NSString).expandingTildeInPath)
        NSWorkspace.shared.open(url)
        #endif
    }

    func metricBadge(for tool: Tool) -> String? {
        switch tool {
        case .cache:
            let b = CleanMetrics.monthTotal(kind: .cache)
            return b > 0 ? "\(formatBytes(b))" : nil
        case .logs:
            let b = CleanMetrics.monthTotal(kind: .logs)
            return b > 0 ? "\(formatBytes(b))" : nil
        case .browsers:
            let b = CleanMetrics.monthTotal(kind: .browsers)
            return b > 0 ? "\(formatBytes(b))" : nil
        default:
            return nil
        }
    }

    struct MetricsSparkline: View {
        var series: [Int64]
        var body: some View {
            GeometryReader { geo in
                let values = series.map { Double($0) }
                let maxV = max(values.max() ?? 1, 1)
                let points = values.enumerated().map { idx, v in
                    CGPoint(x: geo.size.width * CGFloat(Double(idx) / Double(max(series.count-1, 1))),
                            y: geo.size.height * CGFloat(1 - v / maxV))
                }
                ZStack {
                    Path { p in
                        guard let first = points.first else { return }
                        p.move(to: first)
                        for pt in points.dropFirst() { p.addLine(to: pt) }
                    }
                    .stroke(Color.accentColor.opacity(0.8), lineWidth: 1.5)

                    if let last = points.last {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 4, height: 4)
                            .position(last)
                    }
                }
            }
        }
    }

    struct MetricsPie: View {
        var slices: [(String, Int64)] // (label, bytes)
        var body: some View {
            GeometryReader { geo in
                let total = max(1, slices.reduce(0) { $0 + $1.1 })
                let angles = slices.map { Double($0.1) / Double(total) * 360.0 }
                ZStack {
                    ForEach(Array(slices.indices), id: \.self) { idx in
                        let start = -90 + angles.prefix(idx).reduce(0, +)
                        let end = start + angles[idx]
                        PieSlice(startAngle: .degrees(start), endAngle: .degrees(end))
                            .fill(palette(idx).opacity(0.85))
                    }
                    // Legend
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(slices.indices), id: \.self) { idx in
                            let s = slices[idx]
                            HStack(spacing: 6) {
                                Circle().fill(palette(idx)).frame(width: 8, height: 8)
                                Text("\(s.0) — \(ByteCountFormatter.string(fromByteCount: s.1, countStyle: .file))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(8)
                }
                .overlay(
                    Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
            }
        }

        private func palette(_ i: Int) -> Color {
            let colors: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .indigo]
            return colors[i % colors.count]
        }
    }

    struct PieSlice: Shape {
        var startAngle: Angle
        var endAngle: Angle
        func path(in rect: CGRect) -> Path {
            var p = Path()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2 - 6
            p.move(to: center)
            p.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
            p.closeSubpath()
            return p
        }
    }
}


// Простой превью
#Preview {
    CleanerView()
}

// MARK: - Non-main-actor cleaning core (pure file operations)
    // MARK: - Non-main-actor cleaning core (pure file operations)
    struct CleaningCore {
        struct TrashedItem: Codable, Sendable { let originalPath: String; let trashedPath: String }
        struct CleanResult: Sendable {
            var items: Int = 0
            var bytes: Int64 = 0
            var failed: Int = 0
            var trashed: [TrashedItem] = []
            mutating func add(_ other: CleanResult) {
                items += other.items
                bytes += other.bytes
                failed += other.failed
                trashed.append(contentsOf: other.trashed)
            }
        }

        static func cleanCaches(includeHidden: Bool, riskMode: RiskMode) -> CleanResult {
            var result = CleanResult()
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            let keepDays = max(riskMode.keepDays, CleanPrefs.customKeepDays)

            let userCaches = home.appendingPathComponent("Library/Caches", isDirectory: true)
            result.add(trashChildren(of: userCaches, includeHidden: includeHidden, keepDays: keepDays))

            let containers = home.appendingPathComponent("Library/Containers", isDirectory: true)
            result.add(iterateChildren(of: containers, includeHidden: includeHidden) { appDir in
                let caches = appDir.appendingPathComponent("Data/Library/Caches", isDirectory: true)
                return trashChildren(of: caches, includeHidden: includeHidden, keepDays: keepDays)
            })

            let groups = home.appendingPathComponent("Library/Group Containers", isDirectory: true)
            result.add(iterateChildren(of: groups, includeHidden: includeHidden) { groupDir in
                let caches = groupDir.appendingPathComponent("Library/Caches", isDirectory: true)
                return trashChildren(of: caches, includeHidden: includeHidden, keepDays: keepDays)
            })
            return result
        }

        static func cleanLogs(includeHidden: Bool, riskMode: RiskMode) -> CleanResult {
            var result = CleanResult()
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            let keepDays = max(riskMode.keepDays, CleanPrefs.customKeepDays)

            let userLogs = home.appendingPathComponent("Library/Logs", isDirectory: true)
            result.add(trashChildren(of: userLogs, includeHidden: includeHidden, keepDays: keepDays))

            let diag = home.appendingPathComponent("Library/DiagnosticReports", isDirectory: true)
            result.add(trashChildren(of: diag, includeHidden: includeHidden, keepDays: keepDays))

            let crashes = home.appendingPathComponent("Library/Application Support/CrashReporter", isDirectory: true)
            result.add(trashChildren(of: crashes, includeHidden: includeHidden, keepDays: keepDays))

            let containers = home.appendingPathComponent("Library/Containers", isDirectory: true)
            result.add(iterateChildren(of: containers, includeHidden: includeHidden) { appDir in
                let logs = appDir.appendingPathComponent("Data/Library/Logs", isDirectory: true)
                return trashChildren(of: logs, includeHidden: includeHidden, keepDays: keepDays)
            })
            return result
        }

        static func cleanBrowserCaches(includeHidden: Bool, riskMode: RiskMode) -> CleanResult {
            var result = CleanResult()
            let fm = FileManager.default
            let home = fm.homeDirectoryForCurrentUser
            let keepDays = max(riskMode.keepDays, CleanPrefs.customKeepDays)

            // Safari caches
            let safariCaches = home.appendingPathComponent("Library/Caches/com.apple.Safari", isDirectory: true)
            result.add(trashChildren(of: safariCaches, includeHidden: includeHidden, keepDays: keepDays))

            // Chrome caches
            let chromeCaches = home.appendingPathComponent("Library/Caches/Google/Chrome", isDirectory: true)
            result.add(trashChildren(of: chromeCaches, includeHidden: includeHidden, keepDays: keepDays))

            // Edge caches
            let edgeCaches = home.appendingPathComponent("Library/Caches/Microsoft Edge", isDirectory: true)
            result.add(trashChildren(of: edgeCaches, includeHidden: includeHidden, keepDays: keepDays))

            // Firefox caches (profile dirs)
            let firefoxProfiles = home.appendingPathComponent("Library/Caches/Firefox/Profiles", isDirectory: true)
            result.add(iterateChildren(of: firefoxProfiles, includeHidden: includeHidden) { profileDir in
                return trashChildren(of: profileDir, includeHidden: includeHidden, keepDays: keepDays)
            })

            return result
        }

        // Traverse direct children of a directory and apply an action
        private static func iterateChildren(of dir: URL, includeHidden: Bool, action: (URL) -> CleanResult) -> CleanResult {
            var aggregate = CleanResult()
            let fm = FileManager.default
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue {
                let opts: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
                if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: opts) {
                    for url in items {
                        // Skip excluded paths entirely
                        if ExclusionsMatcher.shouldExclude(url: url) { continue }
                        aggregate.add(action(url))
                    }
                }
            }
            return aggregate
        }

        // Trash the contents of a directory (not the directory itself)
        private static func trashChildren(of dir: URL, includeHidden: Bool, keepDays: Int) -> CleanResult {
            var result = CleanResult()
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return result }
            let opts: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: opts) else { return result }

            let cutoff: Date? = keepDays > 0 ? Calendar.current.date(byAdding: .day, value: -keepDays, to: Date()) : nil

            for item in items {
                // Respect exclusions (whitelist)
                if ExclusionsMatcher.shouldExclude(url: item) { continue }

                if let cutoff,
                   let v = try? item.resourceValues(forKeys: [.contentModificationDateKey]),
                   let m = v.contentModificationDate, m > cutoff { continue }

                let sz = approximateSize(of: item, includeHidden: includeHidden)
                do {
                    var trashedURL: NSURL?
                    try fm.trashItem(at: item, resultingItemURL: &trashedURL)
                    result.items += 1
                    result.bytes += sz
                    if let t = trashedURL as URL? {
                        result.trashed.append(TrashedItem(originalPath: item.path, trashedPath: t.path))
                    }
                } catch {
                    result.failed += 1
                }
            }
            return result
        }

        // Approximate size of file or directory by enumerating files
        private static func approximateSize(of url: URL, includeHidden: Bool) -> Int64 {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }

            if !isDir.boolValue {
                if let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) {
                    return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                }
                return 0
            }

            var total: Int64 = 0
            let opts: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
            if let en = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey], options: opts) {
                for case let f as URL in en {
                    if let values = try? f.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]), values.isRegularFile == true {
                        total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                    }
                }
            }
            return total
        }
    }

// MARK: - Uninstall preview helpers (using Features.swift types)
private extension CleanerView {
    // Build PreviewNode tree: App → Kind → Path
    func buildTree(appName: String, bundleID: String?, items: [(URL, Int64)]) -> [PreviewNode] {
        enum Kind: String, CaseIterable { case caches = "Caches", logs = "Logs", support = "Application Support", containers = "Containers", groups = "Group Containers", other = "Other" }
        func kind(for path: String) -> Kind {
            if path.contains("/Library/Caches") { return .caches }
            if path.contains("/Library/Logs") { return .logs }
            if path.contains("/Library/Application Support") { return .support }
            if path.contains("/Library/Containers") { return .containers }
            if path.contains("/Library/Group Containers") { return .groups }
            return .other
        }

        var buckets: [Kind: [PreviewNode]] = [:]
        for (url, size) in items {
            let k = kind(for: url.path)
            // Лист — полный путь в title, размер установлен
            buckets[k, default: []].append(PreviewNode(title: url.path, size: size, selected: true, children: nil))
        }
        // Сортируем листья по размеру у каждой группы
        for k in buckets.keys { buckets[k]?.sort { $0.totalSize > $1.totalSize } }

        // Узлы Kind уровнем выше
        var kindNodes: [PreviewNode] = []
        for k in Kind.allCases {
            if let rows = buckets[k], !rows.isEmpty {
                kindNodes.append(PreviewNode(title: k.rawValue, size: 0, selected: true, children: rows))
            }
        }
        guard !kindNodes.isEmpty else { return [] }

        // Верхний узел — само приложение
        let top = PreviewNode(title: appName.hasSuffix(".app") ? appName : appName + ".app",
                              detail: bundleID,
                              size: 0,
                              selected: true,
                              children: kindNodes)
        return [top]
    }

    // Собираем выбранные листья (paths) из дерева
    func flattenSelectedLeaves(_ nodes: [PreviewNode]) -> [PreviewNode] {
        var out: [PreviewNode] = []
        func visit(_ n: PreviewNode) {
            guard n.selected else { return }
            if let kids = n.children, !kids.isEmpty {
                for c in kids { visit(c) }
            } else {
                out.append(n)
            }
        }
        for n in nodes { visit(n) }
        return out
    }

    // Выполнить удаление по дереву с прогрессом и ETA для SmartProgressButton
    func runUninstallFromPreview() {
        let leaves = flattenSelectedLeaves(previewNodes)
        guard !leaves.isEmpty else { return }
        uninstallBtnState = .running(progress: 0, eta: 0)
        isWorking = true
        status = "Удаляю выбранные элементы…"
        let start = Date()

        Task.detached {
            let fm = FileManager.default
            var trashed: [CleaningCore.TrashedItem] = []
            var deletedBytes: Int64 = 0
            var deletedFiles: Int = 0
            var failedCount: Int = 0
            let totalCount = leaves.count

            for (idx, leaf) in leaves.enumerated() {
                let url = URL(fileURLWithPath: leaf.title)
                let size = leaf.totalSize
                do {
                    var t: NSURL?
                    try fm.trashItem(at: url, resultingItemURL: &t)
                    deletedBytes += size
                    deletedFiles += 1
                    if let tt = t as URL? {
                        trashed.append(.init(originalPath: url.path, trashedPath: tt.path))
                    }
                } catch {
                    failedCount += 1
                }
                // Обновляем прогресс/ETA (сглажённая оценка по среднему времени на элемент)
                let completed = idx + 1
                let progress = Double(completed) / Double(max(1, totalCount))
                let elapsed = Date().timeIntervalSince(start)
                let avgPerItem = elapsed / Double(max(1, completed))
                let remaining = Double(max(0, totalCount - completed)) * avgPerItem
                await MainActor.run {
                    uninstallBtnState = .running(progress: progress, eta: remaining)
                }
            }

            let duration = Date().timeIntervalSince(start)

            let finalDeletedBytes = deletedBytes
            let finalDeletedFiles = deletedFiles
            let finalFailedCount = failedCount
            let finalTrashed = trashed
            let finalDuration = duration

            await MainActor.run {
                isWorking = false
                lastResult = CleaningCore.CleanResult(items: finalDeletedFiles, bytes: finalDeletedBytes, failed: finalFailedCount, trashed: finalTrashed)
                var text = "Удалено \(finalDeletedFiles) объектов, освобождено \(formatBytes(finalDeletedBytes)). Все перемещено в Корзину."
                if finalFailedCount > 0 { text += " Не удалось переместить \(finalFailedCount) элементов." }
                status = text
                undoItems = finalTrashed
                if !finalTrashed.isEmpty { startUndoCountdown(seconds: 15 * 60) }
                CleanMetrics.log(bytes: finalDeletedBytes, kind: .uninstall)
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    uninstallBtnState = .success(bytes: finalDeletedBytes, files: finalDeletedFiles, duration: finalDuration)
                }
            }
        }
    }
}

struct PermissionHintView: View {
    @Binding var show: Bool
    @Binding var hidePermanently: Bool
    var accent: Color

    var body: some View {
        content
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(accent)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 4) {
                Text("Разрешите доступ")
                    .font(.headline)
                Text("macOS может показать запрос на доступ к данным других приложений. Нажмите «Разрешить», чтобы BroomCleaner Pro корректно находил и удалял кэш и логи.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Toggle("Больше не показывать", isOn: $hidePermanently)
                        .toggleStyle(.checkbox)
                        .onChange(of: hidePermanently) { v in
                            if v { withAnimation(.easeOut(duration: 0.15)) { show = false } }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button { withAnimation(.easeOut(duration: 0.15)) { show = false } } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Скрыть подсказку.")
        }
        .accessibilityElement(children: .combine)
    }
}

struct FeaturePillView: View {
    var title: String
    var systemImage: String
    var accent: Color
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).imageScale(.medium)
            Text(title)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(
            Capsule(style: .continuous).fill(accent.opacity(0.12))
        )
    }
}

struct StatRow<T: CustomStringConvertible>: View {
    var value: T
    var label: String
    var systemImage: String
    var tint: Color
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: String(describing: value))
                    .font(.headline)
                    .contentTransition(.numericText())
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(String(describing: value))")
    }
}

struct CelebrationOverlay: View {
    var accent: Color
    @State private var animate = false

    var body: some View {
        ZStack {
            // Pulsing rings
            Circle()
                .stroke(accent.opacity(0.35), lineWidth: 6)
                .scaleEffect(animate ? 1.4 : 0.6)
                .opacity(animate ? 0.0 : 1.0)
                .animation(.easeOut(duration: 0.9), value: animate)
            Circle()
                .stroke(accent.opacity(0.25), lineWidth: 4)
                .scaleEffect(animate ? 1.2 : 0.6)
                .opacity(animate ? 0.0 : 1.0)
                .animation(.easeOut(duration: 0.9).delay(0.05), value: animate)

            // Checkmark in a soft circle
            Circle()
                .fill(accent.opacity(0.20))
                .frame(width: 84, height: 84)
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(accent)
                        .scaleEffect(animate ? 1.0 : 0.6)
                        .opacity(animate ? 1.0 : 0.0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: animate)
                )
                .shadow(color: accent.opacity(0.25), radius: 10, x: 0, y: 6)
        }
        .onAppear { animate = true }
    }
}

struct CleaningControlsView: View {
    @Binding var riskModeRaw: String
    @Binding var includeHidden: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.fill").imageScale(.small)
                Picker("Режим", selection: $riskModeRaw) {
                    ForEach(RiskMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(0.05)))

            Toggle("Скрытые файлы", isOn: $includeHidden)
                .toggleStyle(.checkbox)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct MetricsFooterView: View {
    @Binding var showReport: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                let month = CleanMetrics.monthTotal()
                Button { showReport = true } label: {
                    Label("Освобождено за месяц: \(formatBytesStatic(month))", systemImage: "chart.line.uptrend.xyaxis")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                CleanerView.MetricsSparkline(series: CleanMetrics.seriesLastDays())
                    .frame(width: 160, height: 20)
            }

            Group {
                #if os(macOS)
                if #available(macOS 26.0, *) {
                    CleanerView.MetricsPie(slices: CleanMetrics.topSources(kinds: [.cache, .logs]))
                        .frame(height: 120)
                        .glassEffect(in: .rect(cornerRadius: 12))
                } else {
                    CleanerView.MetricsPie(slices: CleanMetrics.topSources(kinds: [.cache, .logs]))
                        .frame(height: 120)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
                }
                #else
                CleanerView.MetricsPie(slices: CleanMetrics.topSources(kinds: [.cache, .logs]))
                    .frame(height: 120)
                #endif
            }
        }
        .padding(10)
    }

    private func formatBytesStatic(_ bytes: Int64) -> String {
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

struct AccentPickerSidebar: View {
    var palette: [String]
    @Binding var selected: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(palette, id: \.self) { name in
                Button {
                    selected = name
                } label: {
                    Circle()
                        .fill(color(for: name))
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(selected == name ? 0.9 : 0.25), lineWidth: selected == name ? 2 : 1)
                        )
                        .shadow(color: color(for: name).opacity(selected == name ? 0.35 : 0.0), radius: selected == name ? 4 : 0)
                        .overlay(
                            Circle()
                                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                        .accessibilityLabel(localizedName(for: name))
                        .accessibilityAddTraits(selected == name ? .isSelected : [])
                }
                .buttonStyle(.plain)
                .help(localizedName(for: name))
            }
        }
    }

    private func color(for name: String) -> Color {
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
}
