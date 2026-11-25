import Foundation

public struct SpinosisAssignment {
  public var variant: String
  public var payload: [String: Any]

  public init(variant: String, payload: [String: Any] = [:]) {
    self.variant = variant
    self.payload = payload
  }

  public var headline: String? {
    stringValue("headline")
  }

  public var subtitle: String? {
    stringValue("subtitle")
  }

  private func stringValue(_ key: String) -> String? {
    guard let value = payload[key] as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

public enum Spinosis {
  public static func initialize(
    apiKey: String,
    userId: String? = nil,
    apiUrl: String = "https://spinosis.com",
    defaultTimeout: TimeInterval = 1.5
  ) async {
    await client.initialize(
      apiKey: apiKey,
      userId: userId,
      apiUrl: apiUrl,
      defaultTimeout: defaultTimeout
    )
  }

  public static func identify(_ userId: String, properties: [String: Any]? = nil) async {
    await client.identify(userId, properties: properties)
  }

  public static func setUserProperties(_ properties: [String: Any]) async {
    await client.setUserProperties(properties)
  }

  public static func getVariant(
    _ experimentKey: String,
    fallback: String,
    timeout: TimeInterval? = nil
  ) async -> String {
    await client.getAssignment(experimentKey, fallback: fallback, timeout: timeout).variant
  }

  public static func getAssignment(
    _ experimentKey: String,
    fallback: String,
    timeout: TimeInterval? = nil
  ) async -> SpinosisAssignment {
    await client.getAssignment(experimentKey, fallback: fallback, timeout: timeout)
  }

  public static func track(_ eventName: String, properties: [String: Any]? = nil) async {
    await client.track(eventName, properties: properties)
  }

  public static func anonymousId() async -> String? {
    await client.anonymousId
  }
}

actor SpinosisClient {
  static let shared = SpinosisClient()

  private let defaults = UserDefaults.standard
  private let anonKey = "spinosis.anonymousId"
  private let userKey = "spinosis.userId"
  private let propsKey = "spinosis.properties"
  private let assignmentsKey = "spinosis.assignments"

  private var initialized = false
  private var apiKey: String?
  private var apiUrl = "https://spinosis.com"
  private var defaultTimeout: TimeInterval = 1.5
  private(set) var anonymousId: String?
  private var userId: String?
  private var properties: [String: Any] = [:]
  private var assignments: [String: CachedAssignment] = [:]

  private struct CachedAssignment: Codable {
    var variant: String
    var payloadJSON: Data?
    var cachedAt: TimeInterval
  }

  func initialize(
    apiKey: String,
    userId: String?,
    apiUrl: String,
    defaultTimeout: TimeInterval
  ) async {
    guard !initialized else { return }

    self.apiKey = apiKey
    self.apiUrl = apiUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    self.defaultTimeout = defaultTimeout

    if let stored = defaults.string(forKey: anonKey) {
      anonymousId = stored
    } else {
      anonymousId = "anon_\(UUID().uuidString.lowercased())"
      defaults.set(anonymousId, forKey: anonKey)
    }

    self.userId = userId ?? defaults.string(forKey: userKey)
    if let userId {
      defaults.set(userId, forKey: userKey)
    }

    if let data = defaults.data(forKey: propsKey),
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      properties = parsed
    }

    if let data = defaults.data(forKey: assignmentsKey),
       let parsed = try? JSONDecoder().decode([String: CachedAssignment].self, from: data) {
      assignments = parsed
    }

    initialized = true

    try? await post("/api/sdk/identify", body: identityPayload(), timeout: defaultTimeout)
  }

  func identify(_ userId: String, properties: [String: Any]?) async {
    guard initialized else { return }
    self.userId = userId
    defaults.set(userId, forKey: userKey)
    if let properties {
      mergeProperties(properties)
    }
    try? await post("/api/sdk/identify", body: identityPayload(), timeout: defaultTimeout)
  }

  func setUserProperties(_ properties: [String: Any]) async {
    guard initialized else { return }
    mergeProperties(properties)
    try? await post("/api/sdk/identify", body: identityPayload(), timeout: defaultTimeout)
  }

  func getAssignment(_ experimentKey: String, fallback: String, timeout: TimeInterval?) async -> SpinosisAssignment {
    let fallbackAssignment = SpinosisAssignment(variant: fallback)
    guard initialized else { return fallbackAssignment }
    let timeout = timeout ?? defaultTimeout

    do {
      let json = try await post(
        "/api/sdk/assignment",
        body: identityPayload().merging(["experimentKey": experimentKey]) { _, new in new },
        timeout: timeout
      )
      if let variant = json["variant"] as? String, !variant.isEmpty {
        let payload = json["payload"] as? [String: Any] ?? [:]
        cache(experimentKey, variant: variant, payload: payload)
        return SpinosisAssignment(variant: variant, payload: payload)
      }
    } catch {
      if let cached = cachedAssignment(experimentKey) {
        return cached
      }
      return fallbackAssignment
    }

    return cachedAssignment(experimentKey) ?? fallbackAssignment
  }

  func track(_ eventName: String, properties: [String: Any]?) async {
    guard initialized else { return }
    var body = identityPayload()
    body["eventName"] = eventName
    body["properties"] = properties ?? [:]
    try? await post("/api/sdk/events", body: body, timeout: defaultTimeout)
  }

  private func mergeProperties(_ incoming: [String: Any]) {
    properties.merge(incoming) { _, new in new }
    if let data = try? JSONSerialization.data(withJSONObject: properties) {
      defaults.set(data, forKey: propsKey)
    }
  }

  /// Read from the device on every call. Sent as defaults; values set by the app win.
  private func deviceProperties() -> [String: Any] {
    var props: [String: Any] = ["platform": "ios"]
    let region: String?
    if #available(iOS 16, macOS 13, *) {
      region = Locale.current.region?.identifier
    } else {
      region = Locale.current.regionCode
    }
    if let region, region.count == 2 {
      props["country"] = region.uppercased()
    }
    return props
  }

  private func identityPayload() -> [String: Any] {
    let merged = deviceProperties().merging(properties) { _, appValue in appValue }
    var body: [String: Any] = ["properties": merged]
    if let userId { body["userId"] = userId }
    if let anonymousId { body["anonymousId"] = anonymousId }
    return body
  }

  private func cachedAssignment(_ experimentKey: String) -> SpinosisAssignment? {
    guard let cached = assignments[experimentKey] else { return nil }
    if Date().timeIntervalSince1970 - cached.cachedAt > 60 * 60 * 24 {
      return nil
    }
    var payload: [String: Any] = [:]
    if let data = cached.payloadJSON,
       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      payload = parsed
    }
    return SpinosisAssignment(variant: cached.variant, payload: payload)
  }

  private func cache(_ experimentKey: String, variant: String, payload: [String: Any]) {
    var payloadJSON: Data? = nil
    if JSONSerialization.isValidJSONObject(payload) {
      payloadJSON = try? JSONSerialization.data(withJSONObject: payload)
    }
    assignments[experimentKey] = CachedAssignment(
      variant: variant,
      payloadJSON: payloadJSON,
      cachedAt: Date().timeIntervalSince1970
    )
    if let data = try? JSONEncoder().encode(assignments) {
      defaults.set(data, forKey: assignmentsKey)
    }
  }

  @discardableResult
  private func post(_ path: String, body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
    guard let apiKey else { throw URLError(.userAuthenticationRequired) }
    guard let url = URL(string: "\(apiUrl)\(path)") else { throw URLError(.badURL) }

    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    if data.isEmpty { return [:] }
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
  }
}

private let client = SpinosisClient.shared
