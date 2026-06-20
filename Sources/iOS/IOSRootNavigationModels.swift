import SwiftUI
import QwenVoiceCore

enum IOSAppTab: String, CaseIterable, Identifiable {
    case studio
    case voices
    case history
    case settings

    var id: String { rawValue }
}

enum IOSLibrarySection: String, CaseIterable, Identifiable {
    case history
    case voices

    var id: String { rawValue }

    var title: String {
        switch self {
        case .history:
            return "历史"
        case .voices:
            return "声音"
        }
    }

    var selectionTint: Color {
        switch self {
        case .history:
            return IOSBrandTheme.library
        case .voices:
            return IOSBrandTheme.library
        }
    }
}

enum IOSGenerationSection: String, CaseIterable, Identifiable {
    case custom
    case design
    case clone

    var id: String { rawValue }

    var mode: GenerationMode {
        switch self {
        case .custom: return .custom
        case .design: return .design
        case .clone: return .clone
        }
    }

    var title: String {
        mode.displayName
    }

    var compactTitle: String {
        // Mode segmented uses the mode name (per design_references/Vocello iOS/
        // chrome.jsx ModeSegmented). The longer action-oriented labels live on
        // the setup-chip pattern; the segmented control itself stays terse.
        switch self {
        case .custom:
            return "自定义"
        case .design:
            return "设计"
        case .clone:
            return "克隆"
        }
    }
}
