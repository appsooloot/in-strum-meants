/// Decides whether a Mac key press should play the on-screen keyboard.
enum KeyRouting {
    static func shouldPlay(inPluginWindow: Bool, inSheet: Bool,
                           hasCommandControlOrOption: Bool, typingInTextField: Bool) -> Bool {
        !(inPluginWindow || inSheet || hasCommandControlOrOption || typingInTextField)
    }
}
