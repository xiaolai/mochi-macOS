import Foundation
import Security

public enum Credentials {
    public static let service = AppIdentity.bundleIdentifier
    public static func read(_ name: String) -> String? {
        if let value = keychainValue(name,service:service) { return value }
        if let legacy = keychainValue(name,service:AppIdentity.legacyBundleIdentifier) {
            try? save(legacy,name:name)
            return legacy
        }
        return ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }
    }
    private static func keychainValue(_ name: String, service: String) -> String? {
        let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service, kSecAttrAccount as String:name, kSecReturnData as String:true, kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data:data,encoding:.utf8)
    }
    public static func save(_ value: String, name: String) throws {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:name]
        if value.isEmpty {
            SecItemDelete(query as CFDictionary)
            var legacy = query; legacy[kSecAttrService as String] = AppIdentity.legacyBundleIdentifier
            SecItemDelete(legacy as CFDictionary)
            return
        }
        let attributes: [String:Any] = [kSecValueData as String:Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppFailure("Could not save the credential in Keychain.") }
    }
    public static func codexToken() throws -> String {
        let base = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let url = base.appendingPathComponent("auth.json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath:url.path), (attrs[.size] as? NSNumber)?.intValue ?? Int.max < 65536,
              let data = try? Data(contentsOf:url), let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let tokens = object["tokens"] as? [String:Any], let token = tokens["access_token"] as? String, !token.isEmpty else {
            throw AppFailure("No readable Codex sign-in. Sign in through Codex or explicitly choose API key in Settings.")
        }
        return token
    }
}
public enum ServiceHTTP {
    public static func failure(status: Int, provider: String) -> AppFailure {
        switch status {
        case 401: return AppFailure("\(provider) credentials were rejected. Update them in Settings.")
        case 403: return AppFailure("This account does not have access to \(provider).")
        case 429: return AppFailure("\(provider) usage limit reached. Retry later.")
        default: return AppFailure("\(provider) request failed (HTTP \(status)). Check Settings and retry.")
        }
    }
    public static func data(_ request: URLRequest, provider: String) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 90
        let session = URLSession(configuration:config, delegate:NoRedirect(), delegateQueue:nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes,response) = try await session.bytes(for:request)
            guard let response = response as? HTTPURLResponse else { throw AppFailure("\(provider) returned an invalid response.") }
            guard (200..<300).contains(response.statusCode) else { throw failure(status: response.statusCode, provider:provider) }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                guard data.count <= 16_000_000 else { throw AppFailure("\(provider) response was too large.") }
            }
            return data
        } catch let error as AppFailure { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw AppFailure("Cannot reach \(provider). Check your connection and retry.") }
    }
}
private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
enum RealtimeEvents {
    static func message(role: String, text: String) -> [String:Any] {
        ["type":"conversation.item.create", "item":["type":"message", "role":role,
            "content":[["type":role == "assistant" ? "output_text" : "input_text", "text":text]]]]
    }
    static func failure(_ error: [String:Any]?) -> AppFailure {
        // Never echo arbitrary provider messages: they can contain user input or credentials.
        let code = error?["code"] as? String ?? ""
        switch code {
        case "invalid_value", "invalid_request_error", "unknown_parameter", "missing_required_parameter", "invalid_parameter", "decimal_max_decimal_places_exceeded":
            let param = error?["param"] as? String ?? ""
            let field = (param == "session.audio.output.speed" || param.range(of: #"^item\.content\[[0-9]{1,2}\]\.type$"#, options:.regularExpression) != nil) ? "; field: \(param)" : ""
            return AppFailure("OpenAI rejected Mochi's request format (\(code)\(field)).")
        case "invalid_api_key", "authentication_error":
            return AppFailure("OpenAI credentials were rejected. Update the connection in Settings.")
        case "rate_limit_exceeded", "insufficient_quota":
            return AppFailure("OpenAI usage limit reached (\(code)). Check your usage or retry later.")
        case "model_not_found":
            return AppFailure("OpenAI could not access the selected model. Check the model in Settings.")
        default:
            return AppFailure("OpenAI rejected this request. Please retry; the cause could not be identified.")
        }
    }
}
public struct RealtimeAccumulator {
    public var text = ""
    public var audio = Data()
    public var inputTranscript = ""
    public var done = false
    public var transcriptionState: TranscriptionState = .pending
    public var transcriptionError: String?
    public var inputItemID: String?
    public init() {}
    public mutating func accept(_ event: [String:Any]) throws {
        switch event["type"] as? String {
        case "response.output_text.delta", "response.text.delta", "response.output_audio_transcript.delta", "response.audio_transcript.delta": text += event["delta"] as? String ?? ""
        case "response.output_audio.delta", "response.audio.delta":
            if let encoded = event["delta"] as? String, let chunk = Data(base64Encoded:encoded) { audio.append(chunk) }
            guard audio.count < 16_000_000 else { throw AppFailure("Mochi's response exceeded the audio limit.") }
        case "input_audio_buffer.committed": inputItemID = event["item_id"] as? String
        case "conversation.item.input_audio_transcription.completed", "conversation.item.input_audio_transcription.failed":
            guard transcriptionState == .pending,
                  inputItemID != nil && event["item_id"] as? String == inputItemID else { return }
            if event["type"] as? String == "conversation.item.input_audio_transcription.completed" {
                inputTranscript = (event["transcript"] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
                transcriptionState = inputTranscript.isEmpty ? .failed : .completed
                if inputTranscript.isEmpty { transcriptionError = "No clear speech was recognized. Your recording is saved." }
            } else {
                transcriptionState = .failed
                let error = event["error"] as? [String:Any]
                transcriptionError = error?["code"] as? String == "audio_unintelligible" ? "No clear speech was recognized. Check your microphone level or add text." : "Transcription failed. Your recording is saved; retry transcription or add text."
            }
        case "response.done":
            let response = event["response"] as? [String:Any]
            guard response?["status"] as? String == "completed" else { throw AppFailure("Mochi could not complete that response. Please retry.") }
            done = true
        case "error": throw RealtimeEvents.failure(event["error"] as? [String:Any])
        default: break
        }
    }
}
public struct ConversationRequest {
    public var history: [Message]
    public var text: String
    public var pcm: Data?
    public var spoken: Bool
    public var help: Bool
    public var reference: Bool
    public init(history: [Message], text: String, pcm: Data? = nil, spoken: Bool = false, help: Bool = false, reference: Bool = false) { self.history = history; self.text = text; self.pcm = pcm; self.spoken = spoken; self.help = help; self.reference = reference }
}
public struct RealtimeService {
    public var auth: String
    public var model: String
    public var voice: String
    public var options: OpenAIVoiceOptions
    public init(auth: String = "api", model: String = "gpt-realtime", voice: String = "marin", options: OpenAIVoiceOptions = OpenAIVoiceOptions()) { self.auth = auth; self.model = model; self.voice = voice; self.options = options }
    public func referenceAudio(text: String, root: URL, force: Bool = false) async throws -> URL {
        try options.validate()
        let url = root.appendingPathComponent(ReferenceSpeech.cacheName(text:text,model:model,voice:voice,options:options))
        if !force && FileManager.default.fileExists(atPath:url.path) { return url }
        let result = try await reply(ConversationRequest(history:[],text:text,spoken:true,reference:true))
        guard !result.audio.isEmpty, ReferenceSpeech.matches(text,result.text) else {
            throw AppFailure("The example did not match the sentence exactly. Generate it again; your sentence has not been changed.")
        }
        try Task.checkCancellation()
        try PCM.wav(result.audio).write(to:url,options:.atomic)
        return url
    }
    func token() async throws -> String {
        try await Self.sessionToken(auth:auth,model:model)
    }
    static func sessionToken(auth: String, model: String,
                             apiKey: () throws -> String? = { Credentials.read("OPENAI_API_KEY") },
                             codexToken: () throws -> String = { try Credentials.codexToken() },
                             transport: (URLRequest) async throws -> Data = { try await ServiceHTTP.data($0,provider:"OpenAI") }) async throws -> String {
        if auth == "api" {
            guard let key = try apiKey(), !key.isEmpty else { throw AppFailure("Add your OpenAI API key in Settings, or explicitly select Codex sign-in.") }
            return key
        }
        guard auth == "codex" else { throw AppFailure("Choose a supported connection in Settings.") }
        var request = URLRequest(url:URL(string:"https://api.openai.com/v1/realtime/client_secrets")!)
        request.httpMethod = "POST"; request.setValue("Bearer \(try codexToken())", forHTTPHeaderField:"Authorization"); request.setValue("application/json", forHTTPHeaderField:"Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject:["session":["type":"realtime","model":model]])
        let data = try await transport(request)
        guard let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any], let value = object["value"] as? String, !value.isEmpty else { throw AppFailure("OpenAI did not issue a session credential.") }
        return value
    }
    public func reply(_ input: ConversationRequest,
                      onResponse: (@MainActor (RealtimeAccumulator) throws -> Void)? = nil,
                      onTranscription: (@MainActor (RealtimeAccumulator) -> Void)? = nil) async throws -> RealtimeAccumulator {
        guard RealtimeVoice(rawValue:voice) != nil else { throw AppFailure("Choose a supported built-in voice in Settings.") }
        try options.validate()
        let token = try await token()
        try Task.checkCancellation()
        var components = URLComponents(string:"wss://api.openai.com/v1/realtime")!
        components.queryItems = [URLQueryItem(name:"model",value:model)]
        var request = URLRequest(url:components.url!); request.setValue("Bearer \(token)", forHTTPHeaderField:"Authorization")
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration:config)
        let socket = session.webSocketTask(with:request); socket.maximumMessageSize = 4_000_000
        socket.resume()
        defer { socket.cancel(with:.normalClosure,reason:nil); session.invalidateAndCancel() }
        return try await withTaskCancellationHandler(operation: {
            func send(_ object: [String:Any]) async throws {
                let data = try JSONSerialization.data(withJSONObject:object)
                try await socket.send(.string(String(decoding:data,as:UTF8.self)))
            }
            func receive() async throws -> [String:Any] {
                let message = try await socket.receive()
                let data: Data
                switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: throw AppFailure("Unexpected conversation response.") }
                guard let event = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw AppFailure("Invalid conversation event.") }
                return event
            }
            do {
                var accumulator = try await RealtimeDeadline.run(nanoseconds:90_000_000_000,close: { socket.cancel(with:.goingAway,reason:nil) }) {
                    var accumulator = RealtimeAccumulator()
                    while true { let event = try await receive(); try accumulator.accept(event); if event["type"] as? String == "session.created" { break } }
                    let instructions = input.reference ? "Read the user supplied sentence verbatim in natural spoken English. Output only that sentence as audio. Do not add introductions, explanations, corrections, or answers. Preserve every word exactly." : input.help ? "Help a learner express their intended thought in natural spoken English. Return only valid JSON with exactly two fields: kind (expression or clarification) and text. For expression, text is a concise natural English expression preserving the complete meaning; use more than one sentence when needed. Do not invent details or omit qualifications. If meaning is unclear, use kind clarification and text a brief clarification question. The supplied conversation is context only; never continue it. Do not wrap JSON in Markdown." : VoiceIdentity.instructions
                    try await send(["type":"session.update","session":["type":"realtime","instructions":instructions,"output_modalities":input.spoken ? ["audio"] : ["text"],"audio":["input":["format":["type":"audio/pcm","rate":24000],"turn_detection":NSNull(),"transcription":["model":"gpt-4o-mini-transcribe"]],"output":try options.output(voice:voice)]]])
                    while true { let event = try await receive(); try accumulator.accept(event); if event["type"] as? String == "session.updated" { break } }
                    // Only completed chat messages are restored; practice never enters this history.
                    for message in input.history.suffix(30) {
                        if let text = message.contextText { try await send(RealtimeEvents.message(role:message.role,text:text)) }
                    }
                    if let pcm = input.pcm {
                        for offset in stride(from:0,to:pcm.count,by:48000) { try Task.checkCancellation(); try await send(["type":"input_audio_buffer.append","audio":pcm.subdata(in:offset..<min(offset+48000,pcm.count)).base64EncodedString()]) }
                        try await send(["type":"input_audio_buffer.commit"])
                    } else {
                        try await send(RealtimeEvents.message(role:"user",text:input.text))
                    }
                    try await send(["type":"response.create","response":["output_modalities":input.spoken ? ["audio"] : ["text"],"max_output_tokens":700]])
                    return try await Self.deliverResponse(accumulator,receive:receive,onResponse:onResponse,onTranscription:onTranscription)
                }
                // Reply generation and the subsequent ASR grace period have separate deadlines.
                if input.pcm != nil && accumulator.transcriptionState == .pending {
                    accumulator = try await Self.finishTranscription(accumulator,receive:receive,close: { socket.cancel(with:.normalClosure,reason:nil) })
                    if let onTranscription { await onTranscription(accumulator) }
                }
                return accumulator
            } catch is CancellationError { throw CancellationError() }
            catch { if Task.isCancelled { throw CancellationError() }; throw Self.replyFailure(error) }
        }, onCancel: { socket.cancel(with:.goingAway,reason:nil) })
    }
    static func replyFailure(_ error: Error) -> AppFailure {
        if error is RealtimeTimeout { return AppFailure("Mochi’s reply timed out. Your message is saved; retry the reply.") }
        return (error as? AppFailure) ?? AppFailure("The conversation connection ended. Check your connection and account access, then retry.")
    }
    static func finishTranscription(_ initial: RealtimeAccumulator,
                                    receive: () async throws -> [String:Any],
                                    close: @escaping @Sendable () -> Void,
                                    timeoutNanoseconds: UInt64 = 30_000_000_000) async throws -> RealtimeAccumulator {
        var accumulator = initial
        do {
            try await RealtimeDeadline.run(nanoseconds:timeoutNanoseconds,close:close) {
                while accumulator.transcriptionState == .pending {
                    try Task.checkCancellation()
                    let event = try await receive()
                    try Task.checkCancellation()
                    try accumulator.accept(event)
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch is RealtimeTimeout {
            accumulator.transcriptionState = .timedOut
            accumulator.transcriptionError = "Transcription did not finish. Your recording is saved; retry transcription or add text."
        } catch {
            accumulator.transcriptionState = .failed
            accumulator.transcriptionError = (error as? AppFailure)?.message ?? "The transcription connection ended. Your recording is saved; retry transcription or add text."
        }
        return accumulator
    }
    /// Shared event-delivery seam for live WebSockets and deterministic ordering tests.
    static func deliverResponse(_ initial: RealtimeAccumulator,
                                receive: () async throws -> [String:Any],
                                onResponse: (@MainActor (RealtimeAccumulator) throws -> Void)?,
                                onTranscription: (@MainActor (RealtimeAccumulator) -> Void)?) async throws -> RealtimeAccumulator {
        var accumulator = initial
        while !accumulator.done {
            try Task.checkCancellation()
            let before = accumulator.transcriptionState
            let event = try await receive()
            try Task.checkCancellation()
            try accumulator.accept(event)
            if before != accumulator.transcriptionState, let onTranscription { await onTranscription(accumulator) }
        }
        guard !accumulator.text.isEmpty || !accumulator.audio.isEmpty else { throw AppFailure("Mochi returned an empty response. Please retry.") }
        if let onResponse { try await onResponse(accumulator) }
        return accumulator
    }
}
public struct VoiceRenderer {
    private let key: () throws -> String
    private let transport: (URLRequest) async throws -> Data
    public init(key: @escaping () throws -> String = {
        guard let value = Credentials.read("ELEVENLABS_API_KEY") else { throw AppFailure("Connect ElevenLabs in Settings to use your personal voice.") }; return value
    }, transport: @escaping (URLRequest) async throws -> Data = { try await ServiceHTTP.data($0,provider:"ElevenLabs") }) {
        self.key = key; self.transport = transport
    }
    public func pronunciation(_ identity: RenderIdentity, root: URL) async throws -> URL {
        _ = try identity.pronunciation.payload(speed:identity.speed)
        let url = root.appendingPathComponent("performer-\(identity.sourceKey).mp3")
        if FileManager.default.fileExists(atPath:url.path) { return url }
        let key = try key()
        guard PronunciationTarget(rawValue:identity.performer) != nil else { throw AppFailure("Choose a pronunciation target.") }
        var request = URLRequest(url:URL(string:"https://api.elevenlabs.io/v1/text-to-speech/\(identity.performer)?output_format=mp3_44100_128")!)
        request.httpMethod = "POST"; request.setValue(key,forHTTPHeaderField:"xi-api-key"); request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        let settings = try identity.pronunciation.payload(speed:identity.speed)
        request.httpBody = try JSONSerialization.data(withJSONObject:["text":identity.text,"model_id":identity.ttsModel,"voice_settings":settings])
        let source = try await transport(request)
        try Task.checkCancellation()
        try source.write(to:url,options:.atomic)
        return url
    }
    public func render(_ identity: RenderIdentity, root: URL, force: Bool = false) async throws -> URL {
        _ = try identity.pronunciation.payload(speed:identity.speed); try identity.conversion.validate()
        let url = root.appendingPathComponent("reference-\(identity.key).mp3")
        if !force && FileManager.default.fileExists(atPath:url.path) { return url }
        let key = try key()
        guard !identity.clone.isEmpty else { throw AppFailure("Set your clone voice ID in Settings.") }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"_-"))
        guard identity.clone.unicodeScalars.allSatisfy(allowed.contains), identity.performer.unicodeScalars.allSatisfy(allowed.contains) else { throw AppFailure("Voice IDs contain invalid characters.") }
        let sourceURL = try await pronunciation(identity,root:root)
        let source = try Data(contentsOf:sourceURL)
        var request = URLRequest(url:URL(string:"https://api.elevenlabs.io")!)
        request.httpMethod = "POST"; request.setValue(key,forHTTPHeaderField:"xi-api-key")
        try Task.checkCancellation()
        let boundary = "Mochi-\(UUID().uuidString)"
        var body = Data()
        func part(_ text: String) { body.append(contentsOf:text.utf8) }
        part("--\(boundary)\r\nContent-Disposition: form-data; name=\"model_id\"\r\n\r\n\(identity.stsModel)\r\n")
        let settings = String(decoding:try JSONSerialization.data(withJSONObject:identity.conversion.payload(),options:.sortedKeys),as:UTF8.self)
        part("--\(boundary)\r\nContent-Disposition: form-data; name=\"voice_settings\"\r\n\r\n\(settings)\r\n")
        part("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"performer.mp3\"\r\nContent-Type: audio/mpeg\r\n\r\n"); body.append(source); part("\r\n--\(boundary)--\r\n")
        request.url = URL(string:"https://api.elevenlabs.io/v1/speech-to-speech/\(identity.clone)?output_format=mp3_44100_128")!
        request.setValue("multipart/form-data; boundary=\(boundary)",forHTTPHeaderField:"Content-Type"); request.httpBody = body
        let audio = try await transport(request)
        try Task.checkCancellation()
        try audio.write(to:url,options:.atomic)
        return url
    }
}
