import SwiftUI
import AVKit
import UniformTypeIdentifiers
import NaturalLanguage
import Security

@main
struct CinemaAudioStudioApp: App {
    var body: some Scene {
        WindowGroup {
            StudioView()
                .frame(minWidth: 1180, minHeight: 760)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
    }
}

enum StudioMode: String, CaseIterable, Identifiable {
    case voice = "Voice"
    case music = "Music"
    case effects = "Sound FX"
    case mix = "Workspace"
    var id: String { rawValue }
    var icon: String {
        switch self { case .voice: "waveform"; case .music: "music.note"; case .effects: "sparkles"; case .mix: "square.stack.3d.up" }
    }
    var eyebrow: String {
        switch self { case .voice: "PERFORMANCE"; case .music: "SCORE & AMBIENCE"; case .effects: "FOLEY & TEXTURES"; case .mix: "PROJECT ASSETS" }
    }
}

struct AudioClip: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var kind: String
    var filename: String
    var createdAt: Date = Date()
    var gain: Double = 1
    var offset: Double = 0
    var url: URL { URL(fileURLWithPath: filename) }
}

@MainActor
final class StudioModel: ObservableObject {
    @Published var mode: StudioMode = .voice
    @Published var isGenerating = false
    @Published var installingAudio = false
    @Published var isChecking = false
    @Published var status = "Ready when you are"
    @Published var errorMessage: String?
    @Published var clips: [AudioClip] = []
    @Published var playingClip: UUID?
    @Published var activeClipID: UUID?
    @Published var playbackTime = 0.0
    @Published var playbackDuration = 0.0
    @Published var voices: [String] = [
        "🇮🇳 Kabir (Warm Indian Male - Conversational)",
        "🇮🇳 Dev (Calm Indian Male - Storyteller / Narrator)",
        "🇮🇳 Kavya (Indian Female - Clear & Friendly)",
        "🇮🇳 Aryan (Young Indian Male - Professional)",
        "🌟 Selene (Official Studio Voice)",
        "❤️ Heart (Warm US Female)",
        "☕ Adam (Warm & Deep US Male)",
        "🎙️ Custom Voice Clone (Upload Audio Sample)"
    ]
    @Published var emotions: [String] = [
        "Auto — read the scene", "Natural / Neutral (Default prosody)",
        "🧐 Curious & Inquisitive", "🎭 Playful & Cheerful", "⚡ Excited & Energetic",
        "🥰 Warm & Empathetic", "🤔 Thoughtful & Reflective", "😄 Laughing / Joyful",
        "🤫 Whispering Softly", "😢 Sad & Melancholic", "😡 Angry & Intense",
        "😮‍💨 Sighing / Relieved", "✏️ Custom Acoustic Tag..."
    ]
    @Published var workspaceURL: URL
    @Published var remoteAvailable = false
    @Published var soundEngineAvailable = false
    @Published var mediumModelAvailable = false
    @Published var soundEnginePath = ""
    @Published var huggingFaceConnected = false
    @Published var voiceSample: Data?
    @Published var voiceSampleName = "No reference selected"
    @Published var currentPlayer: AVPlayer?
    @Published var customEmotion = ""
    @Published var performanceDirection = ""
    @Published var referenceTranscript = ""
    @Published var openRouterAPIKey = ""
    @Published var selectedVoice = "🇮🇳 Dev (Calm Indian Male - Storyteller / Narrator)"
    @Published var selectedEmotion = "Auto — read the scene"
    @Published var speechText = ""
    @Published var pronunciationRules = ""
    @Published var musicPrompt = "A restrained cinematic piano motif, warm felt piano, low strings entering slowly, intimate and unresolved, no vocals"
    @Published var fxPrompt = ""
    @Published var musicSeconds = 45.0
    @Published var musicQuality = "Fast · Small"
    @Published var fxSeconds = 8.0
    @Published var musicEditMode = "New score"
    @Published var fxEditMode = "New sound"
    @Published var editSourceID: UUID?
    @Published var inpaintStart = 0.0
    @Published var inpaintEnd = 8.0
    @Published var variationStrength = 0.55
    @Published var soundSteps = 8.0
    @Published var soundGuidance = 1.0
    @Published var negativePrompt = ""
    @Published var candidateCount = 1.0
    @Published var noiseCleanupEnabled = false
    @Published var currentWorkspaceName = "Untitled Film"

    private let baseService = URL(string: "http://127.0.0.1:5070")!
    private let fm = FileManager.default
    private var voiceServiceProcess: Process?
    private var playbackObserver: Any?
    private var clipMetaURL: URL { workspaceURL.appendingPathComponent("project.json") }
    private var audioDir: URL { workspaceURL.appendingPathComponent("Audio", isDirectory: true) }
    var sourceClips: [AudioClip] { clips.filter { ["Music", "Sound FX", "Import", "Mixdown"].contains($0.kind) } }
    var selectedSourceDuration: Double {
        guard let clip = clips.first(where: { $0.id == editSourceID }) else { return 1 }
        return audioDuration(clip.url) ?? 1
    }

    init() {
        let outputs = URL(fileURLWithPath: "/Users/dheerajsrinivasa/Documents/Codex/2026-11-03/which-is-a-good-text-to/outputs", isDirectory: true)
        let initial = outputs.appendingPathComponent("Cinema Audio Workspace", isDirectory: true)
        workspaceURL = initial
        try? fm.createDirectory(at: initial, withIntermediateDirectories: true)
        for folder in ["Voice", "Music", "Sound FX", "Imports", "Mixes"] {
            try? fm.createDirectory(at: initial.appendingPathComponent("Audio/\(folder)", isDirectory: true), withIntermediateDirectories: true)
        }
        currentWorkspaceName = initial.lastPathComponent
        openRouterAPIKey = loadOpenRouterKey()
        loadProject()
        Task { await checkConnections() }
    }

