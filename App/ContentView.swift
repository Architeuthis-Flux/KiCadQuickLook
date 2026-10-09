import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var droppedFileURL: URL?
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if let url = droppedFileURL {
                KiCanvasPreview(fileURL: url)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            droppedFileURL = nil
                        } label: {
                            Label("Close", systemImage: "xmark.circle.fill")
                                .labelStyle(.iconOnly)
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                        .padding(12)
                    }
            } else {
                welcome
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url = url,
                      ["kicad_pcb", "kicad_sch", "kicad_pro", "step", "stp", "3mf"]
                          .contains(url.pathExtension.lowercased())
                else { return }
                DispatchQueue.main.async { droppedFileURL = url }
            }
            return true
        }
    }

    private var welcome: some View {
        VStack(spacing: 24) {
            Image(systemName: "cpu")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("KiCad Quick Look")
                .font(.largeTitle.bold())

            VStack(alignment: .leading, spacing: 12) {
                instructionRow(
                    number: "1",
                    text: "Keep this app in /Applications (or anywhere permanent). It hosts the Quick Look extensions."
                )
                instructionRow(
                    number: "2",
                    text: "Enable “KiCad Preview” and “KiCad Thumbnails” in System Settings → General → Login Items & Extensions → Quick Look."
                )
                instructionRow(
                    number: "3",
                    text: "Select any .kicad_pcb, .kicad_sch, .kicad_pro, .step, or .3mf file in Finder and press Space."
                )
            }
            .frame(maxWidth: 460)

            Divider().frame(maxWidth: 460)

            VStack(spacing: 6) {
                Text("Test it here")
                    .font(.headline)
                Text("Drop a KiCad, STEP, or 3MF file onto this window to preview it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: 460)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                        style: StrokeStyle(lineWidth: 2, dash: [8])
                    )
            )

            Text("KiCad rendering by KiCanvas (kicanvas.org) · 3D rendering by Online 3D Viewer and Open CASCADE")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }

    private func instructionRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.callout.bold())
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor.opacity(0.2)))
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Renders a dropped KiCad file with the same pipeline the QL extension uses.
struct KiCanvasPreview: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> KiCanvasWebView {
        let webView = KiCanvasWebView(frame: .zero)
        load(into: webView)
        return webView
    }

    func updateNSView(_ webView: KiCanvasWebView, context: Context) {
        if context.coordinator.currentURL != fileURL {
            load(into: webView)
            context.coordinator.currentURL = fileURL
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(currentURL: fileURL)
    }

    final class Coordinator {
        var currentURL: URL
        init(currentURL: URL) { self.currentURL = currentURL }
    }

    private func load(into webView: KiCanvasWebView) {
        let page: PreviewHTMLBuilder.Page
        do {
            let content = try KiCadFileLoader.loadPreviewContent(for: fileURL)
            page = try PreviewHTMLBuilder.page(for: content)
        } catch {
            page = PreviewHTMLBuilder.Page(
                html: PreviewHTMLBuilder.messagePage(
                    title: fileURL.lastPathComponent,
                    detail: error.localizedDescription
                ),
                resources: [:]
            )
        }
        webView.render(page: page) { _ in }
    }
}

#Preview {
    ContentView()
}
