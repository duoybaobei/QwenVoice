import Foundation

// MARK: - Word bank

/// A single word, short phrase, or sentence the child repeats in the
/// read-along loop. `text` is both what TTS speaks and what the judge compares
/// the ASR transcript against.
struct ReadAlongWord: Identifiable, Hashable, Sendable {
    let id: String
    let text: String
    /// Optional pinyin / phonetic hint shown under the big word.
    let phonetic: String?
    let category: ReadAlongCategory.ID
    /// 1 (easy) … 3 (hard). Drives ordering within a session.
    let difficulty: Int

    init(id: String = UUID().uuidString, text: String, phonetic: String? = nil, category: ReadAlongCategory.ID, difficulty: Int = 1) {
        self.id = id
        self.text = text
        self.phonetic = phonetic
        self.category = category
        self.difficulty = difficulty
    }
}

/// A preset themed word pack. Built-in packs need zero model download so the
/// read-along loop works the moment the TTS engine is ready.
struct ReadAlongCategory: Identifiable, Hashable, Sendable {
    typealias ID = String
    let id: ID
    let title: String
    let icon: String
    let words: [ReadAlongWord]

    static let allBuiltIn: [ReadAlongCategory] = [
        .animals,
        .colors,
        .numbers,
        .dailyPhrases,
        .nurseryRhymes,
    ]

    /// 动物 Animals
    static let animals = ReadAlongCategory(
        id: "animals",
        title: "动物",
        icon: "pawprint.fill",
        words: [
            .init(text: "猫", phonetic: "māo", category: "animals", difficulty: 1),
            .init(text: "狗", phonetic: "gǒu", category: "animals", difficulty: 1),
            .init(text: "鸟", phonetic: "niǎo", category: "animals", difficulty: 1),
            .init(text: "鱼", phonetic: "yú", category: "animals", difficulty: 1),
            .init(text: "兔子", phonetic: "tù zi", category: "animals", difficulty: 2),
            .init(text: "大象", phonetic: "dà xiàng", category: "animals", difficulty: 2),
            .init(text: "猴子", phonetic: "hóu zi", category: "animals", difficulty: 2),
            .init(text: "长颈鹿", phonetic: "cháng jǐng lù", category: "animals", difficulty: 3),
        ]
    )

    /// 颜色 Colors
    static let colors = ReadAlongCategory(
        id: "colors",
        title: "颜色",
        icon: "paintpalette.fill",
        words: [
            .init(text: "红色", phonetic: "hóng sè", category: "colors", difficulty: 1),
            .init(text: "蓝色", phonetic: "lán sè", category: "colors", difficulty: 1),
            .init(text: "绿色", phonetic: "lǜ sè", category: "colors", difficulty: 1),
            .init(text: "黄色", phonetic: "huáng sè", category: "colors", difficulty: 1),
            .init(text: "黑色", phonetic: "hēi sè", category: "colors", difficulty: 2),
            .init(text: "白色", phonetic: "bái sè", category: "colors", difficulty: 2),
            .init(text: "紫色", phonetic: "zǐ sè", category: "colors", difficulty: 2),
            .init(text: "橙色", phonetic: "chéng sè", category: "colors", difficulty: 3),
        ]
    )

    /// 数字 Numbers
    static let numbers = ReadAlongCategory(
        id: "numbers",
        title: "数字",
        icon: "number.circle.fill",
        words: [
            .init(text: "一", phonetic: "yī", category: "numbers", difficulty: 1),
            .init(text: "二", phonetic: "èr", category: "numbers", difficulty: 1),
            .init(text: "三", phonetic: "sān", category: "numbers", difficulty: 1),
            .init(text: "四", phonetic: "sì", category: "numbers", difficulty: 1),
            .init(text: "五", phonetic: "wǔ", category: "numbers", difficulty: 1),
            .init(text: "六", phonetic: "liù", category: "numbers", difficulty: 2),
            .init(text: "七", phonetic: "qī", category: "numbers", difficulty: 2),
            .init(text: "八", phonetic: "bā", category: "numbers", difficulty: 2),
            .init(text: "九", phonetic: "jiǔ", category: "numbers", difficulty: 2),
            .init(text: "十", phonetic: "shí", category: "numbers", difficulty: 3),
        ]
    )

