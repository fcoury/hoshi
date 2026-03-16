import Foundation

// A single button in the keyboard toolbar
// Each button has a display label and the bytes it sends to the terminal
struct ToolbarButton: Codable, Identifiable, Equatable, Hashable {
    let id: String          // Unique identifier (e.g., "esc", "ctrl-c")
    let label: String       // Display text on the button
    let bytes: [UInt8]      // Raw bytes sent to the terminal session
    let category: Category  // For grouping in the palette

    enum Category: String, Codable, CaseIterable {
        case modifier   // Ctrl, Alt, etc.
        case navigation // Arrow keys, Home, End, PgUp, PgDn
        case swipe      // Swipe-to-arrow controls
        case function   // F1-F12
        case symbol     // /, -, |, ~, etc.
        case clipboard  // Copy and paste actions
        case combo      // Ctrl+C, Ctrl+B, Ctrl+D, etc.
    }
}

// MARK: - Built-in button definitions

extension ToolbarButton {

    // All available buttons the user can choose from
    static let allAvailable: [ToolbarButton] = modifiers + navigation + swipeControls + function + symbols + clipboard + combos

    // Default toolbar layout
    static let defaultButtons: [ToolbarButton] = [
        .esc, .ctrl, .opt, .tab,
        .arrowUp, .arrowDown, .arrowLeft, .arrowRight,
        .slash, .dash, .pipe,
        .ctrlC,
    ]

    // Modifier IDs that behave as sticky toggles (applied to next key press)
    static let stickyModifierIDs: Set<String> = ["ctrl", "opt", "shift"]

    // Swipe button IDs (rendered with drag gesture instead of tap)
    static let swipeButtonIDs: Set<String> = ["swipe-all", "swipe-horiz", "swipe-vert"]

    // MARK: Modifiers

    static let esc = ToolbarButton(id: "esc", label: "Esc", bytes: [0x1B], category: .modifier)
    static let tab = ToolbarButton(id: "tab", label: "Tab", bytes: [0x09], category: .modifier)

    // Ctrl is a "sticky" modifier — it XORs 0x40 with the next key press
    // Represented as a toggle in the toolbar, not a direct byte sender
    static let ctrl = ToolbarButton(id: "ctrl", label: "Ctrl", bytes: [], category: .modifier)

    // Opt (Alt/Meta) — sticky modifier, prepends ESC (0x1B) before next key
    static let opt = ToolbarButton(id: "opt", label: "Opt", bytes: [], category: .modifier)

    // Shift — sticky modifier, uppercases next letter or adds xterm modifier code
    static let shift = ToolbarButton(id: "shift", label: "Shift", bytes: [], category: .modifier)

    static let modifiers: [ToolbarButton] = [esc, ctrl, opt, shift, tab]

    // MARK: Navigation (VT100 escape sequences for arrow keys, etc.)

    static let arrowUp = ToolbarButton(id: "arrow-up", label: "▲", bytes: [0x1B, 0x5B, 0x41], category: .navigation)        // ESC [ A
    static let arrowDown = ToolbarButton(id: "arrow-down", label: "▼", bytes: [0x1B, 0x5B, 0x42], category: .navigation)    // ESC [ B
    static let arrowRight = ToolbarButton(id: "arrow-right", label: "▶", bytes: [0x1B, 0x5B, 0x43], category: .navigation)  // ESC [ C
    static let arrowLeft = ToolbarButton(id: "arrow-left", label: "◀", bytes: [0x1B, 0x5B, 0x44], category: .navigation)    // ESC [ D
    static let home = ToolbarButton(id: "home", label: "Home", bytes: [0x1B, 0x5B, 0x48], category: .navigation)            // ESC [ H
    static let end = ToolbarButton(id: "end", label: "End", bytes: [0x1B, 0x5B, 0x46], category: .navigation)               // ESC [ F
    static let pgUp = ToolbarButton(id: "pgup", label: "PgUp", bytes: [0x1B, 0x5B, 0x35, 0x7E], category: .navigation)     // ESC [ 5 ~
    static let pgDn = ToolbarButton(id: "pgdn", label: "PgDn", bytes: [0x1B, 0x5B, 0x36, 0x7E], category: .navigation)     // ESC [ 6 ~

    static let navigation: [ToolbarButton] = [arrowUp, arrowDown, arrowLeft, arrowRight, home, end, pgUp, pgDn]

    // MARK: Swipe controls — drag to send arrow keys

    static let swipeAll   = ToolbarButton(id: "swipe-all",   label: "⌖", bytes: [], category: .swipe)
    static let swipeHoriz = ToolbarButton(id: "swipe-horiz", label: "⇔", bytes: [], category: .swipe)
    static let swipeVert  = ToolbarButton(id: "swipe-vert",  label: "⇕", bytes: [], category: .swipe)

    static let swipeControls: [ToolbarButton] = [swipeAll, swipeHoriz, swipeVert]

    // MARK: Function keys (VT100 escape sequences)

