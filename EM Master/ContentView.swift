import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Datenmodell
struct CalloutItem: Identifiable, Equatable {
    let id = UUID()
    var index: Int
    var label: String {
        guard index < 26 else { return "\(index + 1)" }
        return String(UnicodeScalar(65 + index)!)
    }
    var targetNorm: CGPoint       // 0.0 ... 1.0
    var boxOffset: CGSize = CGSize(width: -25, height: -25)
    var text: String = ""
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
                            contentSize: image.size
                        ) {
                            canvasContent(image: image, size: image.size)
                        }
                    } else {
                        emptyStateView
                    }
                }
            }
            .frame(minWidth: 520, minHeight: 480)
            
            // RECHTER BEREICH: Notizen & Export
            sidePanelView
        }
        .onPasteCommand(of: [.png, .tiff]) { providers in
            loadImage(from: providers)
        }
        .onAppear {
            pasteFromClipboard()
        }
    }
    
    // MARK: - Bildinhalt (Vollflächig klickbar über gesamte Bilddimension)
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
                    for item in callouts {
                        let target = CGPoint(
                            x: item.targetNorm.x * size.width,
                            y: item.targetNorm.y * size.height
                        )
                        let boxCenter = CGPoint(
                            x: target.x + item.boxOffset.width,
                            y: target.y + item.boxOffset.height
                        )
                        
                        var path = Path()
                        path.move(to: target)
                        path.addLine(to: boxCenter)
                        context.stroke(path, with: .color(.black), lineWidth: max(1.5, size.width * 0.0015))
                    }
                }
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
            }
            
            // 3. Native Klick- & Drag-Ebene in SwiftUI (Deckungsgleich bis zur untersten Kante)
            Color.clear
                .contentShape(Rectangle())
                .frame(width: size.width, height: size.height)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            if mode == .crop {
                                let start = value.startLocation
                                let current = value.location
                                
                                let minX = max(0, min(size.width, min(start.x, current.x)))
                                let minY = max(0, min(size.height, min(start.y, current.y)))
                                let maxX = max(0, min(size.width, max(start.x, current.x)))
                                let maxY = max(0, min(size.height, max(start.y, current.y)))
                                
                                let normRect = CGRect(
                                    x: minX / size.width,
                                    y: minY / size.height,
                                    width: max(0.02, (maxX - minX) / size.width),
                                    height: max(0.02, (maxY - minY) / size.height)
                                )
                                self.cropRectNorm = normRect
                            }
                        }
                        .onEnded { value in
                            if mode == .annotate {
                                let dist = hypot(value.translation.width, value.translation.height)
                                if dist < 6 { // Klick registriert
                                    let normX = max(0, min(1, value.location.x / size.width))
                                    let normY = max(0, min(1, value.location.y / size.height))
                                    addCallout(at: CGPoint(x: normX, y: normY))
                                }
                            }
                        }
                )
            
            // 4. Buchstaben-Boxen
            if mode == .annotate {
                ForEach($callouts) { $item in
                    DraggableCalloutBadge(item: $item, containerSize: size)
                }
            }
            
            // 5. Crop-Overlay
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
    private func addCallout(at normPoint: CGPoint) {
        let nextIndex = callouts.count
        let newItem = CalloutItem(
            index: nextIndex,
            targetNorm: normPoint,
            boxOffset: CGSize(width: -30, height: -30)
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
    
    // MARK: - Pasteboard & Export
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
    }
    
    private func copyTextToClipboard() {
        let lines = callouts.map { "• \($0.label) -> \($0.text)" }
        let text = lines.joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
    
    @MainActor
    private func copyAnnotatedImageToClipboard() {
        guard let image = image else { return }
        
        let renderView = ZStack {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: image.size.width, height: image.size.height)
            
            Canvas { context, size in
                for item in callouts {
                    let target = CGPoint(
                        x: item.targetNorm.x * size.width,
                        y: item.targetNorm.y * size.height
                    )
                    let boxCenter = CGPoint(
                        x: target.x + item.boxOffset.width,
                        y: target.y + item.boxOffset.height
                    )
                    
                    var path = Path()
                    path.move(to: target)
                    path.addLine(to: boxCenter)
                    context.stroke(path, with: .color(.black), lineWidth: max(2, size.width * 0.003))
                }
            }
            
            ForEach(callouts) { item in
                let target = CGPoint(
                    x: item.targetNorm.x * image.size.width,
                    y: item.targetNorm.y * image.size.height
                )
                let boxCenter = CGPoint(
                    x: target.x + item.boxOffset.width,
                    y: target.y + item.boxOffset.height
                )
                
                CalloutBadgeView(label: item.label)
                    .position(boxCenter)
            }
        }
        .frame(width: image.size.width, height: image.size.height)
        
        let renderer = ImageRenderer(content: renderView)
        renderer.scale = 2.0
        if let nsImage = renderer.nsImage {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([nsImage])
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
                        callouts.removeAll()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                    .font(.caption)
                }
            }
            
            Divider()
            
            if callouts.isEmpty {
                Text("Klicke auf Strukturen im Bild, um Marker (A, B, C...) zu setzen.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach($callouts) { $item in
                            HStack(spacing: 8) {
                                CalloutBadgeView(label: item.label)
                                
                                Image(systemName: "arrow.right")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                                
                                TextField("Back of card", text: $item.text)
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
                    .padding(.vertical, 4)
                }
            }
            
            Spacer()
            
            VStack(spacing: 8) {
                Button(action: copyAnnotatedImageToClipboard) {
                    Label("Bild kopieren (mit Markern)", systemImage: "photo.badge.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
                
                Button(action: copyTextToClipboard) {
                    Label("Text / Anki-Liste kopieren", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
                .buttonStyle(.borderedProminent)
            }
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

// MARK: - Einzelner ziehbarer Badge (Präzise Hitbox)
struct DraggableCalloutBadge: View {
    @Binding var item: CalloutItem
    let containerSize: CGSize
    @State private var dragBaseOffset: CGSize? = nil
    
    var body: some View {
        let target = CGPoint(
            x: item.targetNorm.x * containerSize.width,
            y: item.targetNorm.y * containerSize.height
        )
        let currentBoxPos = CGPoint(
            x: target.x + item.boxOffset.width,
            y: target.y + item.boxOffset.height
        )
        
        CalloutBadgeView(label: item.label)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragBaseOffset == nil {
                            dragBaseOffset = item.boxOffset
                        }
                        if let base = dragBaseOffset {
                            item.boxOffset = CGSize(
                                width: base.width + value.translation.width,
                                height: base.height + value.translation.height
                            )
                        }
                    }
                    .onEnded { _ in
                        dragBaseOffset = nil
                    }
            )
            .position(currentBoxPos)
    }
}

// MARK: - Native AppKit ScrollView
struct NativeZoomableScrollView<Content: View>: NSViewRepresentable {
    @Binding var magnification: CGFloat
    let contentSize: CGSize
    let content: Content

    init(magnification: Binding<CGFloat>, contentSize: CGSize, @ViewBuilder content: () -> Content) {
        self._magnification = magnification
        self.contentSize = contentSize
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

        let hostingView = HostingDocumentView(rootView: content)
        hostingView.targetSize = contentSize
        hostingView.frame = NSRect(origin: .zero, size: contentSize)
        hostingView.autoresizingMask = []
        scrollView.documentView = hostingView
        
        context.coordinator.hostingView = hostingView
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
        if let doc = nsView.documentView as? HostingDocumentView<Content> {
            doc.rootView = content
            if doc.targetSize != contentSize {
                doc.targetSize = contentSize
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
        var hostingView: HostingDocumentView<Content>?
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

// MARK: - Hosting Document View
class HostingDocumentView<Content: View>: NSHostingView<Content> {
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
            .shadow(color: Color.black.opacity(0.2), radius: 2, x: 1, y: 1)
    }
}
