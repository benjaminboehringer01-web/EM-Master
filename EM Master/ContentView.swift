import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Datenmodell
struct CalloutItem: Identifiable, Equatable {
    let id = UUID()
    var index: Int
    var label: String {
        guard index >= 0 else { return "1" }
        guard index < 26 else { return "\(index + 1)" }
        return String(UnicodeScalar(65 + index)!)
    }
    var targetNorm: CGPoint       // 0.0 ... 1.0
    var boxOffset: CGSize = CGSize(width: -30, height: -30)
    var text: String = ""
    var hasLeaderLine: Bool = true // true = mit Linie, false = reiner Kasten (⌘+Klick)
    
    /// Berechnet den Mittelpunkt des Badges mit automatischem Abknicken am Rand
    func badgeCenter(in size: CGSize, badgeRadius: CGFloat = 13) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        let target = CGPoint(
            x: targetNorm.x * size.width,
            y: targetNorm.y * size.height
        )
        
        // Direkter Kasten ohne Linie
        if !hasLeaderLine {
            let finalX = min(max(badgeRadius, target.x + boxOffset.width), size.width - badgeRadius)
            let finalY = min(max(badgeRadius, target.y + boxOffset.height), size.height - badgeRadius)
            return CGPoint(x: finalX, y: finalY)
        }
        
        var ox = boxOffset.width
        var oy = boxOffset.height
        
        // Auto-Flip am Rand
        if target.x + ox < badgeRadius {
            ox = abs(ox)
        } else if target.x + ox > size.width - badgeRadius {
            ox = -abs(ox)
        }
        
        if target.y + oy < badgeRadius {
            oy = abs(oy)
        } else if target.y + oy > size.height - badgeRadius {
            oy = -abs(oy)
        }
        
        let finalX = min(max(badgeRadius, target.x + ox), size.width - badgeRadius)
        let finalY = min(max(badgeRadius, target.y + oy), size.height - badgeRadius)
        
        return CGPoint(x: finalX, y: finalY)
    }
}

enum AppMode {
    case annotate
    case crop
}

// MARK: - Hauptansicht
struct ContentView: View {
    @State private var image: NSImage? = nil
    @State private var callouts: [CalloutItem] = []
    @FocusState private var focusedId: UUID?
    
    // Nativer Zoom State
    @State private var magnification: CGFloat = 1.0
    
    // Crop State
    @State private var mode: AppMode = .annotate
    @State private var cropRectNorm: CGRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    
    // Feedback nach dem Kopieren
    @State private var isCopiedFeedback: Bool = false
    
    var body: some View {
        HSplitView {
            // LINKER BEREICH: Toolbar & Nativer Zoom Canvas
            VStack(spacing: 0) {
                if image != nil {
                    canvasToolbar
                }
                
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)
                    
                    if let image = image {
                        NativeZoomableScrollView(
                            magnification: $magnification,
                            contentSize: image.size,
                            mode: mode,
                            callouts: callouts,
                            onAddCallout: { normPoint, withLeaderLine in
                                addCallout(at: normPoint, withLeaderLine: withLeaderLine)
                            },
                            onUpdateCalloutOffset: { index, newOffset in
                                if callouts.indices.contains(index) {
                                    callouts[index].boxOffset = newOffset
                                }
                            },
                            onCropDrag: { normRect in
                                self.cropRectNorm = normRect
                            }
                        ) {
                            canvasContent(image: image, size: image.size)
                        }
                    } else {
                        emptyStateView
                    }
                }
            }
            .frame(minWidth: 520, minHeight: 480)
            
