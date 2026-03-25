//
//  FetchAnisetteDataOperation.swift
//  AltStore
//
//  Created by Riley Testut on 1/7/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation
import CommonCrypto
import Starscream
import KeychainAccess
import StosSign

final class AnisetteDataHelper: WebSocketDelegate {
    var socket: WebSocket!
    
    var url: URL?
    var startProvisioningURL: URL?
    var endProvisioningURL: URL?
    
    var clientInfo: String?
    var userAgent: String?
    
    var mdLu: String?
    var deviceId: String?
    
    var menuAnisetteURL: String?
    
    private var wsContinuation: CheckedContinuation<Void, Error>?
    
    static var shared: AnisetteDataHelper = AnisetteDataHelper()
    
    var loggingFunc: ((String) -> Void)?
    
    func getAnisetteData(refresh: Bool = false) async throws -> AnisetteData {
        guard let url else {
            throw "No Anisette Server Found!"
        }
        
        if refresh {
            Keychain.shared.adiPb = nil
        }
        
        self.printOut("Anisette URL: \(url.absoluteString)")
        
        if let identifier = Keychain.shared.identifier,
           let adiPb = Keychain.shared.adiPb {
            return try await self.fetchAnisetteV3(identifier, adiPb)
        } else {
            return try await self.provision()
        }
    }
    
    // MARK: - COMMON
    
    func extractAnisetteData(_ data: Data, _ response: HTTPURLResponse?, v3: Bool) async throws -> AnisetteData {
        guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: String] else {
            throw "Invalid anisette (the returned data may not be in JSON)"
        }
        
        if v3, json["result"] == "GetHeadersError" {
            let message = json["message"]
            self.printOut("Error getting V3 headers: \(message ?? "no message")")
            if let message, message.contains("-45061") {
                self.printOut("Error message contains -45061 (not provisioned), resetting adi.pb and retrying")
                Keychain.shared.adiPb = nil
                return try await provision()
            } else {
                throw message ?? "Unknown error"
            }
        }
        
        var formattedJSON: [String: String] = ["deviceSerialNumber": "0"]
        if let machineID = json["X-Apple-I-MD-M"] { formattedJSON["machineID"] = machineID }
        if let oneTimePassword = json["X-Apple-I-MD"] { formattedJSON["oneTimePassword"] = oneTimePassword }
        if let routingInfo = json["X-Apple-I-MD-RINFO"] { formattedJSON["routingInfo"] = routingInfo }
        
        if v3 {
            guard let clientInfo, let mdLu, let deviceId else {
                throw "Missing anisette client info. Please clean up the keychain and try again."
            }
            
            formattedJSON["deviceDescription"] = clientInfo
            formattedJSON["localUserID"] = mdLu
            formattedJSON["deviceUniqueIdentifier"] = deviceId
            
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            formattedJSON["date"] = formatter.string(from: Date())
            formattedJSON["locale"] = Locale.current.identifier
            formattedJSON["timeZone"] = TimeZone.current.abbreviation() ?? TimeZone.current.identifier
        } else {
            if let deviceDescription = json["X-MMe-Client-Info"] { formattedJSON["deviceDescription"] = deviceDescription }
            if let localUserID = json["X-Apple-I-MD-LU"] { formattedJSON["localUserID"] = localUserID }
            if let deviceUniqueIdentifier = json["X-Mme-Device-Id"] { formattedJSON["deviceUniqueIdentifier"] = deviceUniqueIdentifier }
            
            if let date = json["X-Apple-I-Client-Time"] { formattedJSON["date"] = date }
            if let locale = json["X-Apple-Locale"] { formattedJSON["locale"] = locale }
            if let timeZone = json["X-Apple-I-TimeZone"] { formattedJSON["timeZone"] = timeZone }
        }
        
        if let response,
           let version = response.value(forHTTPHeaderField: "Implementation-Version") {
            self.printOut("Implementation-Version: \(version)")
        } else {
            self.printOut("No Implementation-Version header")
        }
        
        self.printOut("Anisette used: \(formattedJSON)")
        self.printOut("Original JSON: \(json)")
        
