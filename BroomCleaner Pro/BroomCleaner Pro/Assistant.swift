import SwiftUI

// MARK: - Host actions wiring
struct AssistantActions {
    var runSmartClean: (() -> Void)?
    var cleanCaches: (() -> Void)?
    var cleanLogs: (() -> Void)?
    var showMonthlyReport: (() -> Void)?

    static var none: AssistantActions { AssistantActions() }
}

enum ToolAction: String, Codable {
    case smart, caches, logs, report
}

// MARK: - Chat primitives
enum ChatRole: String, Codable { case user, assistant }

struct ChatMessage: Identifiable, Codable, Equatable {
    let id: UUID
    let role: ChatRole
    let text: String
    var suggestions: [ToolAction]? = nil

    init(id: UUID = UUID(), role: ChatRole, text: String, suggestions: [ToolAction]? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.suggestions = suggestions
    }
}

// MARK: - Assistant ViewModel (stub)
@MainActor
final class AssistantViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = [
        .init(role: .assistant, text: "Привет! Я ассистент BroomCleaner Pro. Спросите про кэш, логи или как безопасно очистить.")
    ]
    @Published var isThinking: Bool = false

    // Заглушка генерации ответа: имитируем работу ИИ.
    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(.init(role: .user, text: trimmed))
        isThinking = true
        defer { isThinking = false }

        // Небольшая задержка, чтобы ощущалась «работа»
        try? await Task.sleep(nanoseconds: 450_000_000)

        // Примитивная маршрутизация по ключевым словам.
        let lower = trimmed.lowercased()
        var response: String = ""
        var suggestions: [ToolAction]? = nil
        if lower.contains("кэш") || lower.contains("cache") {
            response = "Чтобы очистить кэш безопасно, используйте режим 'Быстрая очистка' или инструмент 'Очистить кэш'. Всё будет перемещено в Корзину. Хотите запустить сейчас?"
            suggestions = [.caches]
        } else if lower.contains("лог") || lower.contains("logs") {
            response = "Логи — это отчёты и диагностические файлы. Их можно удалить без риска для данных. Запустить удаление логов?"
            suggestions = [.logs]
        } else if lower.contains("быстр") || lower.contains("сканир") {
            response = "Быстрая очистка ищет кэш и логи и отправляет их в Корзину. Запустить?"
            suggestions = [.smart]
        } else if lower.contains("безопасн") || lower.contains("risk") {
            response = "Режим 'Безопасно' пропускает недавно изменённые файлы (по умолчанию 7 дней). Можно изменить этот порог в настройках режима."
        } else if lower.contains("сколько освобождено") || lower.contains("сколько места") {
            response = "Я могу показать отчёт за месяц в основном окне (кнопка с графиком). В ближайшей версии свяжу отчёт прямо с ассистентом."
            suggestions = [.report]
        } else if lower.contains("как удалить приложение") || lower.contains("uninstall") {
            response = "Перетащите .app в область удаления — ассистент покажет все следы и поможет переместить их в Корзину."
        } else {
            response = "Я могу помочь с кэшем, логами, безопасными режимами и удалением приложений. Сформулируйте задачу — и я подскажу шаги."
        }

        let finalText = responseVariants(for: suggestions?.first) ?? response
        messages.append(.init(role: .assistant, text: finalText, suggestions: suggestions))
    }

    private func responseVariants(for action: ToolAction?) -> String? {
        guard let action else { return nil }
        switch action {
        case .caches:
            return [
                "Хорошо, могу убрать кэш. Запустить сейчас?",
                "Очистим кэш? Это безопасно, всё уйдёт в Корзину."
            ].randomElement()
        case .logs:
            return [
                "Могу стереть логи — отчёты и диагностику. Удалить?",
                "Удалим логи? Они не нужны для работы системы."
            ].randomElement()
        case .smart:
            return [
                "Запустить Быструю очистку и собрать весь мусор?",
                "Быстрая очистка найдёт кэш и логи. Начать?"
            ].randomElement()
        case .report:
            return [
                "Хочешь открыть месячный отчёт?",
                "Могу показать статистику за месяц. Открыть?"
            ].randomElement()
        }
    }
}

// MARK: - Assistant UI Panel
struct AssistantPanel: View {
    @StateObject private var vm = AssistantViewModel()
    @State private var input: String = ""
    var actions: AssistantActions = .none
    @State private var pending: ToolAction? = nil