    /// 日常用语 Daily Phrases
    static let dailyPhrases = ReadAlongCategory(
        id: "daily",
        title: "日常用语",
        icon: "bubble.left.fill",
        words: [
            .init(text: "你好", phonetic: "nǐ hǎo", category: "daily", difficulty: 1),
            .init(text: "谢谢", phonetic: "xiè xiè", category: "daily", difficulty: 1),
            .init(text: "再见", phonetic: "zài jiàn", category: "daily", difficulty: 1),
            .init(text: "对不起", phonetic: "duì bù qǐ", category: "daily", difficulty: 2),
            .init(text: "没关系", phonetic: "méi guān xi", category: "daily", difficulty: 2),
            .init(text: "我爱你", phonetic: "wǒ ài nǐ", category: "daily", difficulty: 2),
            .init(text: "早上好", phonetic: "zǎo shang hǎo", category: "daily", difficulty: 2),
            .init(text: "晚安", phonetic: "wǎn ān", category: "daily", difficulty: 1),
        ]
    )

    /// 儿歌歌词句 Nursery Rhymes
    static let nurseryRhymes = ReadAlongCategory(
        id: "rhymes",
        title: "儿歌",
        icon: "music.note",
        words: [
            .init(text: "两只老虎", phonetic: "liǎng zhī lǎo hǔ", category: "rhymes", difficulty: 2),
            .init(text: "小星星", phonetic: "xiǎo xīng xing", category: "rhymes", difficulty: 2),
            .init(text: "一闪一闪亮晶晶", phonetic: "yī shǎn yī shǎn liàng jīng jīng", category: "rhymes", difficulty: 3),
            .init(text: "摇啊摇", phonetic: "yáo a yáo", category: "rhymes", difficulty: 1),
            .init(text: "拔萝卜", phonetic: "bá luó bo", category: "rhymes", difficulty: 2),
            .init(text: "小兔子乖乖", phonetic: "xiǎo tù zi guāi guāi", category: "rhymes", difficulty: 3),
        ]
    )
}

/// Preset terms the feedback lines use to address the child. The parent
/// picks one in the read-along setup; it's interpolated into every feedback
/// TTS line so the loop feels personal. Stored verbatim in `@AppStorage`.
enum ReadAlongKidTerm {
    /// The presets shown in the picker. "宝贝" is the gender-neutral default.
    static let presets: [String] = ["宝贝", "闺女", "儿子", "小朋友"]
}

// MARK: - Session record

/// One attempt at a single word: the recognized text (may be empty on ASR
/// failure) and the score the judge gave it.
struct ReadAlongAttempt: Hashable, Sendable {
    let recognizedText: String
    let score: Double
    let verdict: ReadAlongVerdict
}

/// The outcome of a single word in a session: the word, every attempt made,
/// whether it was eventually passed, and the best score.
struct ReadAlongTrial: Identifiable, Hashable, Sendable {
    let id: UUID
    let word: ReadAlongWord
    var attempts: [ReadAlongAttempt]
    var passed: Bool
    var bestScore: Double

    init(word: ReadAlongWord) {
        self.id = UUID()
        self.word = word
        self.attempts = []
        self.passed = false
        self.bestScore = 0
    }

    var attemptCount: Int { attempts.count }
}

/// A complete training session: the category, the ordered trials, and
/// timing. Persisted in-memory only (no GRDB) for the first version.
struct ReadAlongSession: Identifiable, Sendable {
    let id: UUID
    let category: ReadAlongCategory.ID
    let categoryTitle: String
    var trials: [ReadAlongTrial]
    let startedAt: Date
    var completedAt: Date?

    init(category: ReadAlongCategory) {
        self.id = UUID()
        self.category = category.id
        self.categoryTitle = category.title
        // Sort by difficulty ascending so easy words come first.
        self.trials = category.words
            .sorted { $0.difficulty < $1.difficulty }
            .map { ReadAlongTrial(word: $0) }
        self.startedAt = Date()
        self.completedAt = nil
    }

    var passedCount: Int { trials.filter(\.passed).count }
    var totalStars: Int { trials.reduce(0) { $0 + ($1.passed ? 1 : 0) } }
    var totalAttempts: Int { trials.reduce(0) { $0 + $1.attemptCount } }
    var isComplete: Bool { trials.allSatisfy(\.passed) }
}

// MARK: - Judge

/// The verdict for one attempt. Drives the feedback TTS line + the UI emoji.
enum ReadAlongVerdict: String, Sendable, Equatable {
    case pass
    case close
    case retry

    var emoji: String {
        switch self {
        case .pass: return "🎉"
        case .close: return "💪"
        case .retry: return "🤔"
        }
    }

