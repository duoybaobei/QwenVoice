import Foundation
import QwenVoiceCore

/// A fixed, curated story-writing preset for the Story Kingdom (故事王国) writer.
///
/// The writer intentionally does **not** accept free-form user prompts: a
/// `StoryTheme` is the only way to steer generation. Each theme carries a fixed
/// one-line user prompt and the natural narration language of the stories it
/// tends to produce, so the TTS read-aloud path can pick a sensible default.
/// The child-safe system prompt (`StoryTheme.systemPrompt`) is shared across all
/// themes and is the real safety boundary — it locks output to a single short,
/// age-appropriate story body with no extra commentary.
struct StoryTheme: Identifiable, Hashable, Sendable {

    let id: String
    /// Short label shown on the theme chip (e.g. "睡前故事").
    let title: String
    /// One-line teaser under the title.
    let subtitle: String
    /// SF Symbol shown beside the title.
    let iconName: String
    /// The fixed user-side prompt handed to the model for this theme. Kept short
    /// — the system prompt carries the real constraints.
    let prompt: String
    /// The language stories in this theme are written in by default, so the TTS
    /// narration can pick a matching speaker/language. `nil` leaves the user's
    /// current selection untouched.
    let suggestedLanguage: Qwen3SupportedLanguage?

    init(
        id: String,
        title: String,
        subtitle: String,
        iconName: String,
        prompt: String,
        suggestedLanguage: Qwen3SupportedLanguage? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.iconName = iconName
        self.prompt = prompt
        self.suggestedLanguage = suggestedLanguage
    }
}

extension StoryTheme {

    /// The single, fixed child-safe system prompt shared by every theme.
    ///
    /// This is the safety boundary for the writer: it pins the model to one
    /// age-appropriate story in the requested language, with no reasoning
    /// traces, no preamble, and no free-form content. Themes only adjust *what*
    /// the story is about, never how safe it is.
    ///
    /// The model is asked for a tiny structured header (title + one-line
    /// synopsis) followed by the story body. `StoryTextGenerator` parses the
    /// header so the list can show a real story name + description, and only
    /// the body is streamed to the child-facing surface (and later read aloud
    /// by TTS). Length is guided by spoken duration (~3 minutes) rather than a
    /// hard word count so stories stay complete and natural.
    ///
    /// Qwen3 thinking is turned off at the chat-template level
    /// (`enable_thinking: false` in `StoryTextGenerator`), so `<think>` blocks
    /// should never appear; the strip logic remains as a safety net.
    static let systemPrompt: String = """
    你是一位为儿童写故事的作家。请严格遵守以下规则，不要违反：

    1. 只写一个完整的小故事，适合 4-8 岁儿童阅读或聆听。
    2. 内容必须健康、温暖、安全：不得包含暴力、恐怖、色情、歧视、危险行为或任何不适合儿童的内容。
    3. 不要输出 <think> 标签或任何思考过程，直接输出故事。
    4. 语言：请用与用户请求相同的语言写作。用户用中文，你就用中文写；用户用英文，你就用英文写。
    5. 角色与情节围绕用户给定的主题展开，可以有 1-3 个角色，情节简单完整，有一个温和的结尾。
    6. 故事长度以朗读大约 3 分钟以内为宜，必须写完整：有开头、发展、结尾，不要在情节中途停下。

    输出格式（严格按此格式，不要加任何其它内容、不要 Markdown 标记）：
    标题：<不超过 12 个字的故事标题>
    简介：<一句话概括故事，不超过 20 个字>
    故事：
    <故事正文，不要标题、不要分章节、不要前言或结尾点评，只输出正文。>
    """

    /// The curated preset themes shown on the writer surface. Order matters —
    /// the first entry is the default selection.
    ///
    /// Themes only vary the *subject* of the story; the shared `systemPrompt`
    /// enforces length, format, and safety for all of them. New themes should
    /// stay one short sentence so the system prompt remains the real guardrail.
    static let presets: [StoryTheme] = [
        StoryTheme(
            id: "bedtime",
            title: "睡前故事",
            subtitle: "温柔的夜晚小故事",
            iconName: "moon.stars",
            prompt: "请写一个温柔的睡前小故事，帮助小朋友安心入睡。",
            suggestedLanguage: .chinese
        ),
        StoryTheme(
            id: "adventure",
            title: "冒险旅程",
            subtitle: "勇敢的小小冒险",
            iconName: "map",
            prompt: "请写一个关于小朋友或小动物勇敢冒险的短故事。",
            suggestedLanguage: .chinese
        ),
        StoryTheme(
            id: "animals",
            title: "动物朋友",
            subtitle: "森林里的小伙伴",
            iconName: "pawprint",
            prompt: "请写一个关于动物朋友们互相帮助的短故事。",
            suggestedLanguage: .chinese
        ),
        StoryTheme(
            id: "friendship",
            title: "友谊故事",
            subtitle: "关于陪伴与分享",
            iconName: "figure.2.and.child.holdinghands",
            prompt: "请写一个关于两个好朋友之间温暖友谊的短故事。",
            suggestedLanguage: .chinese
        ),
        StoryTheme(
            id: "bedtime-en",
            title: "Bedtime Tale",
            subtitle: "A gentle goodnight story",
            iconName: "moon.haze",
            prompt: "Write a gentle, calming bedtime story to help a child fall asleep.",
            suggestedLanguage: .english
        ),
        StoryTheme(
            id: "adventure-en",
            title: "Little Adventure",
            subtitle: "A brave little journey",
            iconName: "compass",
            prompt: "Write a short story about a brave little adventure.",
            suggestedLanguage: .english
        ),
    ]
}
