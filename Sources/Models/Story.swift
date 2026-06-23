import Foundation
import QwenVoiceCore

/// A short, static story for the Story Kingdom (故事王国) surface. The text is
/// rendered through the regular Custom Voice generation path (streaming TTS)
/// using the speaker / language / tone the user picked on the page, so a
/// `Story` is purely the script + a little presentation metadata — it carries
/// no engine state of its own.
struct Story: Identifiable, Equatable {
    let id: String
    /// Short headline shown in the list row.
    let title: String
    /// One-line teaser under the title.
    let subtitle: String
    /// SF Symbol shown beside the title.
    let iconName: String
    /// The script handed to the engine when the user taps play.
    let text: String
    /// When set, picking a story can nudge the language selector toward the
    /// story's natural language. `nil` (or `.auto`) leaves the user's choice
    /// untouched.
    let suggestedLanguage: Qwen3SupportedLanguage?

    init(
        id: String,
        title: String,
        subtitle: String,
        iconName: String = "book.closed",
        text: String,
        suggestedLanguage: Qwen3SupportedLanguage? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.iconName = iconName
        self.text = text
        self.suggestedLanguage = suggestedLanguage
    }
}

extension Story {
    /// The starter library. These are intentionally short so a tap renders a
    /// complete take quickly on constrained Macs.
    static let sample: [Story] = [
        Story(
            id: "moonlit-rabbit",
            title: "月光下的小兔子",
            subtitle: "一只兔子和它的影子",
            iconName: "moon.stars",
            text: """
            夜深了，月亮把森林照得像撒了一层银粉。小兔子蹦蹦跳跳地出门，发现地上多了一只长长的影子。
            它转过身，影子也转过身；它跳起来，影子也跟着跳。小兔子笑了：原来在这安静的夜里，连影子都愿意陪它一起玩耍。
            """,
            suggestedLanguage: .chinese
        ),
        Story(
            id: "lighthouse-keeper",
            title: "The Lighthouse Keeper",
            subtitle: "A small light against a big sea",
            iconName: "sailboat",
            text: """
            Every evening the old keeper climbed the spiral stairs and lit the great lamp. The sea was wide and dark, \
            but the light reached farther than he could ever walk. One stormy night a small boat found its way home \
            by that steady glow, and the keeper smiled, knowing that even a single light can guide someone through the dark.
            """,
            suggestedLanguage: .english
        ),
        Story(
            id: "curious-fox",
            title: "好奇的小狐狸",
            subtitle: "为什么星星会眨眼？",
            iconName: "sparkles",
            text: """
            小狐狸躺在草地上，盯着满天的星星看了很久。它问妈妈：“星星为什么会眨眼睛呀？”
            妈妈轻轻地说：“因为它们离我们很远很远，光要走很久才能到达这里。眨眼，是它们在跟我们说晚安。”
            小狐狸点点头，闭上眼睛，也在心里对星星说了一声晚安。
            """,
            suggestedLanguage: .chinese
        ),
        Story(
            id: "paper-airplane",
            title: "The Paper Airplane",
            subtitle: "A wish that learned to fly",
            iconName: "paperplane",
            text: """
            A child folded a wish into a paper airplane and threw it from the rooftop. The wind caught it, lifted it \
            over the rooftops, past the tallest tree, and out toward the hills. The child never saw where it landed, \
            but somewhere far away, someone found it and smiled — and that was enough.
            """,
            suggestedLanguage: .english
        ),
    ]
}
