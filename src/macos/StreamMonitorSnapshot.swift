import Foundation

struct StreamMonitorSnapshot {
    private(set) var status = "Pronto"
    private(set) var count = 0
    private(set) var recent = Data()
    private(set) var receivers: [String: Data] = [:]
    private(set) var receiverCounts: [String: Int] = [:]

    mutating func update(status: String, count: Int, recent: Data,
                         receivers: [String: Data], receiverCounts: [String: Int]) {
        self.status = status
        self.count = count
        self.recent = recent
        self.receivers = receivers
        self.receiverCounts = receiverCounts
    }
}

/// Independent decoder presentation: latest follows the stream; history stays pinned.
struct RTCMMonitorState {
    var paused = false
    private(set) var decoder = RTCMDecoder()
    private(set) var selectedType: Int?
    private(set) var pinnedFrame: RTCMDecoder.Frame?
    private var generation: UUID?
    private var revision = -1

    private func revisionOf(_ decoder: RTCMDecoder) -> Int {
        decoder.messages.values.reduce(decoder.badCRC) { $0 + $1.count }
    }

    func needsUpdate(_ incoming: RTCMDecoder, generation: UUID) -> Bool {
        self.generation != generation || (!paused && revision != revisionOf(incoming))
    }

    mutating func update(_ incoming: RTCMDecoder, generation: UUID) {
        if self.generation != generation {
            selectedType = nil
            pinnedFrame = nil
            paused = false
        } else if paused { return }
        self.generation = generation
        revision = revisionOf(incoming)
        decoder = incoming
        if selectedType == nil || decoder.messages[selectedType!] == nil {
            selectedType = decoder.messages.keys.min()
            pinnedFrame = nil
        }
    }

    mutating func selectType(_ type: Int?) {
        guard type != selectedType else { return }
        selectedType = type
        pinnedFrame = nil
    }

    mutating func selectFrame(_ id: Int?) {
        pinnedFrame = id.flatMap { id in availableFrames.first { $0.id == id } }
    }

    var displayedFrame: RTCMDecoder.Frame? {
        pinnedFrame ?? selectedType.flatMap { decoder.messages[$0]?.frames.last }
    }

    var availableFrames: [RTCMDecoder.Frame] {
        var frames = selectedType.flatMap { decoder.messages[$0]?.frames } ?? []
        if let pinnedFrame, !frames.contains(where: { $0.id == pinnedFrame.id }) {
            frames.insert(pinnedFrame, at: 0)
        }
        return frames
    }
}
