import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Hilfserweiterung für auflösungsunabhängige Skalierung
extension CGSize {
    /// Berechnet den Skalierungsfaktor für Beschriftungen basierend auf der Bildauflösung (Referenz: 1000px Basisdimension)
    var calloutScale: CGFloat {
        guard width > 0, height > 0 else { return 1.0 }
        let baseDimension = max(width, height)
        return max(0.4, baseDimension / 1000.0)
    }
}

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
    var boxOffset: CGSize = CGSize(width: -35, height: -35)
    var text: String = ""
    var hasLeaderLine: Bool = true // true = mit Linie, false = reiner Kasten (⌘+Klick)
    
    /// Berechnet den Mittelpunkt des Badges mit automatischem Abknicken am Rand
    func badgeCenter(in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = size.calloutScale
        let badgeRadius: CGFloat = 14 * scale
        
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
    @State private var overviewText: String = "" // Optionale Karte "Was sieht man?"
    @FocusState private var focusedId: UUID?
    @FocusState private var isOverviewFocused: Bool
    
    // Nativer Zoom State
    @State private var magnification: CGFloat = 1.0
    @State private var triggerFitToScreen: Bool = false
    
    // Crop State
    @State private var mode: AppMode = .annotate
    @State private var cropRectNorm: CGRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    
    // Feedback nach dem Kopieren
    @State private var isCopiedFeedback: Bool = false
    
    // Drag & Drop State
    @State private var isDropTargeted: Bool = false
    
    // Tastatur-Event Monitor Token
    @State private var eventMonitor: Any? = nil
    
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
                            cropRectNorm: cropRectNorm,
                            triggerFitToScreen: $triggerFitToScreen,
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
                            // Reines Bild im Hintergrund
                            Image(nsImage: image)
                                .resizable()
                                .frame(width: image.size.width, height: image.size.height)
                        }
                    } else {
                        emptyStateView
                    }
                    
                    // Visueller Drag & Drop Indikator
                    if isDropTargeted {
                        ZStack {
                            Color.accentColor.opacity(0.12)
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                                .padding(16)
                            
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.down.doc.fill")
                                    .font(.system(size: 44))
                                    .foregroundColor(.accentColor)
                                Text("Bild hier ablegen")
                                    .font(.title2.bold())
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
            }
            .frame(minWidth: 520, minHeight: 480)
            
            // RECHTER BEREICH: Notizen & Kombinierter Export
            sidePanelView
        }
        .onDrop(of: [.image, .fileURL, .png, .tiff, .jpeg], isTargeted: $isDropTargeted) { providers in
            loadFromProviders(providers)
            return true
        }
        .onAppear {
            setupGlobalPasteMonitor()
            pasteFromClipboard()
        }
        .onDisappear {
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
    
    // MARK: - Tastatur Monitor für ⌘V
    private func setupGlobalPasteMonitor() {
        if eventMonitor != nil { return }
        
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let isCmdV = event.modifierFlags.contains(.command) &&
                         (event.charactersIgnoringModifiers?.lowercased() == "v")
            
            if isCmdV {
                if let responder = NSApp.keyWindow?.firstResponder,
                   responder is NSTextView || responder is NSTextField {
                    return event
                }
                
                self.pasteFromClipboard()
                return nil
            }
            return event
        }
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
                
                Button(role: .destructive, action: resetApp) {
                    Label("Löschen", systemImage: "trash")
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
                        magnification = max(0.05, magnification - 0.15)
                    }
                }) {
                    Image(systemName: "minus.magnifyingglass")
                }
                
                Slider(value: $magnification, in: 0.05...4.0)
                    .frame(width: 80)
                
                Button(action: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        magnification = min(6.0, magnification + 0.15)
                    }
                }) {
                    Image(systemName: "plus.magnifyingglass")
                }
                
                Text("\(Int(magnification * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
                
                Button("Einpassen") {
                    triggerFitToScreen = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                
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
        self.triggerFitToScreen = true
    }
    
    // MARK: - Marker Management
    private func addCallout(at normPoint: CGPoint, withLeaderLine: Bool) {
        guard let img = image else { return }
        let nextIndex = callouts.count
        let scale = img.size.calloutScale
        
        let initialOffset: CGSize
        if withLeaderLine {
            let dist: CGFloat = 45 * scale
            let initialOffsetX: CGFloat = (normPoint.x < 0.1) ? dist : -dist
            let initialOffsetY: CGFloat = (normPoint.y < 0.1) ? dist : -dist
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
    
    // MARK: - Reset State
    private func resetApp() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        self.focusedId = nil
        self.isOverviewFocused = false
        
        withAnimation(.easeInOut(duration: 0.2)) {
            self.image = nil
            self.callouts.removeAll()
            self.overviewText = ""
            self.magnification = 1.0
            self.mode = .annotate
            self.cropRectNorm = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
            self.isCopiedFeedback = false
        }
    }
    
    // MARK: - Pasteboard & Drag-and-Drop Loader
    private func pasteFromClipboard() {
        let pb = NSPasteboard.general
        
        if let directImage = NSImage(pasteboard: pb) {
            setupNewImage(directImage)
            return
        }
        
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                if let img = NSImage(contentsOf: url) {
                    setupNewImage(img)
                    return
                }
            }
        }
        
        let supportedTypes: [NSPasteboard.PasteboardType] = [
            .png,
            .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic")
        ]
        for type in supportedTypes {
            if let data = pb.data(forType: type), let img = NSImage(data: data) {
                setupNewImage(img)
                return
            }
        }
    }
    
    private func loadFromProviders(_ providers: [NSItemProvider]) {
        guard let provider = providers.first else { return }
        
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { loadedImage, _ in
                if let img = loadedImage as? NSImage {
                    DispatchQueue.main.async {
                        self.setupNewImage(img)
                    }
                }
            }
            return
        }
        
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var targetURL: URL?
                if let url = item as? URL {
                    targetURL = url
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    targetURL = url
                }
                
                if let url = targetURL, let img = NSImage(contentsOf: url) {
                    DispatchQueue.main.async {
                        self.setupNewImage(img)
                    }
                }
            }
            return
        }
        
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                if let data = data, let img = NSImage(data: data) {
                    DispatchQueue.main.async {
                        self.setupNewImage(img)
                    }
                }
            }
        }
    }
    
    private func setupNewImage(_ img: NSImage) {
        if let rep = img.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            img.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            self.image = img
            self.callouts.removeAll()
            self.overviewText = ""
            self.mode = .annotate
            self.isCopiedFeedback = false
            self.triggerFitToScreen = true
        }
    }
    
    /// Kopiert Bild + Liste in einem Schritt in die Zwischenablage mit perfekt skalierter Auflösung
    @MainActor
    private func copyCombinedToClipboard() {
        NSApp.keyWindow?.makeFirstResponder(nil)
        self.focusedId = nil
        self.isOverviewFocused = false
        
        let trimmedOverview = overviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let currentImage = image, (!callouts.isEmpty || !trimmedOverview.isEmpty) else { return }
        let scale = currentImage.size.calloutScale
        
        let renderView = ZStack {
            Image(nsImage: currentImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: currentImage.size.width, height: currentImage.size.height)
            
            Canvas { context, size in
                let baseWidth = max(2.0, 2.5 * scale)
                let outlineWidth = baseWidth + (3.0 * scale)
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
                CalloutBadgeView(label: item.label, scale: scale)
                    .position(boxCenter)
            }
        }
        .frame(width: currentImage.size.width, height: currentImage.size.height)
        
        let renderer = ImageRenderer(content: renderView)
        renderer.scale = 2.0
        
        guard let cgImage = renderer.cgImage else { return }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else { return }
        let nsImage = NSImage(cgImage: cgImage, size: currentImage.size)
        let tiffData = nsImage.tiffRepresentation ?? pngData
        
        let base64Image = pngData.base64EncodedString()
        
        // --- 1. HTML String Zusammenbau ---
        var listItemsHtml = ""
        if !trimmedOverview.isEmpty {
            listItemsHtml += "<li><strong>Was sieht man?</strong> &rarr; \(trimmedOverview)</li>"
        }
        listItemsHtml += callouts.map { item in
            let text = item.text.trimmingCharacters(in: .whitespaces)
            return "<li><strong>\(item.label)</strong> &rarr; \(text)</li>"
        }.joined(separator: "")
        
        let htmlString = """
        <p><img src="data:image/png;base64,\(base64Image)" alt="REM Image" style="max-width:100%; height:auto;" /></p>
        <ul style="list-style-type: disc; margin-top: 10px;">
        \(listItemsHtml)
        </ul>
        """
        
        // --- 2. Plain Text Zusammenbau ---
        var plainLines: [String] = []
        if !trimmedOverview.isEmpty {
            plainLines.append("• Was sieht man? → \(trimmedOverview)")
        }
        plainLines.append(contentsOf: callouts.map { item in
            let text = item.text.trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? "• \(item.label) →" : "• \(item.label) → \(text)"
        })
        let plainText = plainLines.joined(separator: "\n")
        
        // --- 3. RTFD String Zusammenbau ---
        let attrString = NSMutableAttributedString()
        let attachment = NSTextAttachment()
        attachment.image = nsImage
        attrString.append(NSAttributedString(attachment: attachment))
        attrString.append(NSAttributedString(string: "\n\n"))
        
        let font = NSFont.systemFont(ofSize: 14)
        if !trimmedOverview.isEmpty {
            let line = "• Was sieht man? → \(trimmedOverview)\n"
            attrString.append(NSAttributedString(string: line, attributes: [.font: font]))
        }
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
        
        withAnimation(.easeInOut(duration: 0.15)) {
            isCopiedFeedback = true
        }
        
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
                if !callouts.isEmpty || !overviewText.isEmpty {
                    Button("Marker leeren", role: .destructive) {
                        self.callouts.removeAll()
                        self.overviewText = ""
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                    .font(.caption)
                }
            }
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    // Elegante "Was sieht man?" Zeile
                    overviewCardRow
                    
                    if !callouts.isEmpty {
                        Divider()
                            .padding(.vertical, 2)
                    }
                    
                    // Dynamische Liste der Marker (A, B, C...)
                    ForEach(callouts) { item in
                        if let idx = callouts.firstIndex(where: { $0.id == item.id }) {
                            HStack(spacing: 10) {
                                CalloutBadgeView(label: item.label, scale: 1.0)
                                
                                RemArrowView()
                                
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
                    
                    // Hilfetext bei leeren Markern
                    if callouts.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("• **Klick:** Marker mit Zeigerlinie")
                            Text("• **⌘ + Klick:** Direkter Kasten ohne Linie")
                            Text("• **Drag & Drop:** Bild direkt reinziehen")
                        }
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .padding(.top, 12)
                    }
                }
                .padding(.horizontal, 4) // Verhindert Rand-Clipping links
                .padding(.vertical, 6)
            }
            
            Spacer()
            
            // BUTTON-GRUPPE
            let hasContentToCopy = !callouts.isEmpty || !overviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            
            VStack(spacing: 8) {
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
                .disabled(image == nil || !hasContentToCopy)
                
                Button(role: .destructive, action: resetApp) {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text("Löschen")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .disabled(image == nil && callouts.isEmpty && overviewText.isEmpty)
            }
        }
        .padding(14)
        .frame(minWidth: 310, maxWidth: 390)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Schöne, moderne Zeile für "Was sieht man?"
    private var overviewCardRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "eye.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("Was sieht man?")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.04), radius: 2, x: 0, y: 1)
            .fixedSize()
            
            RemArrowView()
            
            TextField("Back of card (optional)", text: $overviewText)
                .textFieldStyle(.roundedBorder)
                .focused($isOverviewFocused)
            
            if !overviewText.isEmpty {
                Button(action: { overviewText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 50))
                .foregroundColor(.secondary)
            Text("Kein Bild geladen")
                .font(.title2)
                .bold()
            Text("Drücke **⌘V**, ziehe ein Bild per **Drag & Drop** hierher oder klicke unten.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            
            Button("Bild aus Zwischenablage einfügen (⌘V)") {
                pasteFromClipboard()
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - RemNote Typografischer Pfeil
struct RemArrowView: View {
    var body: some View {
        Text("→")
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundColor(.primary.opacity(0.65))
            .frame(width: 14)
            .fixedSize()
    }
}

// MARK: - Native AppKit ScrollView
struct NativeZoomableScrollView<Content: View>: NSViewRepresentable {
    @Binding var magnification: CGFloat
    let contentSize: CGSize
    let mode: AppMode
    let callouts: [CalloutItem]
    let cropRectNorm: CGRect
    @Binding var triggerFitToScreen: Bool
    var onAddCallout: (CGPoint, Bool) -> Void
    var onUpdateCalloutOffset: (Int, CGSize) -> Void
    var onCropDrag: (CGRect) -> Void
    let content: Content

    init(
        magnification: Binding<CGFloat>,
        contentSize: CGSize,
        mode: AppMode,
        callouts: [CalloutItem],
        cropRectNorm: CGRect,
        triggerFitToScreen: Binding<Bool>,
        onAddCallout: @escaping (CGPoint, Bool) -> Void,
        onUpdateCalloutOffset: @escaping (Int, CGSize) -> Void,
        onCropDrag: @escaping (CGRect) -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self._magnification = magnification
        self.contentSize = contentSize
        self.mode = mode
        self.callouts = callouts
        self.cropRectNorm = cropRectNorm
        self._triggerFitToScreen = triggerFitToScreen
        self.onAddCallout = onAddCallout
        self.onUpdateCalloutOffset = onUpdateCalloutOffset
        self.onCropDrag = onCropDrag
        self.content = content()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.contentView = CenteringClipView()
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 8.0
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true // ✅ Richtig (Plural)        scrollView.drawsBackground = false

        let documentContainer = FlippedDocumentContainerView()
        documentContainer.targetSize = contentSize

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.frame = NSRect(origin: .zero, size: contentSize)
        documentContainer.addSubview(hostingView)

        let interactionOverlay = CanvasInteractionOverlayView()
        interactionOverlay.translatesAutoresizingMaskIntoConstraints = true
        interactionOverlay.frame = NSRect(origin: .zero, size: contentSize)
        interactionOverlay.contentSize = contentSize
        interactionOverlay.mode = mode
        interactionOverlay.callouts = callouts
        interactionOverlay.cropRectNorm = cropRectNorm
        interactionOverlay.onAddCallout = onAddCallout
        interactionOverlay.onUpdateCalloutOffset = onUpdateCalloutOffset
        interactionOverlay.onCropDrag = onCropDrag
        documentContainer.addSubview(interactionOverlay)

        scrollView.documentView = documentContainer
        
        context.coordinator.documentContainer = documentContainer
        context.coordinator.hostingView = hostingView
        context.coordinator.interactionOverlay = interactionOverlay
        context.coordinator.scrollView = scrollView
        context.coordinator.lastContentSize = contentSize

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.magnifyDidChange(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView
        )

        DispatchQueue.main.async {
            context.coordinator.zoomToFit(animated: false)
        }

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
            overlay.cropRectNorm = cropRectNorm
            overlay.onAddCallout = onAddCallout
            overlay.onUpdateCalloutOffset = onUpdateCalloutOffset
            overlay.onCropDrag = onCropDrag
            if overlay.frame.size != contentSize {
                overlay.frame = NSRect(origin: .zero, size: contentSize)
            }
            overlay.needsDisplay = true
        }
        
        // Neues Bild oder Größenänderung -> automatisch einpassen
        if context.coordinator.lastContentSize != contentSize || triggerFitToScreen {
            context.coordinator.lastContentSize = contentSize
            DispatchQueue.main.async {
                self.triggerFitToScreen = false
                context.coordinator.zoomToFit(animated: true)
            }
        } else if abs(nsView.magnification - magnification) > 0.01 {
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
        var lastContentSize: CGSize = .zero

        init(_ parent: NativeZoomableScrollView) {
            self.parent = parent
        }

        func zoomToFit(animated: Bool = false) {
            guard let sv = scrollView, parent.contentSize.width > 0, parent.contentSize.height > 0 else { return }
            
            let viewportSize = sv.contentView.frame.size
            guard viewportSize.width > 30, viewportSize.height > 30 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.zoomToFit(animated: animated)
                }
                return
            }

            let margin: CGFloat = 32.0
            let availW = max(10, viewportSize.width - margin)
            let availH = max(10, viewportSize.height - margin)

            let scaleX = availW / parent.contentSize.width
            let scaleY = availH / parent.contentSize.height
            let fitScale = min(scaleX, scaleY)
            let finalScale = max(sv.minMagnification, min(fitScale, sv.maxMagnification))

            if animated {
                sv.animator().magnification = finalScale
            } else {
                sv.magnification = finalScale
            }

            self.parent.magnification = finalScale
        }

        @objc func magnifyDidChange(_ notification: Notification) {
            guard let sv = scrollView else { return }
            DispatchQueue.main.async {
                self.parent.magnification = sv.magnification
            }
        }
    }
}

// MARK: - Native AppKit Interaktions- & Zeichen-Overlay (CoreGraphics)
class CanvasInteractionOverlayView: NSView {
    override var isFlipped: Bool { true }

    var contentSize: CGSize = .zero {
        didSet { if oldValue != contentSize { needsDisplay = true } }
    }
    var mode: AppMode = .annotate {
        didSet { if oldValue != mode { needsDisplay = true } }
    }
    var callouts: [CalloutItem] = [] {
        didSet { needsDisplay = true }
    }
    var cropRectNorm: CGRect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8) {
        didSet { needsDisplay = true }
    }

    var onAddCallout: ((CGPoint, Bool) -> Void)?
    var onUpdateCalloutOffset: ((Int, CGSize) -> Void)?
    var onCropDrag: ((CGRect) -> Void)?

    private var activeDraggedCalloutIndex: Int?
    private var dragStartLoc: CGPoint?
    private var dragStartBoxOffset: CGSize = .zero
    private var isDragging: Bool = false
    private var isCommandClick: Bool = false

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard contentSize.width > 0, contentSize.height > 0 else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        
        let scale = contentSize.calloutScale
        
        if mode == .annotate {
            let baseWidth = max(2.0, 2.5 * scale)
            let outlineWidth = baseWidth + (3.0 * scale)
            
            context.setLineCap(.round)
            context.setLineJoin(.round)
            
            // 1. Verbindungslinien - Weißer Umriss
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(outlineWidth)
            for item in callouts where item.hasLeaderLine {
                let target = CGPoint(
                    x: item.targetNorm.x * contentSize.width,
                    y: item.targetNorm.y * contentSize.height
                )
                let boxCenter = item.badgeCenter(in: contentSize)
                
                context.beginPath()
                context.move(to: target)
                context.addLine(to: boxCenter)
                context.strokePath()
            }
            
            // 2. Verbindungslinien - Schwarzer Kern
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineWidth(baseWidth)
            for item in callouts where item.hasLeaderLine {
                let target = CGPoint(
                    x: item.targetNorm.x * contentSize.width,
                    y: item.targetNorm.y * contentSize.height
                )
                let boxCenter = item.badgeCenter(in: contentSize)
                
                context.beginPath()
                context.move(to: target)
                context.addLine(to: boxCenter)
                context.strokePath()
            }
            
            // 3. Buchstaben-Kästen (Badges) zeichnen
            let badgeSize: CGFloat = 24 * scale
            let halfSize = badgeSize / 2.0
            let fontSize: CGFloat = 15 * scale
            let borderWidth: CGFloat = max(1.5, 1.5 * scale)
            let cornerRadius: CGFloat = 3 * scale
            
            let font = NSFont.boldSystemFont(ofSize: fontSize)
            let textAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black
            ]
            
            for item in callouts {
                let center = item.badgeCenter(in: contentSize)
                let badgeRect = CGRect(
                    x: center.x - halfSize,
                    y: center.y - halfSize,
                    width: badgeSize,
                    height: badgeSize
                )
                let path = CGPath(roundedRect: badgeRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
                
                // Schatten
                context.saveGState()
                context.setShadow(
                    offset: CGSize(width: 1 * scale, height: 1 * scale),
                    blur: 2 * scale,
                    color: NSColor.black.withAlphaComponent(0.25).cgColor
                )
                
                // Weißer Kasten mit dezent gerundeten Ecken
                context.setFillColor(NSColor.white.cgColor)
                context.addPath(path)
                context.fillPath()
                context.restoreGState()
                
                // Schwarzer Rahmen
                context.setStrokeColor(NSColor.black.cgColor)
                context.setLineWidth(borderWidth)
                context.addPath(path)
                context.strokePath()
                
                // Zentrierter Text
                let str = NSString(string: item.label)
                let textSize = str.size(withAttributes: textAttributes)
                let textRect = CGRect(
                    x: badgeRect.midX - textSize.width / 2.0,
                    y: badgeRect.midY - textSize.height / 2.0,
                    width: textSize.width,
                    height: textSize.height
                )
                str.draw(in: textRect, withAttributes: textAttributes)
            }
        } else if mode == .crop {
            // 4. Crop-Overlay
            let pixelRect = CGRect(
                x: cropRectNorm.origin.x * contentSize.width,
                y: cropRectNorm.origin.y * contentSize.height,
                width: cropRectNorm.size.width * contentSize.width,
                height: cropRectNorm.size.height * contentSize.height
            )
            
            context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            
            // Oben
            context.fill(CGRect(x: 0, y: 0, width: contentSize.width, height: pixelRect.minY))
            // Unten
            context.fill(CGRect(x: 0, y: pixelRect.maxY, width: contentSize.width, height: contentSize.height - pixelRect.maxY))
            // Links
            context.fill(CGRect(x: 0, y: pixelRect.minY, width: pixelRect.minX, height: pixelRect.height))
            // Rechts
            context.fill(CGRect(x: pixelRect.maxX, y: pixelRect.minY, width: contentSize.width - pixelRect.maxX, height: pixelRect.height))
            
            // Gestrichelter Rahmen
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(2)
            let dashes: [CGFloat] = [6, 6]
            context.setLineDash(phase: 0, lengths: dashes)
            context.stroke(pixelRect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        dragStartLoc = loc
        isDragging = false
        activeDraggedCalloutIndex = nil
        isCommandClick = event.modifierFlags.contains(.command)

        guard contentSize.width > 0, contentSize.height > 0 else { return }

        if mode == .annotate {
            let scale = contentSize.calloutScale
            let hitSize = max(32.0, 32.0 * scale)
            let halfHit = hitSize / 2.0
            
            for (idx, item) in callouts.enumerated().reversed() {
                let badgeCenter = item.badgeCenter(in: contentSize)
                let badgeRect = CGRect(
                    x: badgeCenter.x - halfHit,
                    y: badgeCenter.y - halfHit,
                    width: hitSize,
                    height: hitSize
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
                callouts[draggedIdx].boxOffset = newOffset
                needsDisplay = true
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
            self.cropRectNorm = normRect
            needsDisplay = true
            onCropDrag?(normRect)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)

        if mode == .annotate && activeDraggedCalloutIndex == nil && !isDragging {
            if contentSize.width > 0, contentSize.height > 0 {
                if loc.x >= 0 && loc.x <= contentSize.width && loc.y >= 0 && loc.y <= contentSize.height {
                    let normX = loc.x / contentSize.width
                    let normY = loc.y / contentSize.height
                    let withLeaderLine = !isCommandClick
                    onAddCallout?(CGPoint(x: normX, y: normY), withLeaderLine)
                }
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
            super.setFrameSize(targetSize)
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }
    
    override var intrinsicContentSize: NSSize {
        return targetSize
    }
    
    override func setFrameSize(_ newSize: NSSize) {
        if targetSize != .zero {
            super.setFrameSize(targetSize)
        } else {
            super.setFrameSize(newSize)
        }
    }
    
    override func layout() {
        super.layout()
        guard targetSize != .zero else { return }
        for subview in subviews {
            if subview.frame.size != targetSize || subview.frame.origin != .zero {
                subview.frame = NSRect(origin: .zero, size: targetSize)
            }
        }
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

// MARK: - Skalierbare Badge View (für Export & Seitenleiste)
struct CalloutBadgeView: View {
    let label: String
    var scale: CGFloat = 1.0
    
    var body: some View {
        let size: CGFloat = 24 * scale
        let fontSize: CGFloat = 15 * scale
        let lineWidth: CGFloat = max(1.5, 1.5 * scale)
        let cornerRadius: CGFloat = 3 * scale
        
        Text(label)
            .font(.system(size: fontSize, weight: .bold, design: .default))
            .foregroundColor(.black)
            .frame(width: size, height: size)
            .background(Color.white)
            .cornerRadius(cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.black, lineWidth: lineWidth)
            )
            .shadow(color: Color.black.opacity(0.25), radius: 2 * scale, x: 1 * scale, y: 1 * scale)
            .fixedSize()
    }
}
