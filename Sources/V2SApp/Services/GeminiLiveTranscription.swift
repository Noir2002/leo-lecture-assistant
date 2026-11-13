import Foundation

actor GeminiLiveConnection {
    typealias EventHandler = @Sendable (TranscriptEvent) async -> Void

    private let sequence: Int
    private let client: GeminiAPIClient
    private let course: CourseDefinition
    private let glossary: [String]
    private let eventHandler: EventHandler
    private let session: URLSession
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    init(
        sequence: Int,
        client: GeminiAPIClient,
        course: CourseDefinition,
        glossary: [String],
        session: URLSession = .shared,
        eventHandler: @escaping EventHandler
    ) {
        self.sequence = sequence
        self.client = client
        self.course = course
        self.glossary = Array(glossary.prefix(100))
        self.session = session
        self.eventHandler = eventHandler
    }

    func connect() async throws {
        let token = try await client.ephemeralToken(course: course, glossary: glossary)
        var components = URLComponents(url: ModelConfig.liveEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "access_token", value: token)]
        guard let url = components.url else { throw EngineFailure.unavailable("Invalid Live API URL") }

        let socket = session.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        try await sendJSON(["setup": client.liveConfig(course: course, glossary: glossary)])
        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func send(pcm16: Data) async throws {
        guard pcm16.isEmpty == false, socket != nil else { return }
        let message: [String: Any] = [
            "realtimeInput": [
                "audio": [
                    "data": pcm16.base64EncodedString(),
                    "mimeType": ModelConfig.audioMIMEType,
                ],
            ],
        ]
        try await sendJSON(message)
    }

    func finish() async {
        if socket != nil {
            try? await sendJSON(["realtimeInput": ["audioStreamEnd": true]])
        }
        try? await Task.sleep(nanoseconds: UInt64(ModelConfig.liveFinalDrainTimeout * 1_000_000_000))
        let receiver = receiveTask
        close()
        await receiver?.value
    }

    func close() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    private func sendJSON(_ value: [String: Any]) async throws {
        guard let socket else { throw EngineFailure.network }
        let data = try JSONSerialization.data(withJSONObject: value)
        guard let text = String(data: data, encoding: .utf8) else { throw EngineFailure.malformedResponse }
        do {
            try await socket.send(.string(text))
        } catch {
            throw EngineFailure.network
        }
    }

    private func receiveLoop() async {
        while Task.isCancelled == false, let socket {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: continue
                }
                await handle(data)
            } catch {
                if Task.isCancelled == false {
                    await eventHandler(.failure(.network))
                }
                return
            }
        }
    }

    private func handle(_ data: Data) async {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            await eventHandler(.failure(.malformedResponse))
            return
        }
        if root["setupComplete"] != nil {
            await eventHandler(.status("Gemini Live session \(sequence) connected"))
        }
        guard let server = root["serverContent"] as? [String: Any] else { return }
        let now = Date()
        if let interim = server["interimInputTranscription"] as? [String: Any],
           let text = interim["text"] as? String, text.isEmpty == false {
            await eventHandler(.interim(text: text, capturedAt: now))
        }
        if let final = server["inputTranscription"] as? [String: Any],
           let text = final["text"] as? String, text.isEmpty == false {
            await eventHandler(.final(text: text, capturedAt: now))
        }
    }
}

