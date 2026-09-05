import AVFoundation
import OSLog

/// 随身翻译的俄语朗读（AVSpeechSynthesizer 复用，绝不引入云端 TTS）。
///
/// 与 `TermSpeech` 的差异（本类补齐的互斥缺口）：
/// - 朗读永远使用**去除 U+0301 组合重音后的普通俄语**（重音符号会
///   干扰系统 TTS 的发音）；
/// - 朗读前检查 ru-RU voice 是否存在，缺失时明确报告（不静默失败）；
/// - 新一句开始时停止上一句；
/// - 开始麦克风收音前调用方必须先 `stop()`（InterpreterViewModel
///   与课堂的互斥协议）；
/// - 音频中断后不自动恢复。
@MainActor
final class InterpreterSpeechService: NSObject, AVSpeechSynthesizerDelegate {
    static let logger = Logger(subsystem: "com.livetranslate.ios", category: "interpreter-tts")

    private let synthesizer = AVSpeechSynthesizer()
    /// 正在朗读的文本（停止/重播用）。
    private(set) var speakingText: String?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// ru-RU voice 是否可用（不可用时 UI 明确提示，不反复弹设置）。
    static var russianVoiceAvailable: Bool {
        AVSpeechSynthesisVoice(language: "ru-RU") != nil
    }

    /// 朗读普通俄语（内部自动去除重音符号）。新一句开始时停止上一句。
    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        stop()
        let plain = RussianStressValidator.stripStress(text)
        let utterance = AVSpeechUtterance(string: plain)
        utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
        utterance.rate = 0.45
        speakingText = plain
        synthesizer.speak(utterance)
        Self.logger.info("tts speak (\(plain.count, privacy: .public) chars)")
    }

    /// 重播最近一句。
    func replay() {
        guard let text = speakingText else { return }
        speak(text)
    }

    /// 停止朗读（开始收音、结束会话、切换账号前必须调用）。
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        speakingText = nil
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    // MARK: - AVSpeechSynthesizerDelegate

    /// 音频中断后不自动恢复 —— didCancel 诚实清空状态。
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            speakingText = nil
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            speakingText = nil
        }
    }
}
