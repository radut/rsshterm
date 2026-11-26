import Foundation
import RSSHVNC

// rssh-rfb-probe <host> [port] [--json]: see RFBProbeCommand.
let (status, output) = await RFBProbeCommand.run(Array(CommandLine.arguments.dropFirst()))
FileHandle.standardOutput.write(Data((output + "\n").utf8))
exit(status)
