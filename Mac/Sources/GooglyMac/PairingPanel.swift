import AppKit
import CoreImage.CIFilterBuiltins
import CryptoKit
import GooglyShared

enum MacPairing {
    static let record: PairingRecord = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Googly")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("pairing-secret")
        let key: Data
        if let saved = try? Data(contentsOf: file), saved.count == 32 { key = saved }
        else {
            key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            do { try key.write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
            catch { fatalError("Could not save the private pairing credential") }
        }
        return PairingRecord(service: Host.current().localizedName ?? "Mac", secret: key)
    }()
}

@MainActor
final class PairingPanel {
    private var panel: NSPanel?
    func show() {
        if let panel { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 440, height: 540), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Bluey · iPhone koppeln"; panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(Theme.panel)
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(MacPairing.record.qrText.utf8)
        let view = NSImageView(frame: CGRect(x: 80, y: 178, width: 280, height: 280))
        if let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
           let cg = CIContext().createCGImage(output, from: output.extent) {
            view.image = NSImage(cgImage: cg, size: NSSize(width: 280, height: 280))
        }
        let card = NSView(frame: view.frame.insetBy(dx: -20, dy: -20))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.cornerRadius = 10
        view.frame = card.bounds.insetBy(dx: 20, dy: 20)
        card.addSubview(view)
        panel.contentView?.addSubview(card)
        let title = NSTextField(labelWithString: "Verbinde dein iPhone")
        title.font = .systemFont(ofSize: 23, weight: .semibold); title.alignment = .center
        title.frame = CGRect(x: 20, y: 487, width: 400, height: 32); panel.contentView?.addSubview(title)
        let copy = NSTextField(wrappingLabelWithString: "Öffne Bluey auf dem iPhone und wähle „Mac koppeln“, um den Code zu scannen. Halte den Kopplungscode privat.\n\nWährend einer Fokus-Session teilt Bluey alle 15 Sekunden den Bildschirm mit dem aktiven Fenster mit OpenAI und speichert dabei keine Screenshots. Pausiere oder beende die Session, um die Freigabe zu stoppen.")
        copy.font = .systemFont(ofSize: 13); copy.frame = CGRect(x: 30, y: 20, width: 380, height: 124)
        panel.contentView?.addSubview(copy)
        self.panel = panel; panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}
