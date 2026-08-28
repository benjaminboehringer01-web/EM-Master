<div align="center">

# 🔬 EM Master
### High-Performance Electron Microscopy Annotation & Flashcard Tool for macOS

[![macOS](https://img.shields.io/badge/platform-macOS%2013%2B-blue?logo=apple)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange?logo=swift)](https://swift.org)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-indigo)](https://developer.apple.com/xcode/swiftui/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

*Annotate micrographs at lightning speed. Export image + labeled bullet points directly to **RemNote**, **Anki**, and **Notion** with a single click.*

[Key Features](#-features) • [Workflow](#-workflow) • [Shortcuts](#-shortcuts) • [Getting Started](#-getting-started)

<br />

<!-- Replace with your actual screenshot / demo gif in your repo -->
<img src="assets/demo-preview.png" alt="EM Master Screenshot" width="850" style="border-radius: 8px; box-shadow: 0 4px 12px rgba(0,0,0,0.15);" />

</div>

---

## ✨ Features

- ⚡️ **Instant Clipboard Pipeline**  
  Copy any SEM/TEM micrograph anywhere and press `⌘V` — it loads with native pixel-perfect dimensions instantly.

- 🔍 **Native Hardware Zoom & Pan (20% – 800%)**  
  Zero lag, silky-smooth pinch-to-zoom and canvas panning powered by AppKit's native `NSScrollView`.

- 🏷 **Smart Callout Markers (A, B, C...)**
  - **Auto-Flip & Boundary Guard:** Markers automatically bend and flip inwards when placed near borders so no label is ever cut off.
  - **Dual-Stroke Contrast Lines:** Crisp black lines with white outlines ensure 100% visibility on both pure black backgrounds and bright cell structures.
  - **Direct Box Mode (`⌘ + Click`):** Place direct labels without pointer lines for large structures (e.g., cell nuclei, cytoplasm).
  - **Drag & Reposition:** Easily drag any badge anywhere on the canvas with 1:1 mouse precision at any zoom level.

- ✂️ **Built-in Precision Cropping**  
  Focus on specific organelles or regions with live aspect-ratio-safe cropping.

- 🚀 **1-Click RemNote / Anki / Notion Export**  
  One button generates a unified **Rich HTML + Image + RTFD clipboard payload**. When pasted into RemNote or Notion, you instantly get:
  1. The annotated high-res image
  2. A clean bullet list (`• A → Mitochondria`) right below it
  3. **Auto-Reset:** Automatically resets the canvas to accept the next image immediately.

---

## ⚡️ Workflow

```mermaid
graph LR
    A[📋 ⌘V Paste Image] --> B[🔍 Zoom & Pan]
    B --> C[🏷 Click / ⌘-Click Markers]
    C --> D[✍️ Type Labels]
    D --> E[🚀 1-Click Export]
    E --> F[📝 Paste directly in RemNote / Anki]
