import Foundation

/// Single source of truth for the Voice Design brief product copy + limits,
/// shared by the iOS brief sheet (`IOSVoiceDesignBriefSheet`) and the macOS
/// inline editor (`VoiceBriefEditor`).
enum VoiceDesignBriefCatalog {
    /// Voice Design BRIEF (the voice DESCRIPTION) limit — deliberately
    /// decoupled from the spoken-script limit. Research on the official
    /// Qwen3-TTS VoiceDesign docs found no model-imposed description cap for
    /// the open-weights model; the hosted API caps voice_prompt at 2048 chars,
    /// and official example descriptions are short (one dense sentence,
    /// ~21–160 chars). 500 fits 2–3 dense sentences with headroom while
    /// discouraging paragraph-length rambling the examples suggest is
    /// unnecessary.
    static let descriptionLimit = 500

    /// Research-aligned (official Qwen3-TTS VoiceDesign guidance): each brief
    /// combines several dimensions from the official voice-design table —
    /// gender, age, pitch, pace, emotion, timbre, and purpose/use-case — in one
    /// dense sentence, the shape the model's own example descriptions use.
    /// The last four mirror official example archetypes (documentary narrator,
    /// fast upbeat commercial voice, animation child voice, and the
    /// persona-plus-delivery-mechanics teenager from the design-then-clone
    /// example). Accent wording is a flavor hint, not a guarantee — instruct
    ///-driven accent/dialect control is unreliable on the open checkpoints.
    ///
    /// Always name a **gender** and, when pitch matters, a **concrete register**
    /// ("low, bass-resonant" — not just "deep"). Voice Design samples a fresh
    /// voice per call (no fixed speaker, talker temp 0.9), so an under-specified
    /// brief lets it sample a higher or different-gender voice — a gender-less
    /// "deep narrator" can come out high-pitched. Concrete, gendered defaults
    /// keep that tail tight.
    static let startingPoints = [
        "一位低沉男声旁白，温暖、有低频共鸣，带轻微英式口音。",
        "一位明亮的年轻女声，充满活力，像日常对话一样自然。",
        "一位沙哑低沉的年长男声，语速缓慢、亲密，像深夜电台。",
        "一位柔和带气声的年轻女声，温柔且让人安心。",
        "一位沉稳的中年男声，语速慢，音色深沉有磁性，适合纪录片旁白。",
        "一位活泼年轻女声，语速快、语调上扬，适合轻快的产品视频。",
        "一个约八岁、可爱又有点调皮的童声，适合动画角色。",
        "一位少年男声，男高音区，逐渐变得自信，但紧张时元音仍会收紧。",
    ]

    static let placeholder = "一位温暖、低沉、有共鸣的男声旁白，带轻微英式口音。"
}
