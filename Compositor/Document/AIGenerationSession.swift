import AppKit
import SwiftUI

extension EditorSession {
    /// The contextual cutout action is relevant when the current selection overlaps the active image layer.
    var canCutOutSubjectFromSelection: Bool {
        guard canSelectSubject, let document, let selection, !selection.isEmpty,
              let layer = activeLayer, !layer.isGroup, layer.asset != nil,
              document.effectiveVisibleIDs.contains(layer.id) else { return false }
        let corners = [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
            .map(layer.transform.point)
        guard let minX = corners.map(\.x).min(), let maxX = corners.map(\.x).max(),
              let minY = corners.map(\.y).min(), let maxY = corners.map(\.y).max() else { return false }
        let imageBounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return selection.path.boundingBoxOfPath.intersects(imageBounds)
    }

    func makeAIGenerationSnapshot(maxSide: Int = 2048) throws -> AIGenerationCanvasSnapshot {
        guard canEditLayers, !isMaskSelected, let document else { throw AIGenerationError.noDocument }
        if selection?.isEmpty == true { throw AIGenerationError.emptySelection }

        let canvas = CGRect(origin: .zero, size: document.size)
        let selectedBounds = selection?.coverageBounds ?? canvas
        let destinationRect = selectedBounds.integral.intersection(canvas)
        guard !destinationRect.isNull, !destinationRect.isEmpty else { throw AIGenerationError.emptySelection }

        let scale = min(1, CGFloat(maxSide) / max(destinationRect.width, destinationRect.height))
        let width = max(1, Int((destinationRect.width * scale).rounded()))
        let height = max(1, Int((destinationRect.height * scale).rounded()))
        let sx = CGFloat(width) / destinationRect.width
        let sy = CGFloat(height) / destinationRect.height

        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.scaleBy(x: sx, y: sy)
        context.translateBy(x: -destinationRect.minX, y: -destinationRect.minY)
        drawLiveComposite(document, in: context)
        guard let image = context.makeImage() else { throw ExportError.render }

        var coverage: CGImage?
        var maskData: Data?
        if let selection {
            var transform = CGAffineTransform(scaleX: sx, y: sy)
                .translatedBy(x: -destinationRect.minX, y: -destinationRect.minY)
            guard let path = selection.path.copy(using: &transform) else { throw ExportError.render }
            let resized = DocumentSelection(path: path, antialiased: selection.antialiased,
                                            feather: selection.feather * min(sx, sy))
            let selectionCoverage = try resized.coverage(width: width, height: height)
            coverage = selectionCoverage
            maskData = try AIGenerationImageCodec.transparentEditMaskPNG(from: selectionCoverage)
        }

        let imageData = try AIGenerationImageCodec.pngData(image)
        guard imageData.count < 50 * 1024 * 1024 else { throw AIGenerationError.imageTooLarge }
        return AIGenerationCanvasSnapshot(documentID: document.id, canvasSize: document.size,
                                          destinationRect: destinationRect, inputWidth: width, inputHeight: height,
                                          imageData: imageData, maskData: maskData, selectionCoverage: coverage)
    }

    func insertAIGeneratedImage(_ image: CGImage, snapshot: AIGenerationCanvasSnapshot) throws {
        guard let document, document.id == snapshot.documentID else { throw AIGenerationError.documentChanged }
        let fitted = try AIGenerationImageCodec.fit(image, width: snapshot.inputWidth, height: snapshot.inputHeight,
                                                     clip: snapshot.selectionCoverage)
        let thumbnail = try PixelInvert.thumbnail(of: fitted)
        let name = String(localized: "AI Generation")
        var layer = ImageLayer(asset: ImportedImage(image: fitted, thumbnail: thumbnail, name: name), origin: .zero)
        layer.transform = LayerTransform(origin: snapshot.destinationRect.origin, size: snapshot.destinationRect.size)
        layer.parentID = nil
        beginEdit(name)
        self.document?.layers.append(layer)
        activeLayerID = layer.id
        endEdit()
    }

    func generateAIImage(endpoint: String, model: String, apiKey: String, prompt: String,
                         quality: String, references: [Data] = []) {
        do {
            let snapshot = try makeAIGenerationSnapshot()
            let images = [snapshot.imageData] + references
            let requestPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            aiGenerationErrorMessage = nil
            aiGenerationStatusMessage = nil
            cancelAIGeneration()
            isGeneratingImage = true
            let taskID = UUID()
            aiGenerationTaskID = taskID
            aiGenerationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.aiGenerationTaskID == taskID {
                        self.isGeneratingImage = false
                        self.aiGenerationTask = nil
                        self.aiGenerationTaskID = nil
                    }
                }
                do {
                    let generated = try await AIGenerationClient.generate(
                        endpoint: endpoint, model: model, apiKey: apiKey, prompt: requestPrompt,
                        quality: quality, images: images, mask: snapshot.maskData)
                    try Task.checkCancellation()
                    try self.insertAIGeneratedImage(generated, snapshot: snapshot)
                    self.aiGenerationCompletionID += 1
                    self.aiGenerationStatusMessage = String(localized: "Generated fill added as a new layer.")
                } catch is CancellationError {
                    self.aiGenerationStatusMessage = String(localized: "Generation cancelled.")
                } catch {
                    self.aiGenerationErrorMessage = error.localizedDescription
                }
            }
        } catch {
            aiGenerationErrorMessage = error.localizedDescription
        }
    }

    func requestAIGenerationPanel(prompt: String = "") {
        aiGenerationInitialPrompt = prompt
        aiGenerationPanelRequest += 1
    }

    func cancelAIGeneration() {
        let task = aiGenerationTask
        aiGenerationTask = nil
        aiGenerationTaskID = nil
        isGeneratingImage = false
        task?.cancel()
    }
}
