import SwiftUI
import AppKit

/// Developer aid: `TwentyThree --snapshot <dir>` renders the presence in several states to PNGs and exits.
@MainActor
enum Snapshot {
    /// Sample conversation showing the code-tool cards (used by `--demo-cards`).
    static func codeDemo() -> [ChatMessage] {
        [
            ChatMessage(role: .user, text: "Make fib.py print 15 numbers and run it, then install requests."),
            ChatMessage(role: .action, text: "", action: ActionCard(tool: "edit_file", title: "Edit ~/Developer/23-workspace/fib.py", status: .done,
                detail: "Edited ~/Developer/23-workspace/fib.py at line 11.", undo: .memoryAdded("demo"),
                diff: "@@ line 11\n  if __name__ == \"__main__\":\n-     print(\"First 10 Fibonacci numbers:\")\n-     for i, value in enumerate(fib(10), start=1):\n+     print(\"First 15 Fibonacci numbers:\")\n+     for i, value in enumerate(fib(15), start=1):")),
            ChatMessage(role: .action, text: "", action: ActionCard(tool: "run_command", title: "$ python3 fib.py  (in ~/Developer/23-workspace)", status: .done,
                detail: "(exit code 0, 0.1 s)", output: "First 15 Fibonacci numbers:\n 1. 0\n 2. 1\n 3. 1\n 4. 2\n 5. 3\n 6. 5\n 7. 8\n 8. 13\n 9. 21\n10. 34\n11. 55\n12. 89\n13. 144\n14. 233\n15. 377")),
            ChatMessage(role: .action, text: "", action: ActionCard(tool: "run_command", title: "$ pip install requests  (in ~/Developer/23-workspace)", status: .awaitingApproval,
                detail: "Asking because it needs the internet, it installs or updates software packages.")),
        ]
    }

    static func run(dir: String) {
        let moods: [(String, PresenceMood)] = [("presence-idle", .idle), ("presence-listening", .listening), ("presence-thinking", .thinking),
                                               ("presence-working", .working), ("presence-needs-you", .needsYou), ("presence-error", .error)]
        // Words arriving: the same sentence at rest, and with its last 30 characters still on their way.
        let sample = "The capital of Australia is **Canberra**, not Sydney. It was chosen in 1908 as a compromise between Sydney and Melbourne, and Parliament first sat there in 1927."
        for (name, shown) in [("words-rest", sample.count), ("words-arriving", sample.count - 30)] {
            let view = Text(LocalizedStringKey(sample)).font(DS.Text.reading).lineSpacing(4)
                .textRenderer(StreamReveal(shown: Double(shown), total: sample.count))
                .frame(width: 360, alignment: .leading).padding(20)
                .background(Color(nsColor: .windowBackgroundColor))
            let r = ImageRenderer(content: view); r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
        }
        for (name, mood) in moods {
            let view = LensDrop(mood: mood, t: 0.9, level: 0.6, size: 120).frame(width: 300, height: 200)
                .background(Color(nsColor: .windowBackgroundColor))
            let r = ImageRenderer(content: view); r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            }
        }
    }
}