    /// The TTS feedback line spoken after this verdict, addressed to the child
    /// by the given term (e.g. "宝贝", "闺女", "儿子"). Each verdict has several
    /// phrasings so the loop can rotate them and the feedback doesn't sound
    /// repetitive across attempts — pass the attempt index to pick a line.
    ///
    /// Kept long enough to satisfy the Qwen3 custom-voice minimum-tokenized-
    /// prompt requirement (short phrases like "真棒!" are rejected as too few
    /// chat tokens) while still sounding natural for a child.
    func feedbackLine(forKidTerm kidTerm: String, attemptIndex: Int = 0) -> String {
        switch self {
        case .pass:
            let lines = [
                "太棒了,\(kidTerm),你读得真好!",
                "\(kidTerm),你读得太棒了,继续加油!",
                "哇,\(kidTerm),你读得真不错!"
            ]
            return lines[attemptIndex % lines.count]
        case .close:
            let lines = [
                "\(kidTerm),差一点点,我们再来一次好吗?",
                "差一点点哦,\(kidTerm),再试一次一定行!",
                "\(kidTerm),就差一点点了,加油!"
            ]
            return lines[attemptIndex % lines.count]
        case .retry:
            let lines = [
                "没关系,\(kidTerm),我们再试一次吧!",
                "\(kidTerm),要加油哦,我们再来一次!",
                "别灰心,\(kidTerm),慢慢来,再读一次好吗?"
            ]
            return lines[attemptIndex % lines.count]
        }
    }
}

/// Pure-Swift pronunciation judge. No model — just string normalization +
/// Levenshtein edit distance, tuned lenient for young children.
///
/// Usage:
/// ```swift
/// let judge = ReadAlongPronunciationJudge()
/// let verdict = judge.judge(target: "你好", recognized: "你好")
/// // verdict.verdict == .pass, verdict.score == 1.0
/// ```
struct ReadAlongPronunciationJudge: Sendable {
    /// Minimum score to pass (0…1). Lenient for kids.
    static let defaultPassThreshold: Double = 0.8
    /// Below pass but at/above this → "close" (encouraging retry).
    static let defaultCloseThreshold: Double = 0.5

    let passThreshold: Double
    let closeThreshold: Double

    init(passThreshold: Double = ReadAlongPronunciationJudge.defaultPassThreshold,
         closeThreshold: Double = ReadAlongPronunciationJudge.defaultCloseThreshold) {
        self.passThreshold = passThreshold
        self.closeThreshold = closeThreshold
    }

    struct Result: Sendable, Equatable {
        let score: Double
        let verdict: ReadAlongVerdict
    }

    func judge(target: String, recognized: String?) -> Result {
        let normalizedTarget = normalize(target)
        let normalizedRecognized = normalize(recognized ?? "")

        // No recognition at all → retry.
        guard !normalizedRecognized.isEmpty else {
            return Result(score: 0, verdict: .retry)
        }

        // Exact match after normalization → perfect pass.
        if normalizedRecognized == normalizedTarget {
            return Result(score: 1.0, verdict: .pass)
        }

        let distance = Self.levenshtein(normalizedTarget, normalizedRecognized)
        let maxLen = max(normalizedTarget.count, normalizedRecognized.count, 1)
        let score = 1.0 - Double(distance) / Double(maxLen)

        let verdict: ReadAlongVerdict
        if score >= passThreshold {
            verdict = .pass
        } else if score >= closeThreshold {
            verdict = .close
        } else {
            verdict = .retry
        }
        return Result(score: score, verdict: verdict)
    }

    /// Normalize for comparison: lowercase, strip punctuation/whitespace,
    /// convert fullwidth → halfwidth. Does NOT strip pinyin tone marks (the
    /// ASR transcript is hanzi, not pinyin, so tone marks don't appear).
    func normalize(_ text: String) -> String {
        var result = text.lowercased()
        // Fullwidth → halfwidth (e.g. "Ａ" → "a", "！" → "!").
        result = result.unicodeScalars.map { scalar -> String in
            if scalar.value >= 0xFF01 && scalar.value <= 0xFF5E {
                return String(UnicodeScalar(scalar.value - 0xFEE0)!)
            }
            return String(scalar)
        }.joined()
        // Remove all punctuation and whitespace, keep letters/han/kana/numbers.
        let punctuation = CharacterSet.punctuationCharacters
        let symbols = CharacterSet.symbols
        let whitespace = CharacterSet.whitespacesAndNewlines
        result = result.unicodeScalars
            .filter { scalar in
                if whitespace.contains(scalar) { return false }
                if punctuation.contains(scalar) { return false }
                if symbols.contains(scalar) { return false }
                return true
            }
            .map { String($0) }
            .joined()
        return result
    }

    /// Classic Levenshtein edit distance. Iterative DP, O(m*n) time and space.
    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count
        if m == 0 { return n }
        if n == 0 { return m }

        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,        // deletion
                    curr[j - 1] + 1,    // insertion
                    prev[j - 1] + cost  // substitution
                )
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }
}