    func checkConnections() async {
        isChecking = true
        defer { isChecking = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: baseService.appendingPathComponent("voices"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StudioError.unreachable }
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            if let values = payload["fish_voices"] as? [String], !values.isEmpty {
                voices = values.filter { !$0.contains("Custom Fish Voice ID") }
            }
            if let values = payload["fish_emotions"] as? [String], !values.isEmpty {
                emotions = ["Auto — read the scene"] + values
            }
            remoteAvailable = true
            status = "Fish Audio connected through your port 5070 service"
        } catch {
            await launchVoiceServiceIfNeeded()
        }
        if !remoteAvailable, voiceServiceProcess != nil {
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(650))
                if await pingVoiceService() { break }
            }
        }
        soundEnginePath = locateSoundEngine()
        soundEngineAvailable = !soundEnginePath.isEmpty
        refreshMediumModelAvailability()
        await refreshHuggingFaceStatus()
    }

    func refreshHuggingFaceStatus() async {
        refreshMediumModelAvailability()
        guard !soundEnginePath.isEmpty else { huggingFaceConnected = false; return }
        let hf = URL(fileURLWithPath: soundEnginePath).deletingLastPathComponent().appendingPathComponent(".venv/bin/hf")
        guard fm.isExecutableFile(atPath: hf.path) else { huggingFaceConnected = false; return }
        do {
            let result = try await runProcess(executable: hf, arguments: ["auth", "whoami", "--quiet"], directory: hf.deletingLastPathComponent(), environment: ProcessInfo.processInfo.environment)
            huggingFaceConnected = result.status == 0
        } catch { huggingFaceConnected = false }
    }

    private func refreshMediumModelAvailability() {
        guard !soundEnginePath.isEmpty else { mediumModelAvailable = false; return }
        let folder = URL(fileURLWithPath: soundEnginePath).deletingLastPathComponent().appendingPathComponent("models/mlx", isDirectory: true)
        mediumModelAvailable = fm.fileExists(atPath: folder.appendingPathComponent("dit_medium_f16.npz").path) && fm.fileExists(atPath: folder.appendingPathComponent("same_l_decoder_f32.npz").path)
        if !mediumModelAvailable && musicQuality.hasPrefix("Cinematic") { musicQuality = "Fast · Small" }
    }

    func openHuggingFaceLogin() {
        guard !soundEnginePath.isEmpty else { errorMessage = "Install the local audio runtime first."; return }
        let hf = URL(fileURLWithPath: soundEnginePath).deletingLastPathComponent().appendingPathComponent(".venv/bin/hf")
        let command = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Cinema Audio Studio/connect-huggingface.command")
        let script = [
            "#!/bin/zsh",
            "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin\"",
            "HF=\"\(hf.path)\"",
            "if [[ ! -x \"$HF\" ]]; then echo \"Hugging Face CLI is missing. Reinstall the local audio engine from CineScope settings.\"; read -k 1; exit 1; fi",
            "\"$HF\" auth login",
            "result=$?",
            "echo",
            "if [[ $result -eq 0 ]]; then echo \"Hugging Face sign-in complete. Return to CineScope and click Refresh status.\"; else echo \"Sign-in did not complete. Return to CineScope and try again.\"; fi",
            "read -k 1 \"?Press any key to close this window...\"",
            "exit $result"
        ].joined(separator: "\n")
        do {
            try fm.createDirectory(at: command.deletingLastPathComponent(), withIntermediateDirectories: true)
            try script.write(to: command, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
            guard NSWorkspace.shared.open(command) else { throw StudioError.message("Could not open Terminal for Hugging Face sign-in.") }
            status = "Finish Hugging Face sign-in in Terminal, then refresh status"
        } catch { errorMessage = error.localizedDescription }
    }

    private func pingVoiceService() async -> Bool {
        do {
            let (data, response) = try await URLSession.shared.data(from: baseService.appendingPathComponent("voices"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            if let values = payload["fish_voices"] as? [String], !values.isEmpty { voices = values.filter { !$0.contains("Custom Fish Voice ID") } }
            if let values = payload["fish_emotions"] as? [String], !values.isEmpty { emotions = ["Auto — read the scene"] + values }
            remoteAvailable = true
            status = "Voice link ready · your existing Fish Audio service"
            return true
        } catch { remoteAvailable = false; return false }
    }

    private func launchVoiceServiceIfNeeded() async {
        let folder = URL(fileURLWithPath: "/Users/dheerajsrinivasa/Documents/essentials/MyVoiceAssistant", isDirectory: true)
        let server = folder.appendingPathComponent("server.py")
        let python = folder.appendingPathComponent(".venv/bin/python")
        guard fm.fileExists(atPath: server.path), fm.isExecutableFile(atPath: python.path), voiceServiceProcess == nil else {
            remoteAvailable = false
            status = "Voice service not found on port 5070"
            return
        }
        do {
            let log = folder.appendingPathComponent("cinescope-service.log")
            fm.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            let process = Process(); process.executableURL = python; process.arguments = [server.path]; process.currentDirectoryURL = folder
            var environment = ProcessInfo.processInfo.environment
            environment["PORT"] = "5070"
            environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment; process.standardOutput = handle; process.standardError = handle
            try process.run(); voiceServiceProcess = process
            status = "Starting your existing voice service…"
        } catch { remoteAvailable = false; status = "Could not start the existing voice service" }
    }

    func selectWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Workspace"
        if panel.runModal() == .OK, let url = panel.url {
            workspaceURL = url
            currentWorkspaceName = url.lastPathComponent
            ensureFolders()
            loadProject()
        }
    }

    func saveOpenRouterKey() {
        let key = openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { errorMessage = "Enter your OpenRouter key first."; return }
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "CineScope", kSecAttrAccount as String: "OpenRouter API key"]
        SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = Data(key.utf8)
        let result = SecItemAdd(query as CFDictionary, nil)
        if result == errSecSuccess { status = "OpenRouter key saved in macOS Keychain" }
        else { errorMessage = "Could not save the OpenRouter key in Keychain (\(result))." }
    }

    private func loadOpenRouterKey() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "CineScope", kSecAttrAccount as String: "OpenRouter API key", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8) else { return "" }
        return key
    }

    func importReference(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            voiceSample = try Data(contentsOf: url)
            voiceSampleName = url.lastPathComponent
        } catch { errorMessage = "Could not read that audio file: \(error.localizedDescription)" }
    }

    func generateSpeech() async {
        guard !speechText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorMessage = "Add the line or scene you want spoken."; return }
        guard remoteAvailable else { errorMessage = "The Fish Audio service on port 5070 is not reachable. Start your existing voice assistant and retry."; return }
        isGenerating = true
        status = "Reading the scene and directing the performance…"
        defer { isGenerating = false }
        do {
            let preparedText = applyPronunciationRules(speechText)
            let emotionChoice = selectedEmotion == "Auto — read the scene" ? "" : selectedEmotion
            let emotion = emotionChoice == "✏️ Custom Acoustic Tag..." ? "__custom__" : emotionChoice
            let requestURL = baseService.appendingPathComponent("speak")
            var request = URLRequest(url: requestURL, timeoutInterval: 600)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var payload: [String: Any] = [
                "text": preparedText,
                "engine": "fish",
                "voice": selectedVoice,
                "speed": 1.0,
                "emotion": emotion,
                "direction": performanceDirection.trimmingCharacters(in: .whitespacesAndNewlines),
                "normalize": true
            ]
            if emotion == "__custom__" { payload["custom_emotion"] = customEmotion }
            if !openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                payload["api_key"] = openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if selectedVoice.contains("Custom Voice Clone") {
                guard let voiceSample else { throw StudioError.message("Choose a reference recording before generating a cloned voice.") }
                let transcript = referenceTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !transcript.isEmpty else { throw StudioError.message("Enter the exact words spoken in the reference recording. Fish uses this transcript to condition voice cloning.") }
                let ext = URL(fileURLWithPath: voiceSampleName).pathExtension.lowercased()
                let mime = ["mp3": "audio/mpeg", "wav": "audio/wav", "m4a": "audio/mp4", "flac": "audio/flac", "ogg": "audio/ogg", "aac": "audio/aac"][ext] ?? "audio/wav"
                payload["custom_voice_data"] = "data:\(mime);base64,\(voiceSample.base64EncodedString())"
                payload["custom_voice_text"] = transcript
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 600
            configuration.timeoutIntervalForResource = 900
            let (data, response) = try await URLSession(configuration: configuration).data(for: request)
            guard let http = response as? HTTPURLResponse else { throw StudioError.unreachable }
            guard (200..<300).contains(http.statusCode) else {
                let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "Voice generation failed (HTTP \(http.statusCode))."
                throw StudioError.message(message)
            }
            let name = "Voice \(timestamp())"
            let folder = audioDir.appendingPathComponent("Voice", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let output = folder.appendingPathComponent(safeFilename(name) + ".mp3")
            try data.write(to: output)
            addClip(AudioClip(name: name, kind: "Voice", filename: output.path))
            status = selectedEmotion == "Auto — read the scene" ? "Voice take saved · Auto delivery followed the scene" : "Voice take saved · \(emotionDisplay(emotion))"
            play(output, id: clips.last?.id)
        } catch { errorMessage = error.localizedDescription; status = "Speech generation failed" }
    }

    func generateSound(kind: StudioMode) async {
        guard soundEngineAvailable else { errorMessage = "Stable Audio’s local MLX runtime is not installed yet. Open Settings → Audio Engine Setup."; return }
        let isMusic = kind == .music
        let prompt = (isMusic ? musicPrompt : fxPrompt).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { errorMessage = isMusic ? "Describe the music you want." : "Describe the sound effect or ambience."; return }
        var seconds = isMusic ? Int(musicSeconds) : Int(fxSeconds)
        let editMode = isMusic ? musicEditMode : fxEditMode
        let sourceClip = clips.first(where: { $0.id == editSourceID })
        let tag = isMusic ? "Music" : "Sound FX"
        if isMusic && musicQuality.hasPrefix("Cinematic") && !mediumModelAvailable { errorMessage = "The Medium music model is not installed yet. Let its download finish, then open Settings and refresh status."; return }
        isGenerating = true
        status = "Composing \(isMusic ? "music" : "sound") locally on Apple silicon…"
        defer { isGenerating = false }
        do {
            let folder = audioDir.appendingPathComponent(tag, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let output = folder.appendingPathComponent("\(tag) \(timestamp()).wav")
            var continuationMerge: (sourcePath: String, prefixSeconds: Double)?
            var continuationSource: URL?
            let useMedium = isMusic && musicQuality.hasPrefix("Cinematic")
            let dit = useMedium ? "medium" : (isMusic ? "sm-music" : "sm-sfx")
            let decoder = useMedium ? "same-l" : "same-s"
            let mlxFolder = URL(fileURLWithPath: soundEnginePath).deletingLastPathComponent()
            let python = mlxFolder.appendingPathComponent(".venv/bin/python")
            let script = mlxFolder.appendingPathComponent("scripts/sa3_mlx.py")
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(mlxFolder.appendingPathComponent(".venv/bin").path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            environment["HOME"] = NSHomeDirectory()
            environment["PYTHONUNBUFFERED"] = "1"
            var arguments = ["-u", script.path, "--prompt", prompt, "--dit", dit, "--decoder", decoder, "--seconds", "\(seconds)", "--steps", "\(Int(soundSteps))", "--out", output.path]
            if soundGuidance != 1 { arguments += ["--cfg", String(format: "%.1f", soundGuidance)] }
            let cleanedNegative = negativePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if soundGuidance != 1 && !cleanedNegative.isEmpty { arguments += ["--negative-prompt", cleanedNegative] }
            if editMode != (isMusic ? "New score" : "New sound") {
                guard let sourceClip, fm.fileExists(atPath: sourceClip.filename) else { throw StudioError.message("Choose a source clip in the Edit from menu first.") }
                var initURL = sourceClip.url
                if editMode == "Continue" {
                    guard let sourceDuration = audioDuration(sourceClip.url), sourceDuration > 0 else { throw StudioError.message("Could not read the source clip duration.") }
                    let extensionSeconds = isMusic ? musicSeconds : fxSeconds
                    let contextSeconds = min(sourceDuration, 8.0)
                    let prefixSeconds = max(0, sourceDuration - contextSeconds)
                    let generationSeconds = Int(ceil(contextSeconds + extensionSeconds))
                    guard generationSeconds <= 120 else { throw StudioError.message("One continuation can add up to 112 seconds on this local model. Continue the new output again for a longer cue.") }
                    seconds = generationSeconds
                    let padded = folder.appendingPathComponent(".edit-source-\(UUID().uuidString).wav")
                    let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: { fm.isExecutableFile(atPath: $0) })
                    guard let ffmpeg else { throw StudioError.message("FFmpeg is required to prepare a continuation source. Install it with Homebrew (brew install ffmpeg).") }
                    let padArgs = ["-y", "-ss", String(format: "%.4f", prefixSeconds), "-i", sourceClip.filename, "-af", "apad", "-t", "\(generationSeconds)", "-ar", "44100", "-ac", "2", "-c:a", "pcm_s16le", padded.path]
                    let paddedResult = try await runProcess(executable: URL(fileURLWithPath: ffmpeg), arguments: padArgs, directory: folder, environment: environment)
                    guard paddedResult.status == 0, fm.fileExists(atPath: padded.path) else { throw StudioError.message("Could not prepare the padded continuation source.") }
                    initURL = padded
                    continuationSource = padded
                    let seam = max(0, contextSeconds - 1.5)
                    arguments += ["--init-audio", initURL.path, "--inpaint-range", String(format: "%.2f,%d", seam, generationSeconds)]
                    continuationMerge = (sourceClip.filename, prefixSeconds)
                } else if editMode == "Replace region" {
                    guard let sourceDuration = audioDuration(sourceClip.url), sourceDuration > 0 else { throw StudioError.message("Could not read the source clip duration.") }
                    let start = max(0, min(inpaintStart, sourceDuration - 0.1))
                    let end = max(start + 0.1, min(inpaintEnd, sourceDuration))
                    seconds = Int(ceil(sourceDuration))
                    arguments += ["--init-audio", initURL.path, "--inpaint-range", String(format: "%.2f,%.2f", start, end)]
                } else {
                    arguments += ["--init-audio", initURL.path, "--init-noise-level", String(format: "%.2f", variationStrength)]
                    if editMode == "More like this" { seconds = Int(ceil(audioDuration(sourceClip.url) ?? Double(seconds))) }
                }
            }
            if editMode == "Continue" {
                let sameVibe = "Continue the supplied audio seamlessly. Preserve its tempo, harmony, timbre, instrumentation, and emotional mood; develop the existing idea naturally without an abrupt restart."
                arguments += ["--prompt", "\(prompt). \(sameVibe)"]
            } else if editMode == "More like this" {
                arguments += ["--prompt", "\(prompt). Create a related variation that keeps the source's overall style, instrumentation, tempo, and mood while introducing fresh melodic or textural details."]
            }
            arguments += ["--seconds", "\(seconds)"]
            let count = max(1, Int(candidateCount))
            var rendered: [AudioClip] = []
            for candidate in 1...count {
                status = "Rendering \(isMusic ? "score" : "sound") · take \(candidate) of \(count)…"
                let candidateURL = count == 1 ? output : folder.appendingPathComponent("\(tag) \(timestamp()) · Take \(candidate).wav")
                let generationURL = continuationMerge == nil ? candidateURL : folder.appendingPathComponent(".continuation-\(UUID().uuidString).wav")
                var candidateArgs = arguments + ["--seed", "\(UInt32.random(in: 1...UInt32.max))"]
                if let outIndex = candidateArgs.firstIndex(of: "--out"), outIndex + 1 < candidateArgs.count { candidateArgs[outIndex + 1] = generationURL.path }
                let result = try await runProcess(executable: python, arguments: candidateArgs, directory: mlxFolder, environment: environment)
                guard result.status == 0, fm.fileExists(atPath: generationURL.path) else {
                    let log = result.output
                    let lowerLog = log.lowercased()
                    let needsAccess = ["401", "403", "gated", "access denied", "permission", "restricted"].contains(where: { lowerLog.contains($0) })
                    throw StudioError.message(needsAccess ? "Stable Audio access is blocked. In Settings → Engines & workspace, accept model access and connect Hugging Face, then retry." : "Local audio generation failed. \(log.suffix(700))")
                }
                if let continuationMerge {
                    if continuationMerge.prefixSeconds > 0.01 {
                        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: { fm.isExecutableFile(atPath: $0) }) else { throw StudioError.message("FFmpeg is required to assemble the extended cue.") }
                        let filter = "[0:a]atrim=start=0:end=\(String(format: "%.4f", continuationMerge.prefixSeconds)),asetpts=PTS-STARTPTS[prefix];[1:a]asetpts=PTS-STARTPTS[tail];[prefix][tail]concat=n=2:v=0:a=1[out]"
                        let mergeArgs = ["-y", "-i", continuationMerge.sourcePath, "-i", generationURL.path, "-filter_complex", filter, "-map", "[out]", "-ar", "44100", "-ac", "2", "-c:a", "pcm_s16le", candidateURL.path]
                        let merged = try await runProcess(executable: URL(fileURLWithPath: ffmpeg), arguments: mergeArgs, directory: folder, environment: environment)
                        guard merged.status == 0, fm.fileExists(atPath: candidateURL.path) else { throw StudioError.message("The model rendered the continuation, but FFmpeg could not assemble it with the original cue.") }
                    } else if generationURL != candidateURL {
                        try fm.moveItem(at: generationURL, to: candidateURL)
                    }
                    try? fm.removeItem(at: generationURL)
                }
                if noiseCleanupEnabled {
                    guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: { fm.isExecutableFile(atPath: $0) }) else { throw StudioError.message("FFmpeg is required for noise cleanup.") }
                    let cleaned = folder.appendingPathComponent(".cleanup-\(UUID().uuidString).wav")
                    let cleanupArgs = ["-y", "-i", candidateURL.path, "-af", "afftdn=nr=8:nf=-45:tn=1", "-ar", "44100", "-ac", "2", "-c:a", "pcm_s16le", cleaned.path]
                    let cleanupResult = try await runProcess(executable: URL(fileURLWithPath: ffmpeg), arguments: cleanupArgs, directory: folder, environment: environment)
                    guard cleanupResult.status == 0, fm.fileExists(atPath: cleaned.path) else { throw StudioError.message("FFmpeg could not apply gentle noise cleanup to the render.") }
                    try fm.removeItem(at: candidateURL)
                    try fm.moveItem(at: cleaned, to: candidateURL)
                }
                let clip = AudioClip(name: "\(tag) \(timestamp()) · Take \(candidate)", kind: tag, filename: candidateURL.path)
                addClip(clip)
                rendered.append(clip)
            }
            if let continuationSource { try? fm.removeItem(at: continuationSource) }
            let renderedSeconds = rendered.last.flatMap { audioDuration($0.url) }.map { Int($0.rounded()) } ?? seconds
            status = "\(tag) rendered locally · \(renderedSeconds) sec · \(count) take\(count == 1 ? "" : "s")"
            if let last = rendered.last { play(last.url, id: last.id) }
        } catch { errorMessage = error.localizedDescription; status = "Local render failed" }
    }

    func importAudio(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let folder = audioDir.appendingPathComponent("Imports", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: url, to: destination)
            addClip(AudioClip(name: url.deletingPathExtension().lastPathComponent, kind: "Import", filename: destination.path))
            status = "Added audio to workspace"
        } catch { errorMessage = "Import failed: \(error.localizedDescription)" }
    }

    func play(_ url: URL, id: UUID? = nil) {
        if let observer = playbackObserver, let oldPlayer = currentPlayer { oldPlayer.removeTimeObserver(observer); playbackObserver = nil }
        currentPlayer?.pause()
        let player = AVPlayer(url: url)
        currentPlayer = player
        playingClip = id
        activeClipID = id
        playbackTime = 0
        playbackDuration = audioDuration(url) ?? 0
        playbackObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.playbackTime = max(0, time.seconds) }
        }
        player.play()
    }

    func seekPlayback(to seconds: Double) {
        guard let currentPlayer else { return }
        let clamped = max(0, min(seconds, playbackDuration))
        currentPlayer.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playbackTime = clamped
    }

    func pausePlayback() { currentPlayer?.pause(); playingClip = nil }

    func formattedTime(_ time: Double) -> String {
        guard time.isFinite else { return "0:00" }
        let total = max(0, Int(time.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    func togglePlayback(_ clip: AudioClip) {
        if playingClip == clip.id { currentPlayer?.pause(); playingClip = nil }
        else { play(clip.url, id: clip.id) }
    }

    func makeMixdown() {
        guard !clips.isEmpty else { errorMessage = "Generate or import audio before creating a mix."; return }
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: { fm.isExecutableFile(atPath: $0) }) else {
            errorMessage = "FFmpeg is not installed. Install it with Homebrew (`brew install ffmpeg`) to render a mixdown."; return
        }
        do {
            let outputFolder = audioDir.appendingPathComponent("Mixes", isDirectory: true)
            try fm.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            let output = outputFolder.appendingPathComponent("Mix \(timestamp()).wav")
            var args: [String] = ["-y"]
            let active = clips.filter { fm.fileExists(atPath: $0.filename) }
            for clip in active { args += ["-i", clip.filename] }
            var filters: [String] = []
            for (index, clip) in active.enumerated() {
                let delay = max(0, Int(clip.offset * 1000))
                filters.append("[\(index):a]volume=\(String(format: "%.3f", clip.gain)),adelay=\(delay)|\(delay)[a\(index)]")
            }
            let labels = active.indices.map { "[a\($0)]" }.joined()
            filters.append("\(labels)amix=inputs=\(active.count):duration=longest:normalize=0:dropout_transition=0,alimiter=limit=0.95[out]")
            args += ["-filter_complex", filters.joined(separator: ";"), "-map", "[out]", "-ar", "48000", "-c:a", "pcm_s24le", output.path]
            let proc = Process(); proc.executableURL = URL(fileURLWithPath: ffmpeg); proc.arguments = args
            let pipe = Pipe(); proc.standardError = pipe; proc.standardOutput = Pipe()
            try proc.run(); proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { throw StudioError.message("FFmpeg could not mix those clips. Check that each source file is valid audio.") }
            let clip = AudioClip(name: output.deletingPathExtension().lastPathComponent, kind: "Mixdown", filename: output.path)
            addClip(clip); status = "Mixdown exported as 24-bit / 48 kHz WAV"; play(output, id: clip.id)
        } catch { errorMessage = error.localizedDescription }
    }

    func removeClip(_ clip: AudioClip) {
        clips.removeAll { $0.id == clip.id }
        saveProject()
    }

    func updateClip(_ clip: AudioClip) {
        if let index = clips.firstIndex(where: { $0.id == clip.id }) { clips[index] = clip; saveProject() }
    }

    func showOutputFolder() { NSWorkspace.shared.open(workspaceURL) }

    private func ensureFolders() {
        for folder in ["Voice", "Music", "Sound FX", "Imports", "Mixes"] { try? fm.createDirectory(at: audioDir.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true) }
    }
    private func loadProject() {
        ensureFolders()
        if let data = try? Data(contentsOf: clipMetaURL), let saved = try? JSONDecoder().decode([AudioClip].self, from: data) {
            clips = saved.filter { fm.fileExists(atPath: $0.filename) }.sorted { $0.createdAt > $1.createdAt }
        }
    }
    private func addClip(_ clip: AudioClip) { clips.insert(clip, at: 0); saveProject() }
    private func saveProject() { if let data = try? JSONEncoder().encode(clips) { try? data.write(to: clipMetaURL, options: .atomic) } }
    private func locateSoundEngine() -> String {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("StableAudio/optimized/mlx/sa3").path,
            URL(fileURLWithPath: "/Users/dheerajsrinivasa/Library/Application Support/Cinema Audio Studio/StableAudio/optimized/mlx/sa3").path
        ].compactMap { $0 }
        return candidates.first(where: { candidate in
            let folder = URL(fileURLWithPath: candidate).deletingLastPathComponent()
            return fm.isExecutableFile(atPath: candidate) && fm.fileExists(atPath: folder.appendingPathComponent(".venv/bin/python").path)
        }) ?? ""
    }
    private func runProcess(executable: URL, arguments: [String], directory: URL, environment: [String: String]) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = directory
                process.environment = environment
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: (process.terminationStatus, String(data: data, encoding: .utf8) ?? ""))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func timestamp() -> String { DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short).replacingOccurrences(of: ":", with: "-") }
    private func audioDuration(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return nil }
        let value = Double(file.length) / file.fileFormat.sampleRate
        return value.isFinite && value > 0 ? value : nil
    }
    private func safeFilename(_ value: String) -> String { value.replacingOccurrences(of: "[^A-Za-z0-9 -]", with: "", options: .regularExpression).replacingOccurrences(of: " ", with: "-") }
    private func emotionDisplay(_ value: String) -> String { value.replacingOccurrences(of: "^[^A-Za-z]+", with: "", options: .regularExpression).components(separatedBy: "(").first ?? value }
    private func applyPronunciationRules(_ text: String) -> String {
        var output = text
        for raw in pronunciationRules.components(separatedBy: .newlines) {
            let parts = raw.components(separatedBy: "=")
            guard parts.count >= 2 else { continue }
            let original = parts[0].trimmingCharacters(in: .whitespaces)
            let phonetic = parts.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
            if !original.isEmpty && !phonetic.isEmpty {
                output = output.replacingOccurrences(of: original, with: phonetic, options: [.caseInsensitive, .diacriticInsensitive])
            }
        }
        return output
    }
    private func detectEmotion(in text: String) -> String {
        let lower = text.lowercased()
        let rules: [(String, [String])] = [
            ("😢 Sad & Melancholic", ["grief", "miss you", "alone", "lost", "goodbye", "tears", "heartbroken", "never again", "death", "sorry"]),
            ("😡 Angry & Intense", ["furious", "hate", "damn", "how dare", "revenge", "fight", "angry", "betrayal", "get out"]),
            ("😮‍💨 Sighing / Relieved", ["finally", "at last", "safe", "relief", "thank goodness", "it's over"]),
            ("⚡ Excited & Energetic", ["amazing", "incredible", "can't believe", "wonderful", "we did it", "yes!", "let's go"]),
            ("🧐 Curious & Inquisitive", ["why", "how could", "what if", "who are you", "where did", "really?"]),
            ("🥰 Warm & Empathetic", ["i understand", "it's okay", "i'm here", "i care", "you are not alone", "take a breath"]),
            ("🎭 Playful & Cheerful", ["kidding", "just joking", "funny", "ha ha", "what a mess", "silly"]),
            ("🤫 Whispering Softly", ["don't wake", "quietly", "keep it down", "secret", "whisper"])
        ]
        for (emotion, cues) in rules where cues.contains(where: { lower.contains($0) }) { return emotion }
        return "Natural / Neutral (Default prosody)"
    }
}

