// Verify a Sparkle archive using only the public key shipped in the app.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4,
      let keyData = Data(base64Encoded: args[1]),
      let signature = Data(base64Encoded: args[3]) else {
    fputs("Usage: verify-update.swift PUBLIC_KEY ARCHIVE SIGNATURE\n", stderr)
    exit(2)
}
let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
let archive = try Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: archive) else {
    fputs("Archive signature does not match the app's public key\n", stderr)
    exit(1)
}
print("Archive signature verified")