        do {
            let jsonData = try JSONEncoder().encode(formattedJSON)
            let anisette = try JSONDecoder().decode(AnisetteData.self, from: jsonData)
            self.printOut("Anisette is valid!")
            return anisette
        } catch {
            self.printOut("Anisette is invalid!!!!")
            throw "Invalid anisette (the returned data may not have all the required fields)"
        }
    }
    
    // MARK: - V3: PROVISIONING
    
    func provision() async throws -> AnisetteData {
        try await fetchClientInfo()
        self.printOut("Getting provisioning URLs")
        
        var request = try self.buildAppleRequest(url: URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!)
        request.httpMethod = "GET"
        
        let (data, _) = try await URLSession.shared.data(for: request)
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]],
           let startProvisioningString = plist["urls"]?["midStartProvisioning"] as? String,
           let startProvisioningURL = URL(string: startProvisioningString),
           let endProvisioningString = plist["urls"]?["midFinishProvisioning"] as? String,
           let endProvisioningURL = URL(string: endProvisioningString) {
            self.startProvisioningURL = startProvisioningURL
            self.endProvisioningURL = endProvisioningURL
            self.printOut("startProvisioningURL: \(startProvisioningURL.absoluteString)")
            self.printOut("endProvisioningURL: \(endProvisioningURL.absoluteString)")
            self.printOut("Starting a provisioning session")
            return try await self.startProvisioningSession()
        } else {
            self.printOut("Apple didn't give valid URLs! Got response: \(String(data: data, encoding: .utf8) ?? "not utf8")")
            throw "Apple didn't give valid URLs. Please try again later"
        }
    }
    
    func startProvisioningSession() async throws -> AnisetteData {
        guard let url else {
            throw "No Anisette Server Found!"
        }
        
        let provisioningSessionURL = url.appendingPathComponent("v3").appendingPathComponent("provisioning_session")
        var wsRequest = URLRequest(url: provisioningSessionURL)
        wsRequest.timeoutInterval = 5
        self.socket = WebSocket(request: wsRequest)
        self.socket.delegate = self
        
        try await withCheckedThrowingContinuation { continuation in
            self.wsContinuation = continuation
            self.socket.connect()
        }
        
        guard let identifier = Keychain.shared.identifier,
              let adiPb = Keychain.shared.adiPb else {
            throw "Provisioning finished, but the anisette session could not be saved. Please try again."
        }
        
        return try await self.fetchAnisetteV3(identifier, adiPb)
    }
    
    func didReceive(event: WebSocketEvent, client: WebSocketClient) {
        switch event {
        case .text(let string):
            do {
                guard let jsonData = string.data(using: .utf8),
                      let json = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] else {
                    throw "The server didn't give valid JSON"
                }
                
                guard let result = json["result"] as? String else {
                    self.printOut("The server didn't give us a result")
                    client.disconnect(closeCode: 0)
                    failProvisioning("The server didn't give us a result")
                    return
                }
                
                self.printOut("Received result: \(result)")
                switch result {
                case "GiveIdentifier":
                    guard let identifier = Keychain.shared.identifier else {
                        client.disconnect(closeCode: 0)
                        failProvisioning("Missing identifier. Please clean up the keychain and try again.")
                        return
                    }
                    
                    self.printOut("Giving identifier")
                    client.json(["identifier": identifier])
                    
                case "GiveStartProvisioningData":
                    self.printOut("Getting start provisioning data")
                    let body: [String: Any] = [
                        "Header": [String: Any](),
                        "Request": [String: Any]()
                    ]
                    
                    guard let startProvisioningURL else {
                        client.disconnect(closeCode: 0)
                        failProvisioning("Missing start provisioning URL. Please try again later.")
                        return
                    }
                    
                    do {
                        var request = try self.buildAppleRequest(url: startProvisioningURL)
                        request.httpMethod = "POST"
                        request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
                        URLSession.shared.dataTask(with: request) { data, _, _ in
                            if let data,
                               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]],
                               let spim = plist["Response"]?["spim"] as? String {
                                self.printOut("Giving start provisioning data")
                                client.json(["spim": spim])
                            } else {
                                self.printOut("Apple didn't give valid start provisioning data! Got response: \(String(data: data ?? Data("nothing".utf8), encoding: .utf8) ?? "not utf8")")
                                client.disconnect(closeCode: 0)
                                self.failProvisioning("Apple didn't give valid start provisioning data. Please try again later")
                            }
                        }.resume()
                    } catch {
                        client.disconnect(closeCode: 0)
                        failProvisioning(error)
                    }
                    
                case "GiveEndProvisioningData":
                    self.printOut("Getting end provisioning data")
                    guard let cpim = json["cpim"] as? String else {
                        self.printOut("The server didn't give us a cpim")
                        client.disconnect(closeCode: 0)
                        failProvisioning("The server didn't give us a cpim")
                        return
                    }
                    
                    let body: [String: Any] = [
                        "Header": [String: Any](),
                        "Request": [
                            "cpim": cpim
                        ]
                    ]
                    
                    guard let endProvisioningURL else {
                        client.disconnect(closeCode: 0)
                        failProvisioning("Missing end provisioning URL. Please try again later.")
                        return
                    }
                    
                    do {
                        var request = try self.buildAppleRequest(url: endProvisioningURL)
                        request.httpMethod = "POST"
                        request.httpBody = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
                        URLSession.shared.dataTask(with: request) { data, _, _ in
                            if let data,
                               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]],
                               let ptm = plist["Response"]?["ptm"] as? String,
                               let tk = plist["Response"]?["tk"] as? String {
                                self.printOut("Giving end provisioning data")
                                client.json(["ptm": ptm, "tk": tk])
                            } else {
                                self.printOut("Apple didn't give valid end provisioning data! Got response: \(String(data: data ?? Data("nothing".utf8), encoding: .utf8) ?? "not utf8")")
                                client.disconnect(closeCode: 0)
                                self.failProvisioning("Apple didn't give valid end provisioning data. Please try again later")
                            }
                        }.resume()
                    } catch {
                        client.disconnect(closeCode: 0)
                        failProvisioning(error)
                    }
                    
                case "ProvisioningSuccess":
                    self.printOut("Provisioning succeeded!")
                    client.disconnect(closeCode: 0)
                    
                    guard let adiPb = json["adi_pb"] as? String else {
                        self.printOut("The server didn't give us an adi.pb file")
                        failProvisioning("The server didn't give us an adi.pb file")
                        return
                    }
                    
                    Keychain.shared.adiPb = adiPb
                    finishProvisioning()
                    
                default:
                    if result.contains("Error") || result.contains("Invalid") || result == "ClosingPerRequest" || result == "Timeout" || result == "TextOnly" {
                        self.printOut("Failing because of \(result)")
                        failProvisioning(result + (json["message"] as? String ?? ""))
                    }
                }
            } catch {
                self.printOut("Failed to handle text: \(error.localizedDescription)")
                failProvisioning(error)
            }
            
        case .connected:
            self.printOut("Connected")
            
        case .disconnected(let string, let code):
            self.printOut("Disconnected: \(code); \(string)")
            if wsContinuation != nil {
                failProvisioning("Provisioning session disconnected unexpectedly. \(string)")
            }
            
        case .peerClosed:
            self.printOut("PeerClosed")
            if wsContinuation != nil {
                failProvisioning("Provisioning session closed by server.")
            }
            
        case .error(let error):
            self.printOut("Got error: \(String(describing: error))")
            if let error {
                failProvisioning(error)
            } else if wsContinuation != nil {
                failProvisioning("Unknown WebSocket error")
            }
            
        default:
            self.printOut("Unknown event: \(event)")
        }
    }
    
    func buildAppleRequest(url: URL) throws -> URLRequest {
        guard let clientInfo, let userAgent, let mdLu, let deviceId else {
            throw "Missing anisette client info. Please clean up the keychain and try again."
        }
        
        var request = URLRequest(url: url)
        request.setValue(clientInfo, forHTTPHeaderField: "X-Mme-Client-Info")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(mdLu, forHTTPHeaderField: "X-Apple-I-MD-LU")
        request.setValue(deviceId, forHTTPHeaderField: "X-Mme-Device-Id")
        
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        request.setValue(formatter.string(from: Date()), forHTTPHeaderField: "X-Apple-I-Client-Time")
        request.setValue(Locale.current.identifier, forHTTPHeaderField: "X-Apple-Locale")
        request.setValue(TimeZone.current.abbreviation() ?? TimeZone.current.identifier, forHTTPHeaderField: "X-Apple-I-TimeZone")
        return request
    }
    
    // MARK: - V3: FETCHING
    
    func fetchClientInfo() async throws {
        if self.clientInfo != nil,
           self.userAgent != nil,
           self.mdLu != nil,
           self.deviceId != nil,
           Keychain.shared.identifier != nil {
            self.printOut("Skipping client_info fetch since all the properties we need aren't nil")
            return
        }
        
        guard let url else {
            throw "No Anisette Server Found!"
        }
        
        self.printOut("Trying to get client_info")
        let clientInfoURL = url.appendingPathComponent("v3").appendingPathComponent("client_info")
        let (data, _) = try await URLSession.shared.data(from: clientInfoURL)
        
        guard let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: String] else {
            throw "Couldn't fetch client info. The returned data may not be in JSON"
        }
        
        guard let clientInfo = json["client_info"],
              let userAgent = json["user_agent"] else {
            throw "Couldn't fetch client info. The anisette server response is missing required fields."
        }
        
        self.printOut("Server is V3")
        self.clientInfo = clientInfo
        self.userAgent = userAgent
        self.printOut("Client-Info: \(clientInfo)")
        self.printOut("User-Agent: \(userAgent)")
        
        if Keychain.shared.identifier == nil {
            self.printOut("Generating identifier")
            var bytes = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            
            if status != errSecSuccess {
                self.printOut("ERROR GENERATING IDENTIFIER!!! \(status)")
                throw "Couldn't generate identifier"
            }
            
            Keychain.shared.identifier = Data(bytes).base64EncodedString()
        }
        
        guard let identifier = Keychain.shared.identifier,
              let decoded = Data(base64Encoded: identifier),
              decoded.count == 16 else {
            throw "Saved identifier is invalid. Please clean up the keychain and try again."
        }
        
        self.mdLu = decoded.sha256().hexEncodedString()
        self.printOut("X-Apple-I-MD-LU: \(self.mdLu ?? "nil")")
        
        let uuid = try decoded.uuidValue()
        self.deviceId = uuid.uuidString.uppercased()
        self.printOut("X-Mme-Device-Id: \(self.deviceId ?? "nil")")
    }
    
    func fetchAnisetteV3(_ identifier: String, _ adiPb: String) async throws -> AnisetteData {
        try await fetchClientInfo()
        self.printOut("Fetching anisette V3")
        
        guard let url else {
            throw "No Anisette Server Found!"
        }
        
        var request = URLRequest(url: url.appendingPathComponent("v3").appendingPathComponent("get_headers"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "identifier": identifier,
            "adi_pb": adiPb
        ], options: [])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        
        return try await self.extractAnisetteData(data, response as? HTTPURLResponse, v3: true)
    }
    
    private func finishProvisioning() {
        guard let continuation = wsContinuation else { return }
        wsContinuation = nil
        continuation.resume()
    }
    
    private func failProvisioning(_ error: Error) {
        guard let continuation = wsContinuation else { return }
        wsContinuation = nil
        continuation.resume(throwing: error)
    }
    
    private func printOut(_ text: String?) {
        let isInternalLoggingEnabled = true
        guard isInternalLoggingEnabled else { return }

        if let loggingFunc {
            loggingFunc(text ?? "")
        } else if let text {
            print(text)
        } else {
            print()
        }
    }
}

extension WebSocketClient {
    func json(_ dictionary: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary, options: []),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        self.write(string: string)
    }
}

extension Data {
    // https://stackoverflow.com/a/25391020
    func sha256() -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(self.count), &hash)
        }
        return Data(hash)
    }
    
    // https://stackoverflow.com/a/40089462
    func hexEncodedString() -> String {
        return self.map { String(format: "%02hhX", $0) }.joined()
    }
    
    func uuidValue() throws -> UUID {
        guard self.count == 16 else {
            throw "Identifier has an invalid size. Please clean up the keychain and try again."
        }
        
        let bytes = Array(self)
        let tuple: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: tuple)
    }
}