            // RECHTER BEREICH: Notizen & Kombinierter Export
            sidePanelView
        }
        .onPasteCommand(of: [.png, .tiff]) { providers in
            loadImage(from: providers)
        }
        .onAppear {
            pasteFromClipboard()
        }
    }
    
    // MARK: - Bildinhalt
    @ViewBuilder
    private func canvasContent(image: NSImage, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            // 1. Das REM-Bild
            Image(nsImage: image)
                .resizable()
                .frame(width: size.width, height: size.height)
            
            // 2. Verbindungslinien
            if mode == .annotate {
                Canvas { context, _ in
                    let baseWidth = max(1.5, size.width * 0.0015)
                    let outlineWidth = baseWidth + 2.5
                    
                    let whiteStyle = StrokeStyle(lineWidth: outlineWidth, lineCap: .round, lineJoin: .round)
                    let blackStyle = StrokeStyle(lineWidth: baseWidth, lineCap: .round, lineJoin: .round)
                    
                    for item in callouts where item.hasLeaderLine {
                        let target = CGPoint(
                            x: item.targetNorm.x * size.width,
                            y: item.targetNorm.y * size.height
                        )
                        let boxCenter = item.badgeCenter(in: size)
                        
                        var path = Path()
                        path.move(to: target)
                        path.addLine(to: boxCenter)
                        
                        context.stroke(path, with: .color(.white), style: whiteStyle)
                        context.stroke(path, with: .color(.black), style: blackStyle)
                    }
                }
                .frame(width: size.width, height: size.height)
            }
            
            // 3. Buchstaben-Boxen
            if mode == .annotate {
                ForEach(callouts) { item in
                    let currentBoxPos = item.badgeCenter(in: size)
                    
                    CalloutBadgeView(label: item.label)
                        .position(currentBoxPos)
                }
            }
            
            // 4. Crop-Overlay
            if mode == .crop {
                CropOverlayView(
                    cropRect: cropRectNorm,
                    containerSize: size
                )
            }
        }
        .frame(width: size.width, height: size.height)
    }
    
    // MARK: - Toolbar
    private var canvasToolbar: some View {
        HStack(spacing: 12) {
            if mode == .annotate {
                Button(action: {
                    mode = .crop
                    cropRectNorm = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
                }) {
                    Label("Zuschneiden", systemImage: "crop")
                }
                .buttonStyle(.bordered)
            } else {
                Button("Abbrechen") {
                    mode = .annotate
                }
                .buttonStyle(.bordered)
                
                Button("Zuschnitt anwenden") {
                    applyCrop()
                }
                .buttonStyle(.borderedProminent)
            }
            
            Spacer()
            
            HStack(spacing: 6) {
                Button(action: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        magnification = max(0.2, magnification - 0.25)
                    }
                }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                
                Slider(value: $magnification, in: 0.2...5.0)
                    .frame(width: 80)
                
                Button(action: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        magnification = min(6.0, magnification + 0.25)
                    }
                }) {
                    Image(systemName: "plus.magnifyingglass")
                }
                
                Text("\(Int(magnification * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
                
                Button("100%") {
                    withAnimation(.easeOut(duration: 0.15)) {
                        magnification = 1.0
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }
    
    // MARK: - Crop Logik
    private func applyCrop() {
        guard let currentImage = image else { return }
        
        let crop = cropRectNorm
        let newWidth = currentImage.size.width * crop.width
        let newHeight = currentImage.size.height * crop.height
        let newSize = NSSize(width: max(1, newWidth), height: max(1, newHeight))
        
        let srcY_BottomLeft = (1.0 - crop.origin.y - crop.height) * currentImage.size.height
        let srcRect = NSRect(
            x: crop.origin.x * currentImage.size.width,
            y: srcY_BottomLeft,
            width: newWidth,
            height: newHeight
        )
        
        let croppedImage = NSImage(size: newSize, flipped: false) { targetRect in
            currentImage.draw(in: targetRect, from: srcRect, operation: .copy, fraction: 1.0)
            return true
        }
        
        croppedImage.size = newSize
        
        callouts = callouts.compactMap { item in
            let newX = (item.targetNorm.x - crop.origin.x) / crop.width
            let newY = (item.targetNorm.y - crop.origin.y) / crop.height
            
            if newX >= 0 && newX <= 1 && newY >= 0 && newY <= 1 {
                var updated = item
                updated.targetNorm = CGPoint(x: newX, y: newY)
                return updated
            }
            return nil
        }
        
        for i in 0..<callouts.count {
            callouts[i].index = i
        }
        
        self.image = croppedImage
        self.mode = .annotate
        self.magnification = 1.0
    }
    
    // MARK: - Marker Management
    private func addCallout(at normPoint: CGPoint, withLeaderLine: Bool) {
        guard let img = image else { return }
        let nextIndex = callouts.count
        
        let initialOffset: CGSize
        if withLeaderLine {
            let initialOffsetX: CGFloat = (normPoint.x < 0.08) ? 35 : -35
            let initialOffsetY: CGFloat = (normPoint.y < 0.08) ? 35 : -35
            initialOffset = CGSize(width: initialOffsetX, height: initialOffsetY)
        } else {
            initialOffset = .zero
        }
        
        let newItem = CalloutItem(
            index: nextIndex,
            targetNorm: normPoint,
            boxOffset: initialOffset,
            hasLeaderLine: withLeaderLine
        )
        callouts.append(newItem)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.focusedId = newItem.id
        }
    }
    
    private func removeCallout(id: UUID) {
        if let idx = callouts.firstIndex(where: { $0.id == id }) {
            callouts.remove(at: idx)
            for i in 0..<callouts.count {
                callouts[i].index = i
            }
        }
    }
    
    // MARK: - Reset State (Sicher gegen Index-Fehler)
    private func resetApp() {
        // Erst den First Responder schliessen, damit kein Textfeld mehr aktiv ist
        NSApp.keyWindow?.makeFirstResponder(nil)
        self.focusedId = nil
        
        withAnimation(.easeInOut(duration: 0.2)) {
            self.image = nil
            self.callouts.removeAll()
            self.magnification = 1.0
            self.mode = .annotate
            self.cropRectNorm = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            self.isCopiedFeedback = false
        }
    }
    
    // MARK: - Pasteboard & Kombinierter RemNote Export
    private func pasteFromClipboard() {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           let newImage = NSImage(data: data) {
            setupNewImage(newImage)
        }
    }
    
    private func loadImage(from providers: [NSItemProvider]) {
        if let provider = providers.first {
            provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                if let data = data, let newImage = NSImage(data: data) {
                    DispatchQueue.main.async {
                        self.setupNewImage(newImage)
                    }
                }
            }
        }
    }
    
    private func setupNewImage(_ img: NSImage) {
        if let rep = img.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            img.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        self.image = img
        self.callouts.removeAll()
        self.magnification = 1.0
        self.mode = .annotate
        self.isCopiedFeedback = false
    }
    
    /// Kopiert Bild + Anki/RemNote-Liste in einem einzigen Schritt in die Zwischenablage und setzt die App sicher zurück
    @MainActor
    private func copyCombinedToClipboard() {
        // 1. Textfeld-Fokus sofort beenden
        NSApp.keyWindow?.makeFirstResponder(nil)
        self.focusedId = nil
        
        guard let currentImage = image, !callouts.isEmpty else { return }
        
        let renderView = ZStack {
            Image(nsImage: currentImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: currentImage.size.width, height: currentImage.size.height)
            
            Canvas { context, size in
                let baseWidth = max(2.0, size.width * 0.003)
                let outlineWidth = baseWidth + 3.0
                let whiteStyle = StrokeStyle(lineWidth: outlineWidth, lineCap: .round, lineJoin: .round)
                let blackStyle = StrokeStyle(lineWidth: baseWidth, lineCap: .round, lineJoin: .round)
                
                for item in callouts where item.hasLeaderLine {
                    let target = CGPoint(
                        x: item.targetNorm.x * size.width,
                        y: item.targetNorm.y * size.height
                    )
                    let boxCenter = item.badgeCenter(in: size)
                    
                    var path = Path()
                    path.move(to: target)
                    path.addLine(to: boxCenter)
                    
                    context.stroke(path, with: .color(.white), style: whiteStyle)
                    context.stroke(path, with: .color(.black), style: blackStyle)
                }
            }
            
            ForEach(callouts) { item in
                let boxCenter = item.badgeCenter(in: currentImage.size)
                CalloutBadgeView(label: item.label)
                    .position(boxCenter)
            }
        }
        .frame(width: currentImage.size.width, height: currentImage.size.height)
        
        let renderer = ImageRenderer(content: renderView)
        renderer.scale = 2.0
        
        // 2. Direktes, stabiles CGImage ohne TIFF-Fehler
        guard let cgImage = renderer.cgImage else { return }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else { return }
        let nsImage = NSImage(cgImage: cgImage, size: currentImage.size)
        let tiffData = nsImage.tiffRepresentation ?? pngData
        
        let base64Image = pngData.base64EncodedString()
        
        // HTML für RemNote / Notion
        let listItemsHtml = callouts.map { item in
            let text = item.text.trimmingCharacters(in: .whitespaces)
            return "<li><strong>\(item.label)</strong> &rarr; \(text)</li>"
        }.joined(separator: "")
        
        let htmlString = """
        <p><img src="data:image/png;base64,\(base64Image)" alt="REM Image" style="max-width:100%; height:auto;" /></p>
        <ul style="list-style-type: disc; margin-top: 10px;">
        \(listItemsHtml)
        </ul>
        """
        
        // Plain-Text Fallback
        let plainText = callouts.map { item in
            let text = item.text.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? "• \(item.label) →" : "• \(item.label) → \(text)"
        }.joined(separator: "\n")
        
        // RTFD Fallback
        let attrString = NSMutableAttributedString()
        let attachment = NSTextAttachment()
        attachment.image = nsImage
        attrString.append(NSAttributedString(attachment: attachment))
        attrString.append(NSAttributedString(string: "\n\n"))
        
        let font = NSFont.systemFont(ofSize: 14)
        for item in callouts {
            let text = item.text.trimmingCharacters(in: .whitespaces)
            let line = text.isEmpty ? "• \(item.label) →\n" : "• \(item.label) → \(text)\n"
            attrString.append(NSAttributedString(string: line, attributes: [.font: font]))
        }
        
        let rtfdData = try? attrString.data(
            from: NSRange(location: 0, length: attrString.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
        )
        
        let pb = NSPasteboard.general
        pb.clearContents()
        
        let pbItem = NSPasteboardItem()
        pbItem.setData(pngData, forType: .png)
        pbItem.setData(tiffData, forType: .tiff)
        if let htmlData = htmlString.data(using: .utf8) {
            pbItem.setData(htmlData, forType: .html)
        }
        if let rtfdData = rtfdData {
            pbItem.setData(rtfdData, forType: .rtfd)
        }
        pbItem.setString(plainText, forType: .string)
        
        pb.writeObjects([pbItem])
        
        // Feedback anzeigen
        withAnimation(.easeInOut(duration: 0.15)) {
            isCopiedFeedback = true
        }
        
        // Sicheres Reset nach kurzer Pause
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            resetApp()
        }
    }
    
    // MARK: - Panels
    private var sidePanelView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Beschriftungen")
                    .font(.headline)
                Spacer()
                if !callouts.isEmpty {
                    Button("Alle löschen", role: .destructive) {
                        resetApp()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                    .font(.caption)
                }
            }
            
            Divider()
            
            if callouts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("• **Klick:** Marker mit Zeigerlinie")
                    Text("• **⌘ + Klick:** Direkter Kasten ohne Linie")
                }
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        // Absturzsichere Auflistung mit Index-Bounds-Check
                        ForEach(callouts) { item in
                            if let idx = callouts.firstIndex(where: { $0.id == item.id }) {
                                HStack(spacing: 8) {
                                    CalloutBadgeView(label: item.label)
                                    
                                    Image(systemName: "arrow.right")
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                    
                                    TextField("Back of card", text: Binding(
                                        get: {
                                            guard callouts.indices.contains(idx) else { return "" }
                                            return callouts[idx].text
                                        },
                                        set: { newValue in
                                            guard callouts.indices.contains(idx) else { return }
                                            callouts[idx].text = newValue
                                        }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .focused($focusedId, equals: item.id)
                                    
                                    Button(action: { removeCallout(id: item.id) }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            
            Spacer()
            
            // EXPORT- UND RESET-BUTTON
            Button(action: copyCombinedToClipboard) {
                HStack(spacing: 8) {
                    Image(systemName: isCopiedFeedback ? "checkmark.circle.fill" : "doc.on.clipboard.fill")
                    Text(isCopiedFeedback ? "Kopiert! Bereit für nächstes Bild ✓" : "Bild + Liste für RemNote kopieren")
                        .bold()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(isCopiedFeedback ? .green : .accentColor)
            .disabled(image == nil || callouts.isEmpty)
        }
        .padding(14)
        .frame(minWidth: 280, maxWidth: 360)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 50))
                .foregroundColor(.secondary)
            Text("Kein Bild geladen")
                .font(.title2)
                .bold()
            Text("Kopiere ein REM-Bild in die Zwischenablage und drücke **⌘V** oder klicke unten.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Button("Bild aus Zwischenablage einfügen") {
                pasteFromClipboard()
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Native AppKit ScrollView
struct NativeZoomableScrollView<Content: View>: NSViewRepresentable {
    @Binding var magnification: CGFloat
    let contentSize: CGSize
    let mode: AppMode
    let callouts: [CalloutItem]
    var onAddCallout: (CGPoint, Bool) -> Void
    var onUpdateCalloutOffset: (Int, CGSize) -> Void
    var onCropDrag: (CGRect) -> Void
    let content: Content

    init(
        magnification: Binding<CGFloat>,
        contentSize: CGSize,
        mode: AppMode,
        callouts: [CalloutItem],
        onAddCallout: @escaping (CGPoint, Bool) -> Void,
        onUpdateCalloutOffset: @escaping (Int, CGSize) -> Void,
        onCropDrag: @escaping (CGRect) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self._magnification = magnification
        self.contentSize = contentSize
        self.mode = mode
        self.callouts = callouts
        self.onAddCallout = onAddCallout
        self.onUpdateCalloutOffset = onUpdateCalloutOffset
        self.onCropDrag = onCropDrag
        self.content = content()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.contentView = CenteringClipView()
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.2
        scrollView.maxMagnification = 8.0
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let documentContainer = FlippedDocumentContainerView()
        documentContainer.targetSize = contentSize
        documentContainer.frame = NSRect(origin: .zero, size: contentSize)

        // 1. SwiftUI Host View
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(origin: .zero, size: contentSize)
        hostingView.autoresizingMask = [.width, .height]
        documentContainer.addSubview(hostingView)

        // 2. Native AppKit Interaktions-Ebene
        let interactionOverlay = CanvasInteractionOverlayView()
        interactionOverlay.frame = NSRect(origin: .zero, size: contentSize)
        interactionOverlay.autoresizingMask = [.width, .height]
        interactionOverlay.contentSize = contentSize
        interactionOverlay.mode = mode
        interactionOverlay.callouts = callouts
        interactionOverlay.onAddCallout = onAddCallout
        interactionOverlay.onUpdateCalloutOffset = onUpdateCalloutOffset
        interactionOverlay.onCropDrag = onCropDrag
        documentContainer.addSubview(interactionOverlay)

        scrollView.documentView = documentContainer
        
        context.coordinator.documentContainer = documentContainer
        context.coordinator.hostingView = hostingView
        context.coordinator.interactionOverlay = interactionOverlay
        context.coordinator.scrollView = scrollView

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.magnifyDidChange(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView
        )

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if let doc = context.coordinator.documentContainer {
            if doc.targetSize != contentSize {
                doc.targetSize = contentSize
            }
        }
        if let hosting = context.coordinator.hostingView {
            hosting.rootView = content
            if hosting.frame.size != contentSize {
                hosting.frame = NSRect(origin: .zero, size: contentSize)
            }
        }
        if let overlay = context.coordinator.interactionOverlay {
            overlay.contentSize = contentSize
            overlay.mode = mode
            overlay.callouts = callouts
            overlay.onAddCallout = onAddCallout
            overlay.onUpdateCalloutOffset = onUpdateCalloutOffset
            overlay.onCropDrag = onCropDrag
            if overlay.frame.size != contentSize {
                overlay.frame = NSRect(origin: .zero, size: contentSize)
            }
        }
        
        if abs(nsView.magnification - magnification) > 0.01 {
            nsView.animator().magnification = magnification
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject {
        var parent: NativeZoomableScrollView
        var documentContainer: FlippedDocumentContainerView?
        var hostingView: NSHostingView<Content>?
        var interactionOverlay: CanvasInteractionOverlayView?
        weak var scrollView: NSScrollView?

        init(_ parent: NativeZoomableScrollView) {
            self.parent = parent
        }

        @objc func magnifyDidChange(_ notification: Notification) {
            guard let sv = scrollView else { return }
            DispatchQueue.main.async {
                self.parent.magnification = sv.magnification
            }
        }
    }
}

// MARK: - Native AppKit Interaktions-Overlay
class CanvasInteractionOverlayView: NSView {
    override var isFlipped: Bool { true }

    var contentSize: CGSize = .zero
    var mode: AppMode = .annotate
    var callouts: [CalloutItem] = []
    var onAddCallout: ((CGPoint, Bool) -> Void)?
    var onUpdateCalloutOffset: ((Int, CGSize) -> Void)?
    var onCropDrag: ((CGRect) -> Void)?

    private var activeDraggedCalloutIndex: Int?
    private var dragStartLoc: CGPoint?
    private var dragStartBoxOffset: CGSize = .zero
    private var isDragging: Bool = false
    private var isCommandClick: Bool = false

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        dragStartLoc = loc
        isDragging = false
        activeDraggedCalloutIndex = nil
        isCommandClick = event.modifierFlags.contains(.command)

        guard contentSize.width > 0, contentSize.height > 0 else { return }

        if mode == .annotate {
            for (idx, item) in callouts.enumerated().reversed() {
                let badgeCenter = item.badgeCenter(in: contentSize)
                let badgeRect = CGRect(
                    x: badgeCenter.x - 16,
                    y: badgeCenter.y - 16,
                    width: 32,
                    height: 32
                )
                if badgeRect.contains(loc) {
                    activeDraggedCalloutIndex = idx
                    dragStartBoxOffset = item.boxOffset
                    break
                }
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartLoc, contentSize.width > 0, contentSize.height > 0 else { return }
        let current = convert(event.locationInWindow, from: nil)
        let dist = hypot(current.x - start.x, current.y - start.y)
        if dist > 3 {
            isDragging = true
        }

        if let draggedIdx = activeDraggedCalloutIndex, mode == .annotate {
            if callouts.indices.contains(draggedIdx) {
                let dx = current.x - start.x
                let dy = current.y - start.y
                let newOffset = CGSize(
                    width: dragStartBoxOffset.width + dx,
                    height: dragStartBoxOffset.height + dy
                )
                onUpdateCalloutOffset?(draggedIdx, newOffset)
            }
        } else if mode == .crop {
            let minX = max(0, min(contentSize.width, min(start.x, current.x)))
            let minY = max(0, min(contentSize.height, min(start.y, current.y)))
            let maxX = max(0, min(contentSize.width, max(start.x, current.x)))
            let maxY = max(0, min(contentSize.height, max(start.y, current.y)))

            let normRect = CGRect(
                x: minX / contentSize.width,
                y: minY / contentSize.height,
                width: max(0.02, (maxX - minX) / contentSize.width),
                height: max(0.02, (maxY - minY) / contentSize.height)
            )
            onCropDrag?(normRect)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)

        if mode == .annotate && activeDraggedCalloutIndex == nil && !isDragging {
            if contentSize.width > 0, contentSize.height > 0 {
                let normX = max(0, min(1, loc.x / contentSize.width))
                let normY = max(0, min(1, loc.y / contentSize.height))
                let withLeaderLine = !isCommandClick
                onAddCallout?(CGPoint(x: normX, y: normY), withLeaderLine)
            }
        }

        dragStartLoc = nil
        activeDraggedCalloutIndex = nil
        isDragging = false
        isCommandClick = false
    }
}

// MARK: - Flipped Document Container
class FlippedDocumentContainerView: NSView {
    override var isFlipped: Bool { true }

    var targetSize: NSSize = .zero {
        didSet {
            frame = NSRect(origin: .zero, size: targetSize)
            invalidateIntrinsicContentSize()
        }
    }
    
    override var intrinsicContentSize: NSSize {
        return targetSize
    }
}

// MARK: - Zentrierte ClipView
class CenteringClipView: NSClipView {
    override var isFlipped: Bool { true }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView = documentView else { return rect }
        
        let docSize = documentView.frame.size
        let clipSize = bounds.size
        
        if docSize.width < clipSize.width {
            rect.origin.x = -(clipSize.width - docSize.width) / 2.0
        }
        if docSize.height < clipSize.height {
            rect.origin.y = -(clipSize.height - docSize.height) / 2.0
        }
        return rect
    }
}

// MARK: - Crop Overlay
struct CropOverlayView: View {
    let cropRect: CGRect
    let containerSize: CGSize
    
    var body: some View {
        let pixelRect = CGRect(
            x: cropRect.origin.x * containerSize.width,
            y: cropRect.origin.y * containerSize.height,
            width: cropRect.size.width * containerSize.width,
            height: cropRect.size.height * containerSize.height
        )
        
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.45))
                .mask(
                    Rectangle()
                        .overlay(
                            Rectangle()
                                .frame(width: pixelRect.width, height: pixelRect.height)
                                .position(x: pixelRect.midX, y: pixelRect.midY)
                                .blendMode(.destinationOut)
                        )
                )
            
            Rectangle()
                .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 2, dash: [6]))
                .frame(width: pixelRect.width, height: pixelRect.height)
                .position(x: pixelRect.midX, y: pixelRect.midY)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Badge View
struct CalloutBadgeView: View {
    let label: String
    
    var body: some View {
        Text(label)
            .font(.system(size: 14, weight: .bold, design: .default))
            .foregroundColor(.black)
            .frame(width: 22, height: 22)
            .background(Color.white)
            .overlay(
                Rectangle()
                    .stroke(Color.black, lineWidth: 1.5)
            )
            .shadow(color: Color.black.opacity(0.25), radius: 2, x: 1, y: 1)
    }
}
