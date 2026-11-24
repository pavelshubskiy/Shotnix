import AVFoundation
import Foundation

/// A note left while a recording runs. Older notes can include additional fields.
struct RecordingRecoveryNote: Codable, Equatable {
    var videoPath: String
    var cameraPath: String?
}

enum RecordingRecovery {
    nonisolated(unsafe) static var overrideRoot: URL?

    static func noteURL(baseDirectory: URL? = nil) -> URL {
        (baseDirectory ?? overrideRoot ?? URL.applicationSupportDirectory)
            .appendingPathComponent("Shotnix", isDirectory: true)
            .appendingPathComponent("InterruptedRecording.json")
    }

    static func save(_ note: RecordingRecoveryNote, baseDirectory: URL? = nil) {
        let url = noteURL(baseDirectory: baseDirectory)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(note).write(to: url, options: .atomic)
        } catch {
            print("[Shotnix] Recording recovery note failed: \(error)")
        }
    }

    static func load(baseDirectory: URL? = nil) -> RecordingRecoveryNote? {
        guard let data = try? Data(contentsOf: noteURL(baseDirectory: baseDirectory)) else { return nil }
        return try? JSONDecoder().decode(RecordingRecoveryNote.self, from: data)
    }

    static func clear(baseDirectory: URL? = nil) {
        try? FileManager.default.removeItem(at: noteURL(baseDirectory: baseDirectory))
    }

    /// Clears the note only if it's `video`'s: a take finishing late must
    /// never delete the note of the next one, already recording.
    static func clear(ifFor video: URL, baseDirectory: URL? = nil) {
        guard let note = load(baseDirectory: baseDirectory), note.videoPath == video.path else { return }
        clear(baseDirectory: baseDirectory)
    }

    /// The screen movie is fragmented, so it can still play after a crash.
    static func recoverInterruptedRecording(baseDirectory: URL? = nil) async -> URL? {
        guard let note = load(baseDirectory: baseDirectory) else { return nil }
        clear(baseDirectory: baseDirectory)
        let video = URL(fileURLWithPath: note.videoPath)
        let camera = note.cameraPath.map { URL(fileURLWithPath: $0) }
        guard let duration = await playableDuration(of: video), duration > 0.2 else {
            try? FileManager.default.removeItem(at: video)
            if let camera { try? FileManager.default.removeItem(at: camera) }
            return nil
        }
        if let camera, await playableDuration(of: camera) == nil {
            try? FileManager.default.removeItem(at: camera)
        }
        return video
    }

    /// Seconds of playable movie, or nil when the file can't be read.
    static func playableDuration(of url: URL) async -> Double? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let asset = AVURLAsset(url: url)
        guard let playable = try? await asset.load(.isPlayable), playable,
              let duration = try? await asset.load(.duration), duration.isNumeric else { return nil }
        return duration.seconds
    }
}
