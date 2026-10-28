/// Which MIDI messages reach the instrument when one channel is chosen.
public enum MIDIChannelFilter {
    /// `channel` is 1…16, or nil for all channels. Channel messages (0x80–0xEF) pass only on the chosen channel;
    /// system messages (0xF0–0xFF) always pass.
    public static func passes(_ bytes: [UInt8], channel: Int?) -> Bool {
        guard let status = bytes.first else { return false }
        guard let channel, status >= 0x80, status < 0xF0 else { return true }
        return Int(status & 0x0F) + 1 == channel
    }
}