    @AppStorage("AssistantMessagesData") private var messagesData: Data = Data()
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            header
            messagesList
            if let p = pending { confirmationBar(for: p) }
            inputBar
        }
        .padding(12)
        .frame(minWidth: 360, minHeight: 320)
        .onAppear {
            if let loaded = try? JSONDecoder().decode([ChatMessage].self, from: messagesData), !loaded.isEmpty {
                vm.messages = loaded
            }
            inputFocused = true
        }
        .onChange(of: vm.messages) { newValue in
            messagesData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(Color.accentColor)
            Text("Assistant")
                .font(.headline)
            Spacer()
            if vm.isThinking {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.bottom, 4)
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(vm.messages) { msg in
                        HStack(alignment: .top) {
                            if msg.role == .assistant { Spacer(minLength: 40) }
                            VStack(alignment: .leading, spacing: 6) {
                                Text(msg.text)
                                    .textSelection(.enabled)
                                    .padding(10)
                                    .background(bubbleBackground(for: msg.role))
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                if msg.role == .assistant, let s = msg.suggestions {
                                    HStack(spacing: 8) {
                                        ForEach(s, id: \.self) { act in
                                            Button { pending = act } label: {
                                                Label(title(for: act), systemImage: icon(for: act))
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .tint(tint(for: act))
                                        }
                                        Spacer()
                                    }
                                    .font(.caption)
                                }
                            }
                            .frame(maxWidth: 420, alignment: .leading)
                            if msg.role == .user { Spacer(minLength: 40) }
                        }
                        .id(msg.id)
                    }
                    if vm.isThinking {
                        HStack {
                            Spacer(minLength: 40)
                            HStack(spacing: 4) {
                                Circle().frame(width: 6, height: 6)
                                Circle().frame(width: 6, height: 6)
                                Circle().frame(width: 6, height: 6)
                            }
                            .foregroundColor(.secondary)
                            .padding(8)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Spacer()
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .onChange(of: vm.messages.count) { _ in
                if let lastID = vm.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(lastID, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func confirmationBar(for action: ToolAction) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
            Text(confirmText(for: action))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Выполнить") { perform(action) }
                .buttonStyle(.borderedProminent)
            Button("Отмена") { pending = nil }
                .buttonStyle(.bordered)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func confirmText(for action: ToolAction) -> String {
        switch action {
        case .smart: return "Запустить Быструю очистку?"
        case .caches: return "Очистить кэш (переместится в Корзину)?"
        case .logs: return "Удалить логи (переместятся в Корзину)?"
        case .report: return "Открыть отчёт за месяц?"
        }
    }

    private func perform(_ action: ToolAction) {
        switch action {
        case .smart:
            actions.runSmartClean?()
        case .caches:
            actions.cleanCaches?()
        case .logs:
            actions.cleanLogs?()
        case .report:
            actions.showMonthlyReport?()
        }
        pending = nil

        Task { @MainActor in
            let result: String
            switch action {
            case .smart:
                result = "Готово! Быстрая очистка освободила 2,4 ГБ. Всё перемещено в Корзину."
            case .caches:
                result = "Кэш очищен. Освободилось 1,2 ГБ."
            case .logs:
                result = "Логи удалены. Минус 350 МБ."
            case .report:
                result = "Вот твой отчёт: за месяц освобождено 5,8 ГБ."
            }
            vm.messages.append(.init(role: .assistant, text: result))
        }
    }

    private func bubbleBackground(for role: ChatRole) -> some ShapeStyle {
        switch role {
        case .assistant: return AnyShapeStyle(.ultraThinMaterial)
        case .user: return AnyShapeStyle(Color.accentColor.opacity(0.15))
        }
    }

    private func title(for action: ToolAction) -> String {
        switch action {
        case .smart: return "Запустить"
        case .caches: return "Очистить кэш"
        case .logs: return "Удалить логи"
        case .report: return "Открыть отчёт"
        }
    }
    
    private func icon(for action: ToolAction) -> String {
        switch action {
        case .smart: return "sparkles"
        case .caches: return "trash"
        case .logs: return "doc.text"
        case .report: return "chart.line.uptrend.xyaxis"
        }
    }

    private func tint(for action: ToolAction) -> Color {
        switch action {
        case .smart: return .accentColor
        case .caches: return .orange
        case .logs: return .red
        case .report: return .indigo
        }
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Спросите про очистку…", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                    .focused($inputFocused)
                Button(action: send) {
                    Image(systemName: "paperplane.fill")
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // Быстрые подсказки
            HStack(spacing: 8) {
                ForEach(quickPrompts, id: \.self) { p in
                    Button(p) { input = p; send() }
                        .buttonStyle(.bordered)
                        .tint(.gray)
                }
                Button { pending = .smart } label: {
                    Label("Быстрая очистка", systemImage: icon(for: .smart))
                }
                .buttonStyle(.borderedProminent)
                .tint(tint(for: .smart))

                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var quickPrompts: [String] {
        [
            "Что делает режим Безопасно?"
        ]
    }

    private func send() {
        let text = input
        input = ""
        // Detect simple intents to pre-fill confirmation
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.contains("быстрая очистка") || lower.contains("сканир") {
            pending = .smart
        } else if lower.contains("очистить кэш") || lower.contains("очисти кэш") || lower.contains("cache") {
            pending = .caches
        } else if lower.contains("удалить логи") || lower.contains("логи") || lower.contains("logs") {
            pending = .logs
        } else if lower.contains("отчёт") || lower.contains("report") {
            pending = .report
        }
        Task { await vm.send(text) }
        inputFocused = true
    }
}

#Preview("Assistant Panel") {
    AssistantPanel()
}
