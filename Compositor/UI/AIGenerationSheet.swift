import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct AIGenerationReference: Identifiable {
    let id = UUID()
    let name: String
    let imageData: Data
    let thumbnailData: Data
}

struct AIGenerationSheet: View {
    @Bindable var session: EditorSession
    @AppStorage("aiImage.endpoint") private var endpoint = "https://cloudapi.flowingcloud.com"
    @AppStorage("aiImage.model") private var model = "gpt-image-2"
    @AppStorage("aiImage.quality") private var quality = "high"
    @State private var apiKey = ""
    @State private var prompt = ""
    @State private var references: [AIGenerationReference] = []
    @State private var showsReferenceImporter = false
    @State private var showsAPISettings = false
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    private var canGenerate: Bool {
        session.document != nil && !session.isGeneratingImage
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (isLocalEndpoint || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private var isLocalEndpoint: Bool {
        guard let host = URL(string: endpoint)?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }
    private var hasSelection: Bool { session.selection != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(hasSelection ? "Generative Fill" : "Generate Image", systemImage: hasSelection ? "selection.pin.in.out" : "sparkles")
                    .font(.headline)
                Text(hasSelection
                     ? "Describe what should appear inside the selected area. The surrounding canvas guides the result."
                     : "Describe an image to create. The current canvas will guide the edit.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $prompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 110)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topLeading) {
                        if prompt.isEmpty {
                            Text(hasSelection ? "What should fill the selection?" : "Describe the image…")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11).padding(.vertical, 14)
                                .allowsHitTesting(false)
                        }
                    }

                HStack {
                    Text("Reference images").font(.subheadline.weight(.medium))
                    Spacer()
                    Button("Add images…") { showsReferenceImporter = true }
                        .disabled(session.isGeneratingImage || references.count >= 15)
                }
                if references.isEmpty {
                    Text("Optional. Reference images are sent after the current canvas.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(references) { reference in
                            HStack(spacing: 8) {
                                if let image = NSImage(data: reference.thumbnailData) {
                                    Image(nsImage: image).resizable().scaledToFill()
                                        .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 5))
                                }
                                Text(reference.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    references.removeAll { $0.id == reference.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain).help("Remove reference image")
                            }
                        }
                    }
                }

