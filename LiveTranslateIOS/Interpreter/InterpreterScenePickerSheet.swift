import SwiftUI

/// 场景选择 + 临时背景。场景只影响术语倾向、礼貌程度、快捷问题与
/// AI prompt 背景 —— 不硬编码翻译结果。背景必须在界面中可见、可
/// 编辑、可清除，不隐式长期携带到其他会话。
struct InterpreterScenePickerSheet: View {
    @Binding var scene: InterpreterScene
    @Binding var contextNote: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("办事场景") {
                    ForEach(InterpreterScene.allCases) { candidate in
                        Button {
                            scene = candidate
                        } label: {
                            HStack {
                                Image(systemName: candidate.symbol)
                                    .foregroundStyle(scene == candidate ? LTColors.accentCyan : LTColors.textTertiary)
                                Text(candidate.displayName)
                                    .foregroundStyle(LTColors.textPrimary)
                                Spacer()
                                if scene == candidate {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(LTColors.accentCyan)
                                }
                            }
                        }
                        .accessibilityLabel(candidate.displayName)
                    }
                }
                Section {
                    TextField(
                        "临时背景，例如：我是莫斯科国立大学留学生",
                        text: $contextNote, axis: .vertical
                    )
                    .lineLimit(2...4)
                } header: {
                    Text("临时背景")
                } footer: {
                    Text("仅用于本次对话的语境理解，不会写入其他会话；保存后随对话一起同步。")
                }
            }
            .navigationTitle("场景与背景")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
