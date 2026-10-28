import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AIGenerationSheet: View {
    @Bindable var session: EditorSession
    @AppStorage("aiImage.endpoint") private var endpoint = "https://cloudapi.flowingcloud.com"
    @AppStorage("aiImage.model") private var model = "gpt-image-2"
    @AppStorage("aiImage.quality") private var quality = "high"
    @State private var apiKey = ""
    @State private var prompt = ""
    @State private var showsReferenceImporter = false
    @State private var showsAPISettings = false
    @State private var localMessage: String?

    private var hasSelection: Bool { session.selection != nil }
    private var isLocalEndpoint: Bool {
        guard let host = URL(string: endpoint)?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }
    private var canGenerate: Bool {
        session.document != nil && !session.isGeneratingImage
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (isLocalEndpoint || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(hasSelection ? "Generative Fill" : "Generate Image",
                          systemImage: hasSelection ? "selection.pin.in.out" : "sparkles")
                        .font(.headline)
                    Spacer()
                    Button {
                        FloatingPanelController.closePanel(identifier: NSUserInterfaceItemIdentifier("aiGenerationPanel"))
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary).frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                    .accessibilityLabel("Close")
                }
                Text(hasSelection
                     ? "Describe what should appear inside the selected area. The surrounding canvas guides the result."
                     : "Describe an image to create. The current canvas will guide the edit.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField(hasSelection ? "What should fill the selection?" : "Describe the image…",
                          text: $prompt, axis: .vertical)
                    .font(.body).lineLimit(4...6).textFieldStyle(.plain).padding(10)
                    .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 110, alignment: .topLeading)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))

                HStack {
                    Text("Reference images").font(.subheadline.weight(.medium))
                    Spacer()
                    Button("Add images…") { showsReferenceImporter = true }
                        .disabled(session.isGeneratingImage || session.aiGenerationReferences.count >= 15)
                }
                if session.aiGenerationReferences.isEmpty {
                    Text("Optional. Reference images are sent after the current canvas.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(session.aiGenerationReferences) { reference in
                            HStack(spacing: 8) {
                                if let image = NSImage(data: reference.thumbnailData) {
                                    Image(nsImage: image).resizable().scaledToFill()
                                        .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 5))
                                }
                                Text(reference.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    session.aiGenerationReferences.removeAll { $0.id == reference.id }
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
                        Text("OpenAI-compatible API base URL").font(.caption).foregroundStyle(.secondary)
                        TextField("API base URL", text: $endpoint).textFieldStyle(.roundedBorder)
                        TextField("Model", text: $model).textFieldStyle(.roundedBorder)
                        SecureField("API key", text: $apiKey).textFieldStyle(.roundedBorder)
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

                if let message = localMessage ?? session.aiGenerationStatusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if let error = session.aiGenerationErrorMessage {
                    Text(error).font(.callout).foregroundStyle(.orange)
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
                            .buttonStyle(.borderedProminent).disabled(!canGenerate)
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
        .onChange(of: session.aiGenerationCompletionID) { _, _ in prompt = "" }
        .fileImporter(isPresented: $showsReferenceImporter,
                      allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importReferences(urls)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { localMessage = error.localizedDescription }
            }
        }
    }

    private func loadAPIKey() {
        do { apiKey = try AIGenerationKeychain.load() }
        catch { session.aiGenerationErrorMessage = error.localizedDescription }
    }

    private func saveSettings() {
        do {
            try AIGenerationKeychain.save(apiKey)
            localMessage = String(localized: "Settings saved.")
            session.aiGenerationErrorMessage = nil
        } catch {
            session.aiGenerationErrorMessage = error.localizedDescription
            localMessage = nil
        }
    }

    private func importReferences(_ urls: [URL]) {
        let slots = max(0, 15 - session.aiGenerationReferences.count)
        guard slots > 0 else { return }
        Task {
            for url in urls.prefix(slots) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    let imported = try await ImageImporter.shared.decode(url, flattenedPhotoshop: true)
                    let data = try AIGenerationImageCodec.pngData(imported.image)
                    guard data.count < 50 * 1024 * 1024 else { throw AIGenerationError.imageTooLarge }
                    let thumbnail = try AIGenerationImageCodec.pngData(try PixelInvert.thumbnail(of: imported.image))
                    session.aiGenerationReferences.append(AIGenerationReference(name: url.lastPathComponent,
                                                                                imageData: data,
                                                                                thumbnailData: thumbnail))
                    localMessage = nil
                } catch {
                    localMessage = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    private func generate() {
        do {
            try AIGenerationKeychain.save(apiKey)
            session.generateAIImage(endpoint: endpoint, model: model, apiKey: apiKey, prompt: prompt,
                                    quality: quality, references: session.aiGenerationReferences.map(\.imageData))
            localMessage = nil
        } catch {
            session.aiGenerationErrorMessage = error.localizedDescription
        }
    }
}

struct AIGenerationPanelObserver: View {
    @Bindable var session: EditorSession
    let panel: FloatingPanelController

    var body: some View {
        Color.clear.onChange(of: session.aiGenerationPanelRequest) { _, _ in
            panel.onClose = { session.cancelAIGeneration() }
            panel.show(title: String(localized: "Generative Fill"), content: AIGenerationSheet(session: session))
        }
    }
}

struct GenerativeFillContextBar: View {
    @Bindable var session: EditorSession
    let availableWidth: CGFloat
    @AppStorage("aiImage.contextBarEnabled") private var isEnabled = false
    @AppStorage("aiImage.endpoint") private var endpoint = "https://cloudapi.flowingcloud.com"
    @AppStorage("aiImage.model") private var model = "gpt-image-2"
    @AppStorage("aiImage.quality") private var quality = "high"
    @State private var prompt = ""

    private var promptFieldMaxWidth: CGFloat { max(120, min(400, availableWidth - 370)) }
    private var promptNaturalWidth: CGFloat {
        prompt.reduce(CGFloat(42)) { $0 + ($1.isASCII ? 7 : 14) }
    }
    private var promptFieldWidth: CGFloat {
        min(promptFieldMaxWidth, max(min(240, promptFieldMaxWidth), promptNaturalWidth))
    }
    private var estimatedPromptLineCount: Int {
        min(8, max(1, Int(ceil(promptNaturalWidth / promptFieldWidth))))
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: estimatedPromptLineCount > 1 ? .bottom : .center, spacing: 10) {
                Toggle("Generative Fill", isOn: $isEnabled).toggleStyle(.switch).fixedSize()
                if session.canCutOutSubjectFromSelection {
                    Button { Task { await session.selectSubject(mode: .replace) } } label: {
                        Label("Select Subject", systemImage: "person.crop.rectangle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(session.isGeneratingImage)
                    .help("Automatically select the foreground subject")
                }
                if isEnabled {
                    TextField("Describe what to fill…", text: $prompt, axis: .vertical)
                        .lineLimit(1...8).multilineTextAlignment(.leading).textFieldStyle(.roundedBorder)
                        .frame(minWidth: promptFieldWidth, idealWidth: promptFieldWidth, maxWidth: promptFieldWidth,
                               minHeight: 36, maxHeight: 180)
                        .onSubmit(generate)
                    if session.isGeneratingImage {
                        ProgressView().controlSize(.small).tint(.black)
                        Button("Cancel") { session.cancelAIGeneration() }.buttonStyle(.borderless)
                    } else {
                        Button(action: generate) { Label("Generate", systemImage: "sparkles") }
                            .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Button { session.requestAIGenerationPanel(prompt: prompt) } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.borderless)
                    .help("Reference images and image API settings")
                }
            }
            if let error = session.aiGenerationErrorMessage {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2).frame(maxWidth: availableWidth - 20)
            } else if let status = session.aiGenerationStatusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 5)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: session.aiGenerationCompletionID) { _, _ in prompt = "" }
    }

    private func generate() {
        do {
            let apiKey = try AIGenerationKeychain.load()
            session.generateAIImage(endpoint: endpoint, model: model, apiKey: apiKey, prompt: prompt,
                                    quality: quality, references: session.aiGenerationReferences.map(\.imageData))
        } catch {
            session.aiGenerationErrorMessage = error.localizedDescription
        }
    }
}
