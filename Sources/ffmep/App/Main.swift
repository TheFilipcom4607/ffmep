import Foundation

/// One binary, two front ends: `ffmep convert …` and the other commands run in the terminal,
/// anything else (Finder, `open`, the Dock) starts the app.
@main
enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard CLI.handles(arguments) else {
            FfmepApp.main()
            return
        }
        Task { @MainActor in
            let status = await CLI.run(arguments)
            exit(status)
        }
        dispatchMain()
    }
}