    static let f1  = ToolbarButton(id: "f1",  label: "F1",  bytes: [0x1B, 0x4F, 0x50], category: .function)             // ESC O P
    static let f2  = ToolbarButton(id: "f2",  label: "F2",  bytes: [0x1B, 0x4F, 0x51], category: .function)             // ESC O Q
    static let f3  = ToolbarButton(id: "f3",  label: "F3",  bytes: [0x1B, 0x4F, 0x52], category: .function)             // ESC O R
    static let f4  = ToolbarButton(id: "f4",  label: "F4",  bytes: [0x1B, 0x4F, 0x53], category: .function)             // ESC O S
    static let f5  = ToolbarButton(id: "f5",  label: "F5",  bytes: [0x1B, 0x5B, 0x31, 0x35, 0x7E], category: .function) // ESC [ 15 ~
    static let f6  = ToolbarButton(id: "f6",  label: "F6",  bytes: [0x1B, 0x5B, 0x31, 0x37, 0x7E], category: .function) // ESC [ 17 ~
    static let f7  = ToolbarButton(id: "f7",  label: "F7",  bytes: [0x1B, 0x5B, 0x31, 0x38, 0x7E], category: .function) // ESC [ 18 ~
    static let f8  = ToolbarButton(id: "f8",  label: "F8",  bytes: [0x1B, 0x5B, 0x31, 0x39, 0x7E], category: .function) // ESC [ 19 ~
    static let f9  = ToolbarButton(id: "f9",  label: "F9",  bytes: [0x1B, 0x5B, 0x32, 0x30, 0x7E], category: .function) // ESC [ 20 ~
    static let f10 = ToolbarButton(id: "f10", label: "F10", bytes: [0x1B, 0x5B, 0x32, 0x31, 0x7E], category: .function) // ESC [ 21 ~
    static let f11 = ToolbarButton(id: "f11", label: "F11", bytes: [0x1B, 0x5B, 0x32, 0x33, 0x7E], category: .function) // ESC [ 23 ~
    static let f12 = ToolbarButton(id: "f12", label: "F12", bytes: [0x1B, 0x5B, 0x32, 0x34, 0x7E], category: .function) // ESC [ 24 ~

    static let function: [ToolbarButton] = [f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12]

    // MARK: Common symbols

    static let slash    = ToolbarButton(id: "slash",     label: "/",  bytes: [0x2F], category: .symbol)
    static let dash     = ToolbarButton(id: "dash",      label: "-",  bytes: [0x2D], category: .symbol)
    static let pipe     = ToolbarButton(id: "pipe",      label: "|",  bytes: [0x7C], category: .symbol)
    static let tilde    = ToolbarButton(id: "tilde",     label: "~",  bytes: [0x7E], category: .symbol)
    static let backtick = ToolbarButton(id: "backtick",  label: "`",  bytes: [0x60], category: .symbol)
    static let at       = ToolbarButton(id: "at",        label: "@",  bytes: [0x40], category: .symbol)
    static let hash     = ToolbarButton(id: "hash",      label: "#",  bytes: [0x23], category: .symbol)
    static let dollar   = ToolbarButton(id: "dollar",    label: "$",  bytes: [0x24], category: .symbol)
    static let ampersand = ToolbarButton(id: "ampersand", label: "&", bytes: [0x26], category: .symbol)
    static let asterisk = ToolbarButton(id: "asterisk",  label: "*",  bytes: [0x2A], category: .symbol)
    static let equals   = ToolbarButton(id: "equals",    label: "=",  bytes: [0x3D], category: .symbol)
    static let plus     = ToolbarButton(id: "plus",      label: "+",  bytes: [0x2B], category: .symbol)
    static let backslash = ToolbarButton(id: "backslash", label: "\\", bytes: [0x5C], category: .symbol)
    static let underscore = ToolbarButton(id: "underscore", label: "_", bytes: [0x5F], category: .symbol)
    static let lbracket = ToolbarButton(id: "lbracket",  label: "[",  bytes: [0x5B], category: .symbol)
    static let rbracket = ToolbarButton(id: "rbracket",  label: "]",  bytes: [0x5D], category: .symbol)
    static let lbrace   = ToolbarButton(id: "lbrace",    label: "{",  bytes: [0x7B], category: .symbol)
    static let rbrace   = ToolbarButton(id: "rbrace",    label: "}",  bytes: [0x7D], category: .symbol)

    static let symbols: [ToolbarButton] = [
        slash, dash, pipe, tilde, backtick, at, hash, dollar,
        ampersand, asterisk, equals, plus, backslash, underscore,
        lbracket, rbracket, lbrace, rbrace,
    ]

    // MARK: Clipboard actions

    static let copy = ToolbarButton(id: "copy", label: "Copy", bytes: [], category: .clipboard)
    static let paste = ToolbarButton(id: "paste", label: "Paste", bytes: [], category: .clipboard)

    static let clipboard: [ToolbarButton] = [copy, paste]

    // MARK: Common key combos (Ctrl+letter = letter & 0x1F)

    static let ctrlC = ToolbarButton(id: "ctrl-c", label: "^C", bytes: [0x03], category: .combo)  // SIGINT
    static let ctrlD = ToolbarButton(id: "ctrl-d", label: "^D", bytes: [0x04], category: .combo)  // EOF
    static let ctrlZ = ToolbarButton(id: "ctrl-z", label: "^Z", bytes: [0x1A], category: .combo)  // SIGTSTP
    static let ctrlA = ToolbarButton(id: "ctrl-a", label: "^A", bytes: [0x01], category: .combo)  // tmux/screen prefix
    static let ctrlB = ToolbarButton(id: "ctrl-b", label: "^B", bytes: [0x02], category: .combo)  // tmux prefix
    static let ctrlL = ToolbarButton(id: "ctrl-l", label: "^L", bytes: [0x0C], category: .combo)  // Clear screen
    static let ctrlR = ToolbarButton(id: "ctrl-r", label: "^R", bytes: [0x12], category: .combo)  // Reverse search
    static let ctrlW = ToolbarButton(id: "ctrl-w", label: "^W", bytes: [0x17], category: .combo)  // Delete word
    static let ctrlU = ToolbarButton(id: "ctrl-u", label: "^U", bytes: [0x15], category: .combo)  // Clear line

    static let combos: [ToolbarButton] = [ctrlC, ctrlD, ctrlZ, ctrlA, ctrlB, ctrlL, ctrlR, ctrlW, ctrlU]
}
