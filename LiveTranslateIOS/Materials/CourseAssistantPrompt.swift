import Foundation

/// Prompt construction for the course assistant (问这门课). Pure
/// functions. The assistant is NOT a chatbot: every answer must ground
/// in the numbered sources the local retrieval selected, cite them as
/// [n], and refuse — explicitly — when the sources do not contain the
/// answer.
enum CourseAssistantPrompt {
    /// The scope a question was asked in.
    enum ScopeLabel: String, Sendable {
        case course
        case material
        case session
        case page

        var promptLine: String {
            switch self {
            case .course: return "提问范围：整门课程（资料、课堂转录与笔记、黑板图片、学习整理、术语与任务）"
            case .material: return "提问范围：一份课程资料"
            case .session: return "提问范围：一堂课"
            case .page: return "提问范围：资料的某一页及其相邻页"
            }
        }
    }

    /// One numbered source in the prompt (built from retrieval hits).
    struct SourceLine: Sendable, Equatable {
        var number: Int
        var label: String
        var text: String
    }

    /// A past turn for follow-up context (bounded by the caller).
    struct HistoryTurn: Sendable, Equatable {
        var isUser: Bool
        var text: String
    }

    static func systemPrompt() -> String {
        """
        你是课程学习助手。用户是在俄罗斯大学留学的中国学生。你会收到从该学生的课程资料、课堂转录、笔记、黑板图片理解和学习整理中检索出的若干段带编号 [n] 的材料片段。请回答用户的问题。

        要求：
        - 用中文回答；涉及俄语原文时保留俄语并给出中文含义。
        - 回答中的每个事实性内容都必须用 [n] 标注来源编号；只能使用输入中出现的编号。
        - 如果提供的材料不足以回答问题，必须明确回答「当前资料中没有找到足够依据」，并说明检索到的材料大致涉及什么；绝不要编造来源或编号。
        - 不要把整段材料照抄进回答；概括、解释、必要时引用原文。
        - 涉及公式时用文字或 LaTeX 描述，并标注其来源页码对应的编号。
        """
    }

    static func userPrompt(
        scope: ScopeLabel,
        sources: [SourceLine],
        history: [HistoryTurn],
        question: String
    ) -> String {
        var lines: [String] = []
        lines.append(scope.promptLine)
        lines.append("")
        lines.append("检索到的材料片段：")
        for source in sources {
            lines.append("[\(source.number)] \(source.label)")
            lines.append("    " + source.text.replacingOccurrences(of: "\n", with: "\n    "))
        }
        if !history.isEmpty {
            lines.append("")
            lines.append("此前对话（仅供理解指代，不必复述）：")
            for turn in history {
                lines.append("\(turn.isUser ? "学生" : "助手")：\(turn.text)")
            }
        }
        lines.append("")
        lines.append("学生的问题：\(question)")
        return lines.joined(separator: "\n")
    }

    /// The honest no-evidence answer (saved verbatim when retrieval
    /// found nothing — no model request is made in that case).
    static let noEvidenceAnswer = """
    当前资料中没有找到足够依据。

    我在课程资料、课堂转录、笔记和图片理解中没有检索到与这个问题相关的内容。你可以：
    - 换个说法再问一次；
    - 把相关资料导入课程资料库后再问；
    - 确认提问范围（目前可能限定在某份资料或某堂课内）。
    """
}
