import Foundation
import PeerKit
import StarlingCore
import StarlingLocalP2P

// A Mac stand-in for the second phone in docs/checklists/phase-0-device.md.
//
// Usage: swift run starling-peer [--no-p2p]
// Then type: list | send <number or id prefix> | stats | quit

let usePeerToPeer = !CommandLine.arguments.contains("--no-p2p")
if CommandLine.arguments.contains("--help") {
    print("usage: starling-peer [--no-p2p]\ncommands: list | send <number or id prefix> | stats | quit")
    exit(0)
}

let transport = LocalP2PTransport(localPeer: .random(), includePeerToPeer: usePeerToPeer)
let session = PeerSession(transport: transport)

let printer = Task {
    for await line in session.log {
        print("[\(Date().formatted(date: .omitted, time: .standard))] \(line)")
    }
}

try await session.start()
print("Service \(transport.serviceName), peer-to-peer Wi-Fi \(usePeerToPeer ? "on" : "off"). Type help for commands.")

for try await line in FileHandle.standardInput.bytes.lines {
    let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
    switch parts.first ?? "" {
    case "list":
        let peers = await session.describePeers()
        print(peers.isEmpty ? "No peers yet." : peers.joined(separator: "\n"))
    case "send":
        do {
            try await session.sendProposal(to: parts.count > 1 ? parts[1] : "1")
        } catch {
            print("Send failed: \(error)")
        }
    case "stats":
        print(await session.roundTripSummary() ?? "No round trips yet.")
    case "quit", "exit":
        await session.stop()
        await printer.value
        exit(0)
    case "help", "":
        print("commands: list | send <number or id prefix> | stats | quit")
    default:
        print("Unknown command. Type help.")
    }
}
await session.stop()
