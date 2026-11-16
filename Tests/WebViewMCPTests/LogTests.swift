import XCTest
@testable import WebViewMCP

final class LogTests: XCTestCase {
  func testEntryLogDropsOldestAndKeepsSequence() {
    var log = EntryLog(limit: 2)
    log.append(["message": "a"])
    log.append(["message": "b"])
    log.append(["message": "c"])
    XCTAssertEqual(log.entries.map { $0["message"] as? String }, ["b", "c"])
    XCTAssertEqual(log.entries.map { $0["seq"] as? Int }, [2, 3])
    XCTAssertEqual(log.dropped, 1)
  }

  func testNetworkLogMergesPhases() {
    var log = NetworkLog(limit: 10)
    log.merge(["type": "network", "phase": "start", "id": "f-1", "url": "https://example.com", "method": "GET", "time": 1])
    XCTAssertEqual(log.entry(id: "f-1")?["state"] as? String, "pending")
    log.merge(["type": "network", "phase": "end", "id": "f-1", "status": 200, "time": 5])
    log.merge(["type": "network", "phase": "body", "id": "f-1", "responseBody": "{}"])
    let entry = log.entry(id: "f-1")
    XCTAssertEqual(entry?["state"] as? String, "finished")
    XCTAssertEqual(entry?["status"] as? Int, 200)
    XCTAssertEqual(entry?["url"] as? String, "https://example.com")
    XCTAssertEqual(entry?["responseBody"] as? String, "{}")
    XCTAssertEqual(entry?["seq"] as? Int, 1)
    XCTAssertNil(entry?["phase"])
  }

  func testNetworkLogMarksErrorsFailed() {
    var log = NetworkLog(limit: 10)
    log.merge(["phase": "start", "id": "x"])
    log.merge(["phase": "end", "id": "x", "error": "Load failed"])
    XCTAssertEqual(log.entry(id: "x")?["state"] as? String, "failed")
  }

  func testNetworkLogEvictsOldest() {
    var log = NetworkLog(limit: 2)
    for id in ["a", "b", "c"] {
      log.merge(["phase": "start", "id": id])
    }
    XCTAssertNil(log.entry(id: "a"))
    XCTAssertEqual(log.all.count, 2)
    XCTAssertEqual(log.dropped, 1)
  }
}