                DisclosureGroup("Image API settings", isExpanded: $showsAPISettings) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("OpenAI-compatible API base URL")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("API base URL", text: $endpoint)
                            .textFieldStyle(.roundedBorder)
                        TextField("Model", text: $model)
                            .textFieldStyle(.roundedBorder)
                        SecureField("API key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Picker("Quality", selection: $quality) {
                                Text("Low").tag("low")
                                Text("Medium").tag("medium")
                                Text("High").tag("high")
                            }
                            .frame(width: 165)
                            Spacer()
                            Button("Save settings") { saveSettings() }
                        }
                        Text("The API key is stored in macOS Keychain. Canvas and reference images are sent to this endpoint. A local endpoint may omit the key.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline.weight(.medium))

                if let infoMessage {
                    Text(infoMessage).font(.caption).foregroundStyle(.secondary)
                }
                if let errorMessage {
                    Text(errorMessage).font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    if session.isGeneratingImage {
                        ProgressView().controlSize(.small)
                        Text("Generating…")
                        Spacer()
                        Button("Cancel") { session.cancelAIGeneration() }
                    } else {
                        Spacer()
                        Button(hasSelection ? "Generate Fill" : "Generate") { generate() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canGenerate)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(18)
        }
        .frame(width: 490, height: 650)
        .onAppear {
            prompt = session.aiGenerationInitialPrompt
            loadAPIKey()
        }
        .fileImporter(isPresented: $showsReferenceImporter,
                      allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importReferences(urls)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { errorMessage = error.localizedDescription }
            }
        }
    }

    private func loadAPIKey() {
        do { apiKey = try AIGenerationKeychain.load() }
        catch { errorMessage = error.localizedDescription }
    }

    private func saveSettings() {
        do {
            try AIGenerationKeychain.save(apiKey)
            infoMessage = "Settings saved."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            infoMessage = nil
        }
    }

    private func importReferences(_ urls: [URL]) {
        let room = max(0, 15 - references.count)
        guard room > 0 else { return }
        Task {
            for url in urls.prefix(room) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let imported = try await ImageImporter.shared.decode(url, flattenedPhotoshop: true)
                    let data = try AIGenerationImageCodec.pngData(imported.image)
                    guard data.count < 50 * 1024 * 1024 else { throw AIGenerationError.imageTooLarge }
                    let thumbnail = try AIGenerationImageCodec.pngData(try PixelInvert.thumbnail(of: imported.image))
                    references.append(AIGenerationReference(name: url.lastPathComponent,
                                                            imageData: data, thumbnailData: thumbnail))
                    errorMessage = nil
                } catch {
                    errorMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    private func generate() {
        do {
            try AIGenerationKeychain.save(apiKey)
            let snapshot = try session.makeAIGenerationSnapshot()
            let imageInputs = [snapshot.imageData] + references.map(\.imageData)
            let apiKey = self.apiKey
            let endpoint = self.endpoint
            let model = self.model
            let quality = self.quality
            let prompt = self.prompt
            let mask = snapshot.maskData
            errorMessage = nil
            infoMessage = nil
            session.cancelAIGeneration()
            session.isGeneratingImage = true
            let taskID = UUID()
            session.aiGenerationTaskID = taskID
            session.aiGenerationTask = Task { @MainActor in
                defer {
                    if session.aiGenerationTaskID == taskID {
                        session.isGeneratingImage = false
                        session.aiGenerationTask = nil
                        session.aiGenerationTaskID = nil
                    }
                }
                do {
                    let generated = try await AIGenerationClient.generate(
                        endpoint: endpoint, model: model, apiKey: apiKey, prompt: prompt,
                        quality: quality, images: imageInputs, mask: mask)
                    try Task.checkCancellation()
                    try session.insertAIGeneratedImage(generated, snapshot: snapshot)
                    self.prompt = ""
                    infoMessage = "Generated image added as a new layer."
                } catch is CancellationError {
                    infoMessage = "Generation cancelled."
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct AIGenerationPanelObserver: View {
    @Bindable var session: EditorSession
    let panel: FloatingPanelController

    var body: some View {
        Color.clear.onChange(of: session.aiGenerationPanelRequest) { _, _ in
            panel.onClose = { session.cancelAIGeneration() }
            panel.show(title: InterfaceLocalization.string("Generative Fill"),
                       content: AIGenerationSheet(session: session))
        }
    }
}

/// A Photoshop-style contextual task bar for an active pixel selection.
struct GenerativeFillContextBar: View {
    @Bindable var session: EditorSession
    @AppStorage("aiImage.contextBarEnabled") private var isEnabled = false
    @AppStorage("aiImage.endpoint") private var endpoint = "https://cloudapi.flowingcloud.com"
    @AppStorage("aiImage.model") private var model = "gpt-image-2"
    @AppStorage("aiImage.quality") private var quality = "high"
    @State private var prompt = ""
    @State private var errorMessage: String?
    @State private var infoMessage: String?

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Toggle("Generative Fill", isOn: $isEnabled)
                    .toggleStyle(.switch)
                    .fixedSize()
                if isEnabled {
                    TextField("Describe what to fill…", text: $prompt, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 240, maxWidth: 420)
                        .onSubmit(generate)
                    Button(action: generate) {
                        if session.isGeneratingImage {
                            ProgressView().controlSize(.small).tint(.black)
                        }
                        else { Label("Generate", systemImage: "sparkles") }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .disabled(session.isGeneratingImage || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button {
                        session.requestAIGenerationPanel(prompt: prompt)
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderless)
                    .help("Reference images and image API settings")
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.orange).lineLimit(2).frame(maxWidth: 420)
            } else if let infoMessage {
                Text(infoMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 5)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func generate() {
        do {
            let snapshot = try session.makeAIGenerationSnapshot()
            let apiKey = try AIGenerationKeychain.load()
            let requestPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            errorMessage = nil
            infoMessage = nil
            session.cancelAIGeneration()
            session.isGeneratingImage = true
            let taskID = UUID()
            session.aiGenerationTaskID = taskID
            session.aiGenerationTask = Task { @MainActor in
                defer {
                    if session.aiGenerationTaskID == taskID {
                        session.isGeneratingImage = false
                        session.aiGenerationTask = nil
                        session.aiGenerationTaskID = nil
                    }
                }
                do {
                    let generated = try await AIGenerationClient.generate(
                        endpoint: endpoint, model: model, apiKey: apiKey, prompt: requestPrompt,
                        quality: quality, images: [snapshot.imageData], mask: snapshot.maskData)
                    try Task.checkCancellation()
                    try session.insertAIGeneratedImage(generated, snapshot: snapshot)
                    prompt = ""
                    infoMessage = "Generated fill added as a new layer."
                } catch is CancellationError {
                    infoMessage = "Generation cancelled."
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