actor GeminiSessionManager: TranscriptionEngine {
    nonisolated let events: AsyncStream<TranscriptEvent>
    private let continuation: AsyncStream<TranscriptEvent>.Continuation
    private let client: GeminiAPIClient
    private let rotationInterval: TimeInterval
    private var course: CourseDefinition?
    private var glossary: [String] = []
    private var current: GeminiLiveConnection?
    private var next: GeminiLiveConnection?
    private var currentStartedAt = Date.distantPast
    private var rotation = GeminiRotationStateMachine()
    private var rotationDrain: Task<Void, Never>?
    private var isPreconnecting = false
    private var isFinished = false
    private var handoverBuffer: [TranscriptEvent] = []

    init(client: GeminiAPIClient, rotationInterval: TimeInterval = 510) {
        self.client = client
        self.rotationInterval = min(max(rotationInterval, 60), 570)
        var captured: AsyncStream<TranscriptEvent>.Continuation!
        self.events = AsyncStream { captured = $0 }
        self.continuation = captured
    }

    func start(course: CourseDefinition, glossary: [String]) async throws {
        self.course = course
        self.glossary = Array(glossary.prefix(100))
        self.isFinished = false
        let sequence = rotation.connected()
        let connection = makeConnection(sequence: sequence, course: course)
        try await connection.connect()
        current = connection
        currentStartedAt = Date()
    }

    func ingest(_ frame: AudioFrame) async throws {
        guard isFinished == false, let current else { return }
        let elapsed = Date().timeIntervalSince(currentStartedAt)
        if elapsed >= rotationInterval - 15, next == nil, isPreconnecting == false {
            isPreconnecting = true
            Task { await self.preconnectWithBackoff() }
        }
        if elapsed >= rotationInterval, let next {
            continuation.yield(.status("Gemini Live rotating"))
            self.current = next
            self.next = nil
            currentStartedAt = Date()
            _ = rotation.rotate()
            rotationDrain = Task {
                await current.finish()
                self.markDrainComplete()
            }
        }
        let data = try PCM16Converter.convert(frame.buffer)
        do {
            try await (self.current ?? current).send(pcm16: data)
        } catch let failure as EngineFailure {
            continuation.yield(.failure(failure))
            throw failure
        }
    }

    func finish() async {
        isFinished = true
        let current = self.current
        let next = self.next
        self.current = nil
        self.next = nil
        await current?.finish()
        await next?.close()
        await rotationDrain?.value
        continuation.finish()
    }

    private func preconnectWithBackoff() async {
        defer { isPreconnecting = false }
        guard let course, let sequence = rotation.preconnected() else { return }
        let candidate = makeConnection(sequence: sequence, course: course)
        let delays: [UInt64] = [1, 2, 4]
        for (index, delay) in delays.enumerated() {
            do {
                try await candidate.connect()
                guard isFinished == false else {
                    await candidate.close()
                    return
                }
                next = candidate
                return
            } catch let failure as EngineFailure {
                if failure.requiresImmediateFallback {
                    rotation.fail()
                    continuation.yield(.failure(failure))
                    return
                }
                if index == delays.count - 1 {
                    rotation.fail()
                    continuation.yield(.failure(failure))
                    return
                }
            } catch {
                if index == delays.count - 1 {
                    rotation.fail()
                    continuation.yield(.failure(.network))
                    return
                }
            }
            let jitter = UInt64.random(in: 0...250_000_000)
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000 + jitter)
        }
    }

    private func makeConnection(sequence: Int, course: CourseDefinition) -> GeminiLiveConnection {
        GeminiLiveConnection(
            sequence: sequence,
            client: client,
            course: course,
            glossary: glossary
        ) { [weak self] event in
            await self?.receive(event, sequence: sequence)
        }
    }

    private func receive(_ event: TranscriptEvent, sequence: Int) {
        if case .draining(_, let currentSequence) = rotation.state,
           sequence == currentSequence,
           case .final = event {
            handoverBuffer.append(event)
            return
        }
        continuation.yield(event)
    }

    private func markDrainComplete() {
        handoverBuffer
            .sorted { lhs, rhs in
                func date(_ event: TranscriptEvent) -> Date {
                    switch event {
                    case .interim(_, let capturedAt), .final(_, let capturedAt): return capturedAt
                    case .status, .failure: return .distantPast
                    }
                }
                return date(lhs) < date(rhs)
            }
            .forEach { continuation.yield($0) }
        handoverBuffer.removeAll(keepingCapacity: true)
        rotation.drained()
    }
}