enum StudioError: LocalizedError {
    case unreachable
    case message(String)
    var errorDescription: String? { switch self { case .unreachable: "The local audio service could not be reached."; case let .message(message): message } }
}

struct StudioView: View {
    @StateObject private var model = StudioModel()
    @State private var showVoiceImporter = false
    @State private var showAudioImporter = false
    @State private var selectedClip: AudioClip?
    @State private var showSettings = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
            VStack(spacing: 0) {
                topBar
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 26) {
                        titleBlock
                        if model.mode == .voice { voiceStudio }
                        else if model.mode == .music { musicStudio }
                        else if model.mode == .effects { effectsStudio }
                        else { workspaceStudio }
                    }
                    .padding(.horizontal, 34).padding(.top, 30).padding(.bottom, 40)
                    .frame(maxWidth: 1240, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                bottomBar
            }
        }
        .background(Color(hex: 0x0C0D10))
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $showVoiceImporter, allowedContentTypes: [.audio, .mp3, .wav], allowsMultipleSelection: false) { result in if case let .success(urls) = result, let url = urls.first { model.importReference(from: url) } }
        .fileImporter(isPresented: $showAudioImporter, allowedContentTypes: [.audio, .mp3, .wav], allowsMultipleSelection: false) { result in if case let .success(urls) = result, let url = urls.first { model.importAudio(url) } }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .alert("Something needs attention", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack { RoundedRectangle(cornerRadius: 10).fill(LinearGradient(colors: [Color(hex: 0xC59C69), Color(hex: 0xF0D6A9)], startPoint: .topLeading, endPoint: .bottomTrailing)); Image(systemName: "waveform.path").font(.system(size: 17, weight: .bold)).foregroundStyle(Color(hex: 0x161514)) }.frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) { Text("CINESCOPE").font(.system(size: 13, weight: .bold, design: .rounded)).tracking(1.6); Text("AUDIO WORKSPACE").font(.system(size: 9, weight: .medium)).tracking(1.8).foregroundStyle(.white.opacity(0.42)) }
            }.padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 30)
            Text("CREATE").font(.system(size: 10, weight: .bold)).tracking(1.7).foregroundStyle(.white.opacity(0.34)).padding(.horizontal, 20).padding(.bottom, 10)
            ForEach([StudioMode.voice, .music, .effects], id: \.self) { mode in modeButton(mode) }
            Spacer().frame(height: 25)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1).padding(.horizontal, 18).padding(.bottom, 22)
            Text("PROJECT").font(.system(size: 10, weight: .bold)).tracking(1.7).foregroundStyle(.white.opacity(0.34)).padding(.horizontal, 20).padding(.bottom, 10)
            Button { model.mode = .mix } label: {
                HStack(spacing: 12) { Image(systemName: "square.stack.3d.up").frame(width: 18); Text(model.currentWorkspaceName).lineLimit(1); Spacer(); Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).opacity(0.45) }
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(model.mode == .mix ? Color(hex: 0xE9C99B) : .white.opacity(0.72)).padding(.horizontal, 14).padding(.vertical, 11).background(model.mode == .mix ? Color.white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 10)
            }.buttonStyle(.plain)
            HStack(spacing: 9) { Circle().fill(model.remoteAvailable ? Color(hex: 0x72C7A4) : Color(hex: 0xCF846D)).frame(width: 7, height: 7); Text(model.remoteAvailable ? "VOICE LINKED" : "VOICE OFFLINE").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(.white.opacity(0.46)) }.padding(.horizontal, 20).padding(.top, 20)
            Spacer()
            Button { showSettings = true } label: { HStack(spacing: 11) { Image(systemName: "slider.horizontal.3"); Text("Settings & engines"); Spacer(); Image(systemName: "chevron.right").font(.system(size: 9)).opacity(0.45) }.font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.52)).padding(14).background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 12).padding(.bottom, 17) }.buttonStyle(.plain)
        }
        .frame(width: 234).background(Color(hex: 0x101114))
    }

    private func modeButton(_ mode: StudioMode) -> some View {
        Button { model.mode = mode } label: {
            HStack(spacing: 12) {
                Image(systemName: mode.icon).font(.system(size: 14, weight: .semibold)).frame(width: 18)
                Text(mode.rawValue).font(.system(size: 13, weight: .medium))
                Spacer()
                if mode == .voice && model.remoteAvailable { Circle().fill(Color(hex: 0x72C7A4)).frame(width: 6, height: 6) }
            }
            .foregroundStyle(model.mode == mode ? Color(hex: 0xF1D5AE) : .white.opacity(0.58))
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(model.mode == mode ? Color.white.opacity(0.075) : .clear, in: RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: .leading) { if model.mode == mode { RoundedRectangle(cornerRadius: 2).fill(Color(hex: 0xD5AE7A)).frame(width: 3, height: 20) } }
            .padding(.horizontal, 10)
        }.buttonStyle(.plain)
    }

    private var topBar: some View {
        HStack {
            HStack(spacing: 8) { Image(systemName: "folder").foregroundStyle(Color(hex: 0xC6A577)); Text(model.currentWorkspaceName).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.76)); Image(systemName: "chevron.down").font(.system(size: 9)).foregroundStyle(.white.opacity(0.35)) }
            Spacer()
            HStack(spacing: 7) { Circle().fill(model.soundEngineAvailable ? Color(hex: 0x72C7A4) : Color(hex: 0xD7AA71)).frame(width: 6, height: 6); Text(model.soundEngineAvailable ? "LOCAL AUDIO READY" : "LOCAL AUDIO SETUP").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.55)) }
            Button { showAudioImporter = true } label: { Label("Import audio", systemImage: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.85)).padding(.horizontal, 13).padding(.vertical, 8).background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain).padding(.leading, 15)
        }
        .padding(.horizontal, 30).frame(height: 57).background(Color(hex: 0x0F1013)).overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
    }

    private var titleBlock: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 11) {
                Text(model.mode.eyebrow).font(.system(size: 10, weight: .bold)).tracking(2.2).foregroundStyle(Color(hex: 0xC7A477))
                Text(titleForMode).font(.system(size: 30, weight: .semibold, design: .rounded)).tracking(-0.8).foregroundStyle(Color(hex: 0xF3F0EB))
                Text(subtitleForMode).font(.system(size: 13)).foregroundStyle(.white.opacity(0.48))
            }
            Spacer()
            if model.mode != .mix { Text("\(model.clips.count) TAKES IN WORKSPACE").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.35)).padding(.bottom, 4) }
        }
    }
    private var titleForMode: String { switch model.mode { case .voice: "Direct the voice"; case .music: "Build the score"; case .effects: "Shape the soundscape"; case .mix: "Your film workspace" } }
    private var subtitleForMode: String { switch model.mode { case .voice: "Natural dialogue, narration, and character performance."; case .music: "Generate a cinematic bed, theme, or musical texture."; case .effects: "Create foley, atmospheres, and designed details."; case .mix: "Collect, audition, balance, and export your audio." } }

    private var voiceStudio: some View {
        VStack(alignment: .leading, spacing: 19) {
            panel {
                HStack { sectionLabel("SCRIPT", detail: "Paste a scene, line, or narration"); Spacer(); Button("Clear") { model.speechText = "" }.buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.42)) }
                TextEditor(text: $model.speechText).font(.system(size: 15, weight: .regular, design: .serif)).scrollContentBackground(.hidden).foregroundStyle(Color(hex: 0xE9E5DE)).frame(minHeight: 158).padding(10).background(Color(hex: 0x141519), in: RoundedRectangle(cornerRadius: 10)).overlay(alignment: .topLeading) { if model.speechText.isEmpty { Text("The camera holds on the empty platform. Then, from the dark…").font(.system(size: 15, design: .serif)).foregroundStyle(.white.opacity(0.25)).padding(.leading, 16).padding(.top, 18).allowsHitTesting(false) } }
                HStack { Text("\(model.speechText.count) characters").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.31)); Spacer(); Text("Auto delivery follows the script’s wording and context").font(.system(size: 10)).foregroundStyle(.white.opacity(0.36)) }
            }
            panel {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) { sectionLabel("PERFORMER", detail: "Voice preset or your reference recording"); Picker("Voice", selection: $model.selectedVoice) { ForEach(model.voices, id: \.self) { Text($0).tag($0) } }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Color(hex: 0x141519), in: RoundedRectangle(cornerRadius: 9)) }
                    VStack(alignment: .leading, spacing: 8) { sectionLabel("DIRECTION", detail: "Choose a feeling or let the scene guide it"); Picker("Emotion", selection: $model.selectedEmotion) { ForEach(model.emotions, id: \.self) { Text($0).tag($0) } }.labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Color(hex: 0x141519), in: RoundedRectangle(cornerRadius: 9)) }
                }
                TextField("Performance direction (e.g. [quietly, holding back tears])", text: $model.performanceDirection, axis: .vertical).lineLimit(1...2).textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(.white.opacity(0.78)).padding(11).background(Color(hex: 0x141519), in: RoundedRectangle(cornerRadius: 8))
                if model.selectedEmotion == "✏️ Custom Acoustic Tag..." { TextField("Custom Fish emotion tag, e.g. wistful", text: $model.customEmotion).textFieldStyle(.plain).padding(11).background(Color(hex: 0x141519), in: RoundedRectangle(cornerRadius: 8)) }
                if model.selectedVoice.contains("Custom Voice Clone") {
                    HStack { Image(systemName: "waveform.badge.mic").foregroundStyle(Color(hex: 0xCDAA79)); Text(model.voiceSampleName).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)); Spacer(); Button("Choose reference") { showVoiceImporter = true }.buttonStyle(SoftButtonStyle()) }
                    TextField("Exact transcript spoken in the reference audio", text: $model.referenceTranscript, axis: .vertical).lineLimit(2...4).textFieldStyle(.plain).font(.system(size: 11)).padding(10).background(Color(hex: 0x141519), in: RoundedRectangle(cornerRadius: 8))
                    Text("Use a clean reference with one speaker and enter its exact transcript. Only use a voice you have permission to clone.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.38))
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) { sectionLabel("NAME PRONUNCIATIONS", detail: "One rule per line: spelling = how it sounds"); TextField("Aarav = aa-rahv    ·    Thiruvananthapuram = thiru-van-an-tha-pu-ram", text: $model.pronunciationRules, axis: .vertical).lineLimit(2...3).textFieldStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.72)).padding(10).background(Color(hex: 0x141519), in: RoundedRectangle(cornerRadius: 8)) }
                }
            }
            HStack {
                HStack(spacing: 8) { Image(systemName: model.remoteAvailable ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(model.remoteAvailable ? Color(hex: 0x72C7A4) : Color(hex: 0xD79273)); Text(model.remoteAvailable ? "Fish Audio S2.1 Pro via your OpenRouter service" : "Start the existing service at localhost:5070").font(.system(size: 11)).foregroundStyle(.white.opacity(0.52)) }
                Spacer()
                Button { Task { await model.generateSpeech() } } label: { Label(model.isGenerating ? "Generating…" : "Generate performance", systemImage: model.isGenerating ? "hourglass" : "waveform").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x171615)).padding(.horizontal, 18).padding(.vertical, 12).background(LinearGradient(colors: [Color(hex: 0xE7C99D), Color(hex: 0xC99F6F)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain).disabled(model.isGenerating || !model.remoteAvailable).opacity(model.isGenerating || !model.remoteAvailable ? 0.55 : 1)
            }
            latestOutput
        }
    }

    private var musicStudio: some View {
        VStack(alignment: .leading, spacing: 18) {
            panel {
                HStack { sectionLabel("MUSIC BRIEF", detail: "Describe the scene, instrumentation, texture, and energy"); Spacer(); Text("LOCAL · APPLE SILICON").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(Color(hex: 0x77C4A1)) }
                TextEditor(text: $model.musicPrompt).font(.system(size: 14, design: .serif)).scrollContentBackground(.hidden).foregroundStyle(Color(hex: 0xE9E5DE)).frame(minHeight: 150).padding(10).background(Color(hex: 0x141519), in: RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) { sectionLabel("LENGTH", detail: model.musicEditMode == "Continue" ? "Seconds to add" : "Seconds"); Slider(value: $model.musicSeconds, in: 10...(model.musicEditMode == "Continue" ? 112 : 120), step: 2).tint(Color(hex: 0xCDAA79)); Text("\(Int(model.musicSeconds)) sec\(model.musicEditMode == "Continue" ? " added" : "")").font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.57)) }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) { sectionLabel("MODEL", detail: "Optimized for your M1 Pro"); HStack { Image(systemName: "cpu").foregroundStyle(Color(hex: 0xCDAA79)); Picker("Music quality", selection: $model.musicQuality) { Text(model.mediumModelAvailable ? "Cinematic · Medium" : "Cinematic · Medium (not installed)").tag("Cinematic · Medium").disabled(!model.mediumModelAvailable); Text("Fast · Small").tag("Fast · Small") }.labelsHidden().pickerStyle(.menu).font(.system(size: 12, weight: .medium)).padding(.top, 1) }.padding(.top, 6) }.frame(maxWidth: .infinity, alignment: .leading)
                }
                editControls(for: true)
                qualityControls
            }
            HStack { Text("Use More like this for related takes, Replace region to revise a section, or Continue to extend a cue.").font(.system(size: 11, design: .serif)).italic().foregroundStyle(.white.opacity(0.4)); Spacer(); generateButton("Compose music", icon: "music.note", enabled: model.soundEngineAvailable) { Task { await model.generateSound(kind: .music) } } }
            latestOutput
        }
    }

    private var effectsStudio: some View {
        VStack(alignment: .leading, spacing: 18) {
            panel {
                sectionLabel("SOUND DESIGN BRIEF", detail: "Describe the source, distance, material, space, and movement")
                TextEditor(text: $model.fxPrompt).font(.system(size: 14, design: .serif)).scrollContentBackground(.hidden).foregroundStyle(Color(hex: 0xE9E5DE)).frame(minHeight: 150).padding(10).background(Color(hex: 0x141519), in: RoundedRectangle(cornerRadius: 10)).overlay(alignment: .topLeading) { if model.fxPrompt.isEmpty { Text("A single mouse click, close-miked, dry, a small plastic switch with a crisp release.").font(.system(size: 14, design: .serif)).foregroundStyle(.white.opacity(0.25)).padding(.leading, 16).padding(.top, 18).allowsHitTesting(false) } }
                Menu {
                    Button("Wind through trees · leaves rustling") { model.fxPrompt = "Steady outdoor wind moving through a stand of trees, individual leaves and fine branches rustling and swaying at different distances, natural irregular gusts, open woodland ambience, no microphone wind noise, no music or voices." }
                    Button("Wind across grass · low field-level") { model.fxPrompt = "Low field-level perspective of a breeze sweeping across tall meadow grass, soft seed heads and blades brushing together in waves, gentle gusts pass left to right, open rural air, no trees, no voices, no music." }
                    Button("Desk chair sliding on wood floor") { model.fxPrompt = "An office desk chair with small casters rolling and scraping a short distance across a hard wooden floor, slight creak and wheel rattle, close indoor perspective, one natural movement and stop, no speech or music." }
                    Button("Sliding door · heavy track") { model.fxPrompt = "A heavy sliding door opening along a metal track, low rolling rumble with a brief gritty scrape and a solid stop, close interior perspective, single action, no voices or music." }
                } label: { Label("Prompt examples", systemImage: "text.quote").font(.system(size: 10, weight: .medium)).foregroundStyle(Color(hex: 0xD8B98E)) }
                Text("Describe what makes the sound, what moves against what, distance, space, and whether it is one action or a continuous bed. The examples below distinguish common concepts the model confuses.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.42))
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) { sectionLabel("LENGTH", detail: model.fxEditMode == "Continue" ? "Seconds to add" : "Seconds"); Slider(value: $model.fxSeconds, in: 2...30, step: 1).tint(Color(hex: 0xCDAA79)); Text("\(Int(model.fxSeconds)) sec\(model.fxEditMode == "Continue" ? " added" : "")").font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.57)) }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) { sectionLabel("MODEL", detail: "Local foley and ambience"); HStack { Image(systemName: "waveform.path.ecg").foregroundStyle(Color(hex: 0xCDAA79)); Text("Stable Audio 3 · Small SFX").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.72)) }.padding(.top, 6) }.frame(maxWidth: .infinity, alignment: .leading)
                }
                editControls(for: false)
                qualityControls
            }
            HStack { Text("For critical Foley, render several candidates and audition them; results still depend on the local model.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)); Spacer(); generateButton("Render sound", icon: "sparkles", enabled: model.soundEngineAvailable) { Task { await model.generateSound(kind: .effects) } } }
            latestOutput
        }
    }

    private var workspaceStudio: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                statCard("\(model.clips.count)", label: "AUDIO CLIPS", icon: "waveform")
                statCard("\(model.clips.filter { $0.kind == "Voice" }.count)", label: "VOICE TAKES", icon: "mic")
                statCard("\(model.clips.filter { $0.kind == "Music" || $0.kind == "Sound FX" }.count)", label: "SCORE & FOLEY", icon: "music.note")
            }
            panel {
                HStack { sectionLabel("TIMELINE LAYERS", detail: "Set start offsets and levels; clips are mixed from their chosen start time"); Spacer(); Button { model.makeMixdown() } label: { Label("Export mixdown", systemImage: "square.and.arrow.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(hex: 0x171615)).padding(.horizontal, 13).padding(.vertical, 9).background(Color(hex: 0xD9B98D), in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain).disabled(model.clips.isEmpty) }
                if model.clips.isEmpty { emptyWorkspace }
                else {
                    VStack(spacing: 0) {
                        ForEach(model.clips) { clip in clipRow(clip) }
                    }.background(Color(hex: 0x141519), in: RoundedRectangle(cornerRadius: 10))
                    Text("Each layer can start at a different point. Export overlays the clips and saves a 24-bit WAV mix in Audio/Mixes.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.38))
                }
            }
            HStack { Button { model.selectWorkspace() } label: { Label("Change project folder", systemImage: "folder").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.62)) }.buttonStyle(.plain); Spacer(); Button { model.showOutputFolder() } label: { Label("Open workspace in Finder", systemImage: "arrow.up.right.square").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.62)) }.buttonStyle(.plain) }
        }
    }

    private var latestOutput: some View {
        Group {
            if let clip = model.clips.first {
                panel {
                    let active = model.clips.first(where: { $0.id == model.activeClipID }) ?? clip
                    HStack(spacing: 14) {
                        Button { model.togglePlayback(active) } label: { Image(systemName: model.playingClip == active.id ? "pause.fill" : "play.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(Color(hex: 0x171615)).frame(width: 40, height: 40).background(Color(hex: 0xD8B98E), in: Circle()) }.buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 4) { Text(model.activeClipID == nil ? "LATEST TAKE" : (model.playingClip == active.id ? "NOW PLAYING" : "PAUSED")).font(.system(size: 9, weight: .bold)).tracking(1.5).foregroundStyle(Color(hex: 0xCDAA79)); Text(active.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.85)) }
                        Spacer()
                        Text(active.kind.uppercased()).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.42)).padding(.horizontal, 10).padding(.vertical, 6).background(Color.white.opacity(0.055), in: Capsule())
                        Button { NSWorkspace.shared.activateFileViewerSelecting([active.url]) } label: { Image(systemName: "arrow.down.to.line").foregroundStyle(.white.opacity(0.62)) }.buttonStyle(.plain).help("Show audio file")
                    }
                    HStack(spacing: 10) {
                        Button { model.seekPlayback(to: max(0, model.playbackTime - 5)) } label: { Image(systemName: "gobackward.5") }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.58)).help("Back 5 seconds")
                        Slider(value: Binding(get: { model.playbackTime }, set: { model.seekPlayback(to: $0) }), in: 0...max(0.1, model.playbackDuration)).tint(Color(hex: 0xD8B98E))
                        Button { model.seekPlayback(to: min(model.playbackDuration, model.playbackTime + 5)) } label: { Image(systemName: "goforward.5") }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.58)).help("Forward 5 seconds")
                        Text("\(model.formattedTime(model.playbackTime)) / \(model.formattedTime(model.playbackDuration))").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.48)).frame(width: 84, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var qualityControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    sectionLabel("DETAIL", detail: "More steps take longer; 8 is the model's documented sweet spot")
                    Picker("Steps", selection: $model.soundSteps) { Text("8 · Recommended").tag(8.0); Text("12 · Slower").tag(12.0); Text("16 · Slowest").tag(16.0) }.labelsHidden().pickerStyle(.menu)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    sectionLabel("CANDIDATES", detail: "Render multiple takes to audition")
                    Picker("Candidate count", selection: $model.candidateCount) { ForEach(1...4, id: \.self) { Text("\($0) take\($0 == 1 ? "" : "s")").tag(Double($0)) } }.labelsHidden().pickerStyle(.menu)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    sectionLabel("PROMPT GUIDANCE", detail: "Higher guidance costs more time")
                    Picker("Guidance", selection: $model.soundGuidance) { Text("Off · 1.0").tag(1.0); Text("Gentle · 2.0").tag(2.0); Text("Strong · 3.0").tag(3.0) }.labelsHidden().pickerStyle(.menu)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Toggle(isOn: $model.noiseCleanupEnabled) {
                VStack(alignment: .leading, spacing: 2) { Text("Gentle noise cleanup after render").font(.system(size: 11, weight: .medium)); Text("FFmpeg spectral denoise can reduce a hiss floor; switch it off for rain, wind, or delicate room tone.").font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)) }
            }.toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(.white.opacity(0.72))
            if model.soundGuidance != 1 { TextField("Optional exclusions (e.g. music, voices, wind buffeting)", text: $model.negativePrompt).textFieldStyle(.plain).font(.system(size: 11)).padding(9).background(Color(hex: 0x141519), in: RoundedRectangle(cornerRadius: 8)) }
        }
    }

    @ViewBuilder private func editControls(for music: Bool) -> some View {
        let mode = music ? $model.musicEditMode : $model.fxEditMode
        let options = music ? ["New score", "More like this", "Replace region", "Continue"] : ["New sound", "More like this", "Replace region", "Continue"]
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    sectionLabel("EDIT FROM", detail: "Use a generated or imported workspace clip")
                    Picker("Edit mode", selection: mode) { ForEach(options, id: \.self) { Text($0).tag($0) } }.labelsHidden().pickerStyle(.menu)
                }.frame(width: 170, alignment: .leading)
                if mode.wrappedValue != (music ? "New score" : "New sound") {
                    VStack(alignment: .leading, spacing: 4) {
                        sectionLabel("SOURCE CLIP", detail: "Choose a clip to vary or edit")
                        Picker("Source clip", selection: $model.editSourceID) {
                            Text("Choose clip…").tag(nil as UUID?)
                            ForEach(model.sourceClips) { clip in Text("\(clip.kind) · \(clip.name)").tag(clip.id as UUID?) }
                        }.labelsHidden().pickerStyle(.menu)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if mode.wrappedValue == "More like this" {
                        VStack(alignment: .leading, spacing: 4) { sectionLabel("VARIATION", detail: "Lower stays closer to the source"); Slider(value: $model.variationStrength, in: 0.4...0.8, step: 0.05).tint(Color(hex: 0xCDAA79)); Text(String(format: "Noise %.2f", model.variationStrength)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.5)) }.frame(maxWidth: 130)
                    }
                }
            }
            if mode.wrappedValue == "Replace region", model.editSourceID != nil {
                VStack(alignment: .leading, spacing: 3) {
                    sectionLabel("REGENERATE REGION", detail: "Everything outside this range is kept from the source")
                    Slider(value: $model.inpaintStart, in: 0...max(0.1, model.selectedSourceDuration - 0.2), step: 0.1).tint(Color(hex: 0x8C88D8))
                    Slider(value: $model.inpaintEnd, in: max(0.1, model.inpaintStart + 0.1)...max(0.2, model.selectedSourceDuration), step: 0.1).tint(Color(hex: 0x8C88D8))
                    Text("\(model.formattedTime(model.inpaintStart)) – \(model.formattedTime(model.inpaintEnd))").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.52))
                }
            }
            if mode.wrappedValue == "Continue" { Text("The model regenerates the last 1.5 seconds as a seam, then creates the added section. Longer continuations are slower and may drift from the original cue.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.4)) }
        }
        .padding(10).background(Color(hex: 0x141519).opacity(0.75), in: RoundedRectangle(cornerRadius: 9))
    }

    private var emptyWorkspace: some View {
        VStack(spacing: 12) { Image(systemName: "waveform.path").font(.system(size: 28, weight: .light)).foregroundStyle(Color(hex: 0xC5A274).opacity(0.8)); Text("Your first take goes here").font(.system(size: 15, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.72)); Text("Create speech, score, or sound design, then build your mix in this project.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.38)).multilineTextAlignment(.center) }.frame(maxWidth: .infinity).padding(.vertical, 42)
    }

    private func clipRow(_ clip: AudioClip) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { model.togglePlayback(clip) } label: { Image(systemName: model.playingClip == clip.id ? "pause.fill" : "play.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(hex: 0xD8B98E)).frame(width: 25, height: 25).background(Color.white.opacity(0.07), in: Circle()) }.buttonStyle(.plain)
                RoundedRectangle(cornerRadius: 2).fill(colorFor(clip.kind)).frame(width: 3, height: 26)
                VStack(alignment: .leading, spacing: 3) { Text(clip.name).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.84)); Text("\(clip.kind.uppercased()) · \(clip.createdAt.formatted(date: .omitted, time: .shortened))").font(.system(size: 9, weight: .medium)).tracking(0.7).foregroundStyle(.white.opacity(0.37)) }
                Spacer(minLength: 5)
                Text("START").font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.3))
                TextField("0", value: binding(for: clip, keyPath: \.offset), format: .number.precision(.fractionLength(1))).textFieldStyle(.plain).font(.system(size: 10, design: .monospaced)).frame(width: 45).padding(6).background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
                Text("s").font(.system(size: 10)).foregroundStyle(.white.opacity(0.36))
                Text("LEVEL").font(.system(size: 8, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.3)).padding(.leading, 6)
                Slider(value: binding(for: clip, keyPath: \.gain), in: 0...1.5).tint(colorFor(clip.kind)).frame(width: 80)
                Button { model.removeClip(clip) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.34)).padding(6) }.buttonStyle(.plain).help("Remove from project")
            }.padding(.horizontal, 12).padding(.vertical, 10)
            if clip.id != model.clips.last?.id { Rectangle().fill(Color.white.opacity(0.055)).frame(height: 1).padding(.leading, 48) }
        }
    }

    private func binding(for clip: AudioClip, keyPath: WritableKeyPath<AudioClip, Double>) -> Binding<Double> {
        Binding(get: { model.clips.first(where: { $0.id == clip.id })?[keyPath: keyPath] ?? clip[keyPath: keyPath] }, set: { value in var updated = model.clips.first(where: { $0.id == clip.id }) ?? clip; updated[keyPath: keyPath] = value; model.updateClip(updated) })
    }
    private func colorFor(_ kind: String) -> Color { if kind == "Voice" { Color(hex: 0xD5AA78) } else if kind == "Music" { Color(hex: 0x8C88D8) } else if kind == "Sound FX" { Color(hex: 0x79B9A4) } else { Color(hex: 0x9C9C9E) } }
    private func statCard(_ value: String, label: String, icon: String) -> some View {
        HStack(spacing: 12) { Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Color(hex: 0xD1AC7D)); VStack(alignment: .leading, spacing: 4) { Text(value).font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(.white.opacity(0.88)); Text(label).font(.system(size: 8, weight: .bold)).tracking(1.1).foregroundStyle(.white.opacity(0.37)) } }.frame(maxWidth: .infinity, alignment: .leading).padding(15).background(Color(hex: 0x151619), in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.055), lineWidth: 1))
    }

    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content).padding(17).background(Color(hex: 0x17181B), in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.white.opacity(0.065), lineWidth: 1))
    }
    private func sectionLabel(_ label: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(label).font(.system(size: 9, weight: .bold)).tracking(1.5).foregroundStyle(.white.opacity(0.78)); Text(detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.38)) }
    }
    private func generateButton(_ title: String, icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(model.isGenerating ? "Rendering…" : title, systemImage: model.isGenerating ? "hourglass" : icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0x171615)).padding(.horizontal, 17).padding(.vertical, 11).background(Color(hex: 0xD8B98E), in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain).disabled(!enabled || model.isGenerating).opacity(!enabled || model.isGenerating ? 0.5 : 1)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Circle().fill(model.status.contains("failed") || model.status.contains("not found") ? Color(hex: 0xD79273) : Color(hex: 0x72C7A4)).frame(width: 6, height: 6)
            Text(model.status).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            Spacer()
            Text("\(model.clips.count) PROJECT ASSETS").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.white.opacity(0.32))
        }.padding(.horizontal, 24).frame(height: 38).background(Color(hex: 0x101114)).overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
    }

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text("Engines & workspace").font(.system(size: 22, weight: .semibold, design: .rounded)); Text("Keep creation in one local project folder.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.48)) }; Spacer(); Button { showSettings = false } label: { Image(systemName: "xmark").foregroundStyle(.white.opacity(0.55)).padding(8).background(Color.white.opacity(0.07), in: Circle()) }.buttonStyle(.plain) }
            VStack(alignment: .leading, spacing: 8) {
                Text("OPENROUTER AUTHENTICATION").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(Color(hex: 0xD0AD7E))
                HStack(spacing: 8) { SecureField("Paste rotated OpenRouter API key", text: $model.openRouterAPIKey).textFieldStyle(.plain).padding(10).background(Color(hex: 0x141519), in: RoundedRectangle(cornerRadius: 8)); Button("Save in Keychain") { model.saveOpenRouterKey() }.buttonStyle(SoftButtonStyle()) }
                Text("The key is stored in macOS Keychain and sent only to your local voice service for synthesis.").font(.system(size: 10)).foregroundStyle(.white.opacity(0.43))
            }
            settingsRow("Voice performance", status: model.remoteAvailable ? "Connected · localhost:5070" : "Not connected", detail: "Speech is synthesized by Fish Audio S2.1 Pro through your local OpenRouter service.", ok: model.remoteAvailable)
            settingsRow("Music & sound effects", status: model.soundEngineAvailable ? "Stable Audio MLX ready" : "Needs one-time setup", detail: model.soundEngineAvailable ? (model.mediumModelAvailable ? "Small Music and SFX ready; Medium music ready for the cinematic setting." : "Small Music and SFX ready. Medium music weights are not installed yet.") : "The local runtime installs here; model weights download after Hugging Face access is accepted.", ok: model.soundEngineAvailable)
            if !model.soundEngineAvailable {
                VStack(alignment: .leading, spacing: 8) {
                    Text("One-time requirements").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(Color(hex: 0xD0AD7E))
                    Button { installStableRuntime() } label: { Label(model.installingAudio ? "Setting up runtime…" : "Install local audio engine", systemImage: "arrow.down.to.line.compact").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(hex: 0x171615)).padding(.horizontal, 13).padding(.vertical, 9).background(Color(hex: 0xD8B98E), in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain).disabled(model.installingAudio)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("HUGGING FACE ACCESS").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(Color(hex: 0xD0AD7E))
                Text(model.huggingFaceConnected ? "Account connected on this Mac. If generation still reports access denied, accept the model terms on the model page." : "Connect your account here. Your token is entered in Terminal and stored by Hugging Face’s local CLI, not by CineScope.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.57)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Link("Accept model access", destination: URL(string: "https://huggingface.co/stabilityai/stable-audio-3-optimized")!).font(.system(size: 10, weight: .medium)).foregroundStyle(Color(hex: 0xD9B98E))
                    Button(model.huggingFaceConnected ? "Signed in" : "Connect Hugging Face") { model.openHuggingFaceLogin() }.buttonStyle(SoftButtonStyle()).disabled(model.huggingFaceConnected)
                    Button("Refresh status") { Task { await model.refreshHuggingFaceStatus() } }.buttonStyle(SoftButtonStyle())
                    Text(model.mediumModelAvailable ? "Medium music · ready" : "Medium music · not installed").font(.system(size: 10, weight: .medium)).foregroundStyle(model.mediumModelAvailable ? Color(hex: 0x83C9AA) : Color(hex: 0xD8B98E))
                }
            }
            Divider().overlay(Color.white.opacity(0.1))
            HStack { VStack(alignment: .leading, spacing: 4) { Text("Current project").font(.system(size: 12, weight: .semibold)); Text(model.workspaceURL.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.39)).lineLimit(1) }; Spacer(); Button("Choose folder") { model.selectWorkspace() }.buttonStyle(SoftButtonStyle()) }
            HStack { Spacer(); Button("Done") { showSettings = false }.buttonStyle(SoftButtonStyle()) }
        }
        .padding(24).frame(width: 520).background(Color(hex: 0x17181B)).preferredColorScheme(.dark)
    }
    private func settingsRow(_ title: String, status: String, detail: String, ok: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) { Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? Color(hex: 0x72C7A4) : Color(hex: 0xD3AC7C)).padding(.top, 1); VStack(alignment: .leading, spacing: 4) { HStack { Text(title).font(.system(size: 12, weight: .semibold)); Spacer(); Text(status).font(.system(size: 10, weight: .medium)).foregroundStyle(ok ? Color(hex: 0x83C9AA) : Color(hex: 0xD8B98E)) }; Text(detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.43)).fixedSize(horizontal: false, vertical: true) } }
    }
    private func installStableRuntime() {
        guard !model.installingAudio else { return }
        model.installingAudio = true
        model.status = "Installing the Apple silicon audio runtime…"
        Task.detached(priority: .userInitiated) {
            do {
                let fm = FileManager.default
                let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cinema Audio Studio", isDirectory: true)
                try fm.createDirectory(at: support, withIntermediateDirectories: true)
                let runtime = support.appendingPathComponent("StableAudio", isDirectory: true)
                let bundled = Bundle.main.resourceURL?.appendingPathComponent("StableAudio", isDirectory: true)
                if !fm.fileExists(atPath: runtime.appendingPathComponent("optimized/mlx/install.sh").path), let bundled, fm.fileExists(atPath: bundled.appendingPathComponent("optimized/mlx/install.sh").path) {
                    try fm.copyItem(at: bundled, to: runtime)
                }
                if !fm.fileExists(atPath: runtime.appendingPathComponent("optimized/mlx/install.sh").path) {
                    let archive = support.appendingPathComponent("stable-audio-3.tar.gz")
                    let download = Process(); download.executableURL = URL(fileURLWithPath: "/usr/bin/curl"); download.arguments = ["-L", "--fail", "--silent", "--show-error", "https://github.com/Stability-AI/stable-audio-3/archive/refs/heads/main.tar.gz", "-o", archive.path]
                    try download.run(); download.waitUntilExit()
                    guard download.terminationStatus == 0 else { throw StudioError.message("Could not download the official Stable Audio runtime source.") }
                    try fm.createDirectory(at: runtime, withIntermediateDirectories: true)
                    let tar = Process(); tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); tar.arguments = ["-xzf", archive.path, "-C", runtime.path, "--strip-components=1"]
                    try tar.run(); tar.waitUntilExit()
                    guard tar.terminationStatus == 0 else { throw StudioError.message("Could not unpack Stable Audio runtime files.") }
                }
                let mlxFolder = runtime.appendingPathComponent("optimized/mlx", isDirectory: true)
                let logURL = support.appendingPathComponent("runtime-install.log")
                fm.createFile(atPath: logURL.path, contents: nil)
                let logHandle = try FileHandle(forWritingTo: logURL)
                let install = Process(); install.executableURL = URL(fileURLWithPath: "/bin/bash"); install.arguments = ["install.sh", "-y"]; install.currentDirectoryURL = mlxFolder
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                install.environment = environment; install.standardOutput = logHandle; install.standardError = logHandle
                try install.run(); install.waitUntilExit(); try? logHandle.close()
                guard install.terminationStatus == 0 else {
                    let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                    throw StudioError.message("Runtime setup failed. See ~/Library/Application Support/Cinema Audio Studio/runtime-install.log. \(log.suffix(450))")
                }
                await MainActor.run {
                    model.installingAudio = false
                    model.soundEnginePath = mlxFolder.appendingPathComponent("sa3").path
                    model.soundEngineAvailable = true
                    model.status = "Local runtime ready · Stable Audio weights download on first generation"
                }
            } catch {
                await MainActor.run { model.installingAudio = false; model.errorMessage = error.localizedDescription; model.status = "Audio engine setup needs attention" }
            }
        }
    }
}

struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.font(.system(size: 11, weight: .semibold)).foregroundStyle(Color(hex: 0xE1C49C)).padding(.horizontal, 12).padding(.vertical, 8).background(Color.white.opacity(configuration.isPressed ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 8)) }
}

extension Color {
    init(hex: UInt, opacity: Double = 1) { self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: opacity) }
}
