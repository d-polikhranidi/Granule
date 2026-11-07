import Foundation
import CryptoKit

// Talks to the App Store Connect API from the command line: signs a JWT with the API key and
// prints the HTTP status, then the response as pretty JSON. Exits 1 on an HTTP error.
//
//   source Tools/asc-env.sh; swift Tools/asc.swift GET /v1/apps/$ASC_APP
//   ... swift Tools/asc.swift POST /v1/betaBuildLocalizations '{"data":{...}}'
//
// The key is read from disk and never printed: it is the credential that uploads builds and
// changes prices.

let env = ProcessInfo.processInfo.environment
guard let keyID = env["ASC_KEY_ID"], let issuer = env["ASC_ISSUER"] else {
    FileHandle.standardError.write(Data("ASC_KEY_ID and ASC_ISSUER are needed (source Tools/asc-env.sh)\n".utf8))
    exit(2)
}
let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: asc.swift METHOD PATH [JSON BODY]\n".utf8))
    exit(2)
}
let method = args[0], path = args[1]
let body = args.count > 2 ? args[2] : nil

let home = FileManager.default.homeDirectoryForCurrentUser
let keyURL = home.appendingPathComponent(".appstoreconnect/private_keys/AuthKey_\(keyID).p8")
guard let pem = try? String(contentsOf: keyURL, encoding: .utf8) else {
    FileHandle.standardError.write(Data("can't read the key at \(keyURL.path)\n".utf8))
    exit(2)
}

func base64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

let key = try! P256.Signing.PrivateKey(pemRepresentation: pem)
let now = Int(Date().timeIntervalSince1970)
let header = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
// Apple accepts tokens of up to twenty minutes.
let claims: [String: Any] = ["iss": issuer, "iat": now, "exp": now + 15 * 60,
                             "aud": "appstoreconnect-v1"]
let head = base64url(try! JSONSerialization.data(withJSONObject: header, options: .sortedKeys))
let load = base64url(try! JSONSerialization.data(withJSONObject: claims, options: .sortedKeys))
let signing = "\(head).\(load)"
let signature = try! key.signature(for: Data(signing.utf8))
let token = "\(signing).\(base64url(signature.rawRepresentation))"

var request = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com" + path)!)
request.httpMethod = method
request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
if let body { request.httpBody = Data(body.utf8) }

let wait = DispatchSemaphore(value: 0)
var code = 0
URLSession.shared.dataTask(with: request) { data, response, error in
    defer { wait.signal() }
    if let error {
        FileHandle.standardError.write(Data("network: \(error)\n".utf8))
        code = 1
        return
    }
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status >= 400 { code = 1 }
    if let data, !data.isEmpty {
        let pretty = (try? JSONSerialization.jsonObject(with: data))
            .flatMap { try? JSONSerialization.data(withJSONObject: $0,
                                                   options: [.prettyPrinted, .sortedKeys,
                                                             .withoutEscapingSlashes]) }
        print("HTTP \(status)")
        print(String(data: pretty ?? data, encoding: .utf8) ?? "")
    } else {
        print("HTTP \(status)")
    }
}.resume()
wait.wait()
exit(Int32(code))
