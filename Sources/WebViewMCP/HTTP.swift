import Foundation

/// A parsed HTTP/1.1 request. The server only speaks enough HTTP for the MCP bridge and curl.
struct HTTPRequest {
  enum ParseResult {
    case complete(HTTPRequest)
    case incomplete
    case invalid(String)
  }

  static let maxHeaderBytes = 64 * 1024
  static let maxBodyBytes = 8 * 1024 * 1024

  var method: String
  var path: String
  var query: [String: String]
  var headers: [String: String]
  var body: Data

  /// The body decoded as a JSON object, or an empty dictionary.
  var jsonBody: [String: Any] {
    guard !body.isEmpty,
          let object = try? JSONSerialization.jsonObject(with: body),
          let dictionary = object as? [String: Any] else {
      return [:]
    }
    return dictionary
  }

  /// A parameter from the query string, falling back to the JSON body.
  func parameter(_ name: String) -> Any? {
    if let value = query[name] {
      return value
    }
    let value = jsonBody[name]
    return value is NSNull ? nil : value
  }

  func string(_ name: String) -> String? {
    switch parameter(name) {
    case let value as String:
      return value.isEmpty ? nil : value
    case let value as NSNumber:
      return value.stringValue
    default:
      return nil
    }
  }

  func int(_ name: String) -> Int? {
    switch parameter(name) {
    case let value as String:
      return Int(value)
    case let value as NSNumber:
      return value.intValue
    default:
      return nil
    }
  }

  func bool(_ name: String) -> Bool {
    switch parameter(name) {
    case let value as String:
      return ["1", "true", "yes"].contains(value.lowercased())
    case let value as NSNumber:
      return value.boolValue
    default:
      return false
    }
  }

  static func parse(_ data: Data) -> ParseResult {
    let separator = Data("\r\n\r\n".utf8)
    guard let headerEnd = data.range(of: separator) else {
      return data.count > maxHeaderBytes ? .invalid("Request headers too large") : .incomplete
    }
    guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
      return .invalid("Request headers are not UTF-8")
    }

    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
    guard requestLine.count >= 2 else {
      return .invalid("Malformed request line")
    }

    var headers: [String: String] = [:]
    for line in lines {
      guard let colon = line.firstIndex(of: ":") else {
        continue
      }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[name] = value
    }

    let length = Int(headers["content-length"] ?? "0") ?? -1
    guard length >= 0 else {
      return .invalid("Invalid Content-Length")
    }
    guard length <= maxBodyBytes else {
      return .invalid("Request body too large")
    }

    let bodyStart = headerEnd.upperBound
    guard data.endIndex - bodyStart >= length else {
      return .incomplete
    }
    let body = Data(data[bodyStart..<(bodyStart + length)])

    let target = String(requestLine[1])
    let components = URLComponents(string: target)
    var query: [String: String] = [:]
    for item in components?.queryItems ?? [] {
      query[item.name] = item.value ?? ""
    }

    return .complete(HTTPRequest(
      method: requestLine[0].uppercased(),
      path: components?.path ?? target,
      query: query,
      headers: headers,
      body: body
    ))
  }
}

struct HTTPResponse {
  var status: Int
  var contentType: String
  var body: Data

  static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
    let data = (try? JSONSerialization.data(
      withJSONObject: JSON.sanitize(object),
      options: [.fragmentsAllowed, .withoutEscapingSlashes]
    )) ?? Data("{}".utf8)
    return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
  }

  static func error(_ status: Int, _ message: String) -> HTTPResponse {
    json(["ok": false, "error": message], status: status)
  }

  func serialized() -> Data {
    var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
    head += "Content-Type: \(contentType)\r\n"
    head += "Content-Length: \(body.count)\r\n"
    head += "Cache-Control: no-store\r\n"
    head += "Connection: close\r\n\r\n"
    return Data(head.utf8) + body
  }

  private static func reason(for status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 403: return "Forbidden"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 408: return "Request Timeout"
    case 409: return "Conflict"
    case 413: return "Payload Too Large"
    case 500: return "Internal Server Error"
    default: return "Status \(status)"
    }
  }
}

enum JSON {
  /// Makes a value safe for `JSONSerialization`: dates become ISO-8601 strings, URLs become
  /// strings, and anything else unknown is described.
  static func sanitize(_ value: Any) -> Any {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
      guard let wrapped = mirror.children.first else {
        return NSNull()
      }
      return sanitize(wrapped.value)
    }

    switch value {
    case let dictionary as [String: Any]:
      return dictionary.mapValues(sanitize)
    case let array as [Any]:
      return array.map(sanitize)
    case is String, is NSNumber, is NSNull:
      return value
    case let date as Date:
      return ISO8601DateFormatter().string(from: date)
    case let url as URL:
      return url.absoluteString
    default:
      return String(describing: value)
    }
  }
}
