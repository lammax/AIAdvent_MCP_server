import Foundation

public enum RemoteMessageChannel: Equatable, Sendable {
    case desktop
    case web
}

/// Only direct message entrypoints apply this policy, never worker startup or polling.
public enum RemoteModePolicy {
    public static func enabled(channel: RemoteMessageChannel, prompt: String) -> Bool {
        let command = prompt.trimmingCharacters(in: .whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ".!?…"))).lowercased()
            .replacingOccurrences(of: "ё", with: "е")
        switch command {
        case "я ушел", "/remote-start": return true
        case "я здесь", "я пришел", "я пришел в офис", "/remote-stop": return false
        default: return channel == .web
        }
    }
}
