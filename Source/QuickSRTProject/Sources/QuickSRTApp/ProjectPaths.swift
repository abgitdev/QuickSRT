import Foundation

public enum ProjectRootResolver {
    public static func resolve(
        environmentRoot: String?,
        bundleURL: URL,
        bundledSupportRoot: URL?,
        applicationSupportRoot: URL,
        desktopRoot: URL,
        isUsableRoot: (URL) -> Bool
    ) -> URL {
        var current = bundleURL.standardizedFileURL
        for _ in 0..<8 {
            if isUsableRoot(current) {
                if let environmentRoot, !environmentRoot.isEmpty {
                    return URL(fileURLWithPath: environmentRoot, isDirectory: true)
                }
                return current
            }

            let parent = current.deletingLastPathComponent()
            if parent == current {
                break
            }
            current = parent
        }

        // The expected support location of an installed application is
        // authoritative even when the directory is damaged or missing.
        // Falling back to an environment-selected runtime after bundle damage
        // would turn an integrity failure into arbitrary code execution.
        if let bundledSupportRoot {
            return bundledSupportRoot
        }

        if let environmentRoot, !environmentRoot.isEmpty {
            return URL(fileURLWithPath: environmentRoot, isDirectory: true)
        }

        if isUsableRoot(applicationSupportRoot) {
            return applicationSupportRoot
        }

        if isUsableRoot(desktopRoot) {
            return desktopRoot
        }

        return applicationSupportRoot
    }
}

public enum ProjectPaths {
    private static let selectedModelKey = "QuickSRT.selectedMLXModelPath"

    static var root: URL {
        let desktopRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent("QuickSRT")
        let applicationSupportRoot = self.applicationSupportRoot

        let bundledSupportRoot = Bundle.main.resourceURL?
            .appendingPathComponent("QuickSRTSupport", isDirectory: true)

        return ProjectRootResolver.resolve(
            environmentRoot: ProcessInfo.processInfo.environment["QUICKSRT_HOME"],
            bundleURL: Bundle.main.bundleURL,
            bundledSupportRoot: bundledSupportRoot,
            applicationSupportRoot: applicationSupportRoot,
            desktopRoot: desktopRoot,
            isUsableRoot: isProjectRoot
        )
    }

