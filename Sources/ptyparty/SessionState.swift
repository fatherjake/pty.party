import Foundation

/// Snapshot of the canvas written to session.json so a relaunch restores
/// the previous workspace.
struct SessionState: Codable {
    struct Tile: Codable {
        enum Kind: String, Codable {
            case terminal, image, command, note
        }

        var kind: Kind
        var id: String
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat
        var program: String?         // launched program name ("claude"), nil = shell
        var directory: String?       // terminal / command working directory
        var imageFile: String?       // image file name under images/
        var noteFile: String? = nil  // note markdown file name under notes/
        var claudeSession: String?   // pinned claude session UUID
        var command: String?         // command runner: command line
        var loopInterval: Double?    // command runner: seconds, 0 = run once
        var name: String?            // command runner: display name
    }

    struct Link: Codable {
        var from: String
        var to: String
    }

    var name: String?                 // display name shown in the session picker
    var workingDirectory: String?     // folder new terminals open in
    var magnification: CGFloat
    var scrollX: CGFloat
    var scrollY: CGFloat
    var tiles: [Tile]
    var imageConnections: [Link]      // image id → terminal id
    var terminalConnections: [Link]   // terminal id → terminal id
    var noteConnections: [Link]? = nil  // note id → terminal id (added later, so optional)
}
