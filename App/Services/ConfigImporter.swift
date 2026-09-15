import Foundation

/// One-shot importers that propose `harbor.toml` contents from existing
/// `Procfile` / `package.json` files. The user reviews the draft before saving.
enum ConfigImporter {
    struct Draft: Identifiable {
        let sourceName: String
        let notes: [String]
        let toml: String
        var id: String { sourceName }
    }

    static func drafts(in root: URL) -> [Draft] {
        var result: [Draft] = []
        let fm = FileManager.default

        let procfileURL = root.appendingPathComponent("Procfile")
        if let text = try? String(contentsOf: procfileURL, encoding: .utf8),
           let draft = fromProcfile(text, projectName: root.lastPathComponent) {
            result.append(draft)
        }

        let packageURL = root.appendingPathComponent("package.json")
        if let data = fm.contents(atPath: packageURL.path),
           let draft = fromPackageJSON(data, projectName: root.lastPathComponent) {
            result.append(draft)
        }
        return result
    }

    static func fromProcfile(_ text: String, projectName: String) -> Draft? {
        var entries: [(name: String, command: String)] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let command = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !command.isEmpty else { continue }
            entries.append((name, command))
        }
        guard !entries.isEmpty else { return nil }
        var toml = "# Draft generated from Procfile\nname = \"\(HarborConfigParser.escape(projectName))\"\n"
        for entry in entries {
            toml += "\n[[process]]\nname = \"\(HarborConfigParser.escape(entry.name))\"\ncommand = \"\(HarborConfigParser.escape(entry.command))\"\n"
        }
        return Draft(sourceName: "Procfile",
                     notes: ["Ports are not part of the Procfile format — add `port` entries manually if you want conflict detection."],
                     toml: toml)
    }

    static func fromPackageJSON(_ data: Data, projectName: String) -> Draft? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = object["scripts"] as? [String: Any],
              !scripts.isEmpty else { return nil }

        var entries: [(name: String, command: String)] = []
        for scriptName in scripts.keys.sorted() {
            // Skip npm lifecycle hooks (preX/postX) — they run via their parent script.
            if scriptName.hasPrefix("pre") || scriptName.hasPrefix("post") { continue }
            entries.append((scriptName, "npm run \(scriptName)"))
        }
        guard !entries.isEmpty else { return nil }

        var toml = "# Draft generated from package.json scripts\nname = \"\(HarborConfigParser.escape(projectName))\"\n"
        for entry in entries {
            toml += "\n[[process]]\nname = \"\(HarborConfigParser.escape(entry.name))\"\ncommand = \"\(HarborConfigParser.escape(entry.command))\"\n"
        }
        return Draft(sourceName: "package.json",
                     notes: ["Every npm script became a process — delete the ones you don't want Harbor to manage.",
                             "Ports are unknown — add `port` entries manually if you want conflict detection."],
                     toml: toml)
    }
}