    static var applicationSupportRoot: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("QuickSRT", isDirectory: true)
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/QuickSRT", isDirectory: true)
    }

    static var ffmpeg: URL {
        root.appendingPathComponent("Tools/ffmpeg")
    }

    static var ffprobe: URL {
        root.appendingPathComponent("Tools/ffprobe")
    }

    static var python: URL {
        root.appendingPathComponent("Runtime/Support/venv/bin/python")
    }

    static var mlxWhisperModel: URL {
        modelsRoot.appendingPathComponent("Whisper/large-v3")
    }

    static var mlxWhisperModelsRoot: URL {
        modelsRoot.appendingPathComponent("MLX-Whisper", isDirectory: true)
    }

    static var mlxWhisperRunner: URL {
        root.appendingPathComponent("Scripts/mlx_transcribe_srt.py")
    }

    static var mlxWhisperDownloader: URL {
        root.appendingPathComponent("Scripts/download_mlx_whisper_model.py")
    }

    static var mlxWhisperModelPolicy: URL {
        root.appendingPathComponent("Runtime/model-policy.json")
    }

    static let mlxWhisperRepositoryID = "mlx-community/whisper-large-v3-mlx"
    static let mlxWhisperRevision = "49e6aa286ad60c14352c404340ded53710378a11"
    static let mlxWhisperPolicyID = "quicksrt-whisper-large-v3-49e6aa286ad60c14352c404340ded53710378a11"

    private static var modelsRoot: URL {
        if FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Source/QuickSRTProject").path
        ) {
            return root.appendingPathComponent("Models", isDirectory: true)
        }
        return applicationSupportRoot.appendingPathComponent("Models", isDirectory: true)
    }

    static func resolvedMLXWhisperModel() -> URL? {
        if
            let selectedPath = UserDefaults.standard.string(forKey: selectedModelKey),
            let selected = findModel(in: URL(fileURLWithPath: selectedPath, isDirectory: true)),
            isManagedModel(selected)
        {
            return selected
        }

        let direct = mlxWhisperModel
        if isMLXModelDirectory(direct) {
            return direct
        }

        return findModel(in: mlxWhisperModelsRoot)
    }

    static func selectModel(at url: URL) -> URL? {
        guard let model = findModel(in: url), isManagedModel(model) else {
            return nil
        }
        UserDefaults.standard.set(model.path, forKey: selectedModelKey)
        return model
    }

    static func useManagedModel() -> URL? {
        UserDefaults.standard.removeObject(forKey: selectedModelKey)
        return findModel(in: mlxWhisperModelsRoot)
    }

    static func isManagedModel(_ url: URL) -> Bool {
        let modelPath = url.standardizedFileURL.path
        let rootPath = mlxWhisperModelsRoot.standardizedFileURL.path + "/"
        return modelPath.hasPrefix(rootPath)
    }

    public static func findModel(in root: URL) -> URL? {
        if isMLXModelDirectory(root) {
            return root
        }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var matches: [URL] = []
        for case let item as URL in enumerator {
            if isMLXModelDirectory(item) {
                matches.append(item)
                enumerator.skipDescendants()
            }
        }

        return matches.sorted { left, right in
            let leftScore = scoreModelPath(left)
            let rightScore = scoreModelPath(right)
            if leftScore == rightScore {
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return leftDate > rightDate
            }
            return leftScore > rightScore
        }.first
    }

    static func supportsMultilingualTranscription(at modelURL: URL) -> Bool {
        let configURL = modelURL.appendingPathComponent("config.json")
        guard
            let data = try? Data(contentsOf: configURL),
            let object = try? JSONSerialization.jsonObject(with: data),
            let config = object as? [String: Any],
            let vocabularySize = config["n_vocab"] as? NSNumber
        else {
            return false
        }

        // This is the same capability rule used by the bundled mlx_whisper runtime.
        return vocabularySize.intValue >= 51_865
    }

    static var tempRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("QuickSRT", isDirectory: true)
    }

    static var outputManifest: URL {
        applicationSupportRoot.appendingPathComponent("output-manifest.json")
    }

    private static func isProjectRoot(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Source/QuickSRTProject").path) {
            return true
        }

        return FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Tools/ffmpeg").path)
            && FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Tools/ffprobe").path)
            && FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("Runtime/Support/venv/bin/python").path)
            && FileManager.default.fileExists(atPath: url.appendingPathComponent("Scripts/mlx_transcribe_srt.py").path)
            && FileManager.default.fileExists(atPath: url.appendingPathComponent("Scripts/download_mlx_whisper_model.py").path)
    }

    private static func isMLXModelDirectory(_ url: URL) -> Bool {
        let config = url.appendingPathComponent("config.json")
        let npz = url.appendingPathComponent("weights.npz")
        let manifest = url.appendingPathComponent("model-manifest.json")
        guard
            FileManager.default.fileExists(atPath: config.path),
            FileManager.default.fileExists(atPath: npz.path),
            let configSize = try? config.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            let weightsSize = try? npz.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            configSize == 269,
            weightsSize == 3_083_520_416,
            let data = try? Data(contentsOf: manifest),
            let object = try? JSONSerialization.jsonObject(with: data),
            let values = object as? [String: Any],
            values["schema_version"] as? Int == 1,
            values["policy_id"] as? String == mlxWhisperPolicyID,
            values["repository_id"] as? String == mlxWhisperRepositoryID,
            values["revision"] as? String == mlxWhisperRevision
        else {
            return false
        }
        return true
    }

    private static func scoreModelPath(_ url: URL) -> Int {
        let path = url.path.lowercased()
        var score = 0
        if path.contains("large-v3") { score += 100 }
        if path.contains("whisper") { score += 50 }
        if path.contains("/snapshots/") { score += 10 }
        if path == mlxWhisperModel.path.lowercased() { score += 1_000 }
        return score
    }
}
