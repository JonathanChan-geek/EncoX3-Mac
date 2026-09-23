import Foundation
import Darwin
import EncoDiagnostics

// Thin wrapper: all command logic lives in EncoDiagnostics so the menu bar app can expose the
// same modes. A bare launch with no arguments prints the usage; a bare launch from inside the
// app bundle (Finder double-click) runs the read-only probe and logs it.
let arguments = Array(CommandLine.arguments.dropFirst())
let launchedFromBundle = (CommandLine.arguments.first ?? "").contains(".app/Contents/MacOS/")

if arguments.isEmpty && launchedFromBundle {
    exit(CLIRunner.runBundledProbe())
}
exit(CLIRunner.run(arguments: arguments))
