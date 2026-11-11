import Foundation

enum TextTransformation: String, CaseIterable, Identifiable {
    case uppercase
    case lowercase
    case titleCase

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uppercase: return "UPPERCASE"
        case .lowercase: return "lowercase"
        case .titleCase: return "Title Case"
        }
    }

    var iconName: String {
        switch self {
        case .uppercase: return "textformat.size"
        case .lowercase: return "textformat.size"
        case .titleCase: return "textformat.size"
        }
    }

    func applied(to text: String) -> String {
        switch self {
        case .uppercase:
            return text.uppercased()
        case .lowercase:
            return text.lowercased()
        case .titleCase:
            return Self.titleCased(text)
        }
    }

    private static func titleCased(_ text: String) -> String {
        var result = ""
        var isAtWordStart = true
        for character in text {
            if isAtWordStart, character.isLetter {
                result += character.uppercased()
            } else {
                result.append(character)
            }
            isAtWordStart = !(character.isLetter
                || character.isNumber
                || character == "'"
                || character == "\u{2019}")
        }
        return result
    }
}
