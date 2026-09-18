import Foundation
import CryptoKit
let args = CommandLine.arguments
let data = try Data(contentsOf: URL(fileURLWithPath: args[1]), options: .mappedIfSafe)
let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: args[2])!)
guard let signature = Data(base64Encoded: args[3]), key.isValidSignature(signature, for: data) else {
    fputs("Update signature does not match embedded public key\n", stderr); exit(1)
}
print("Update signature verified")
