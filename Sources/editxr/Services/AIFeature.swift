/// hyperlab fork: AI section editing (Ctrl+Space, the palette's AI section,
/// the provider in the hint bar) is off until it is wired to our own backend.
/// The LLM code stays compiled so upstream merges stay clean; flip this to
/// bring the feature back.
enum AIFeature {
    static let enabled = false
}
