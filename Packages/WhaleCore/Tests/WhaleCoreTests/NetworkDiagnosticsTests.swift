import XCTest
@testable import WhaleCore

final class NetworkDiagnosticsTests: XCTestCase {
    func testLatencySummaryAndHonestQuickSpeech() throws {
        XCTAssertEqual(try NetworkLatencyReading(output: "round-trip min/avg/max/stddev = 1.200/2.500/5.000/0.400 ms").averageMilliseconds, 2.5)
        XCTAssertEqual(try NetworkLatencyReading(output: "round-trip min/avg/max/std-dev = 0.1/0.2/0.3/0.1 ms").averageMilliseconds, 0.2)
        for output in ["3 packets transmitted, 0 packets received, 100% packet loss", "min/avg/max = 1/nan/2 ms", "min/avg/max = 1/-2/3 ms"] {
            XCTAssertThrowsError(try NetworkLatencyReading(output: output))
        }
        var trace = RouteTrace(); trace.ingest("1 * * *")
        var report = NetworkQuickReport(host: "example.test"); report.trace = trace
        XCTAssertTrue(report.speech.contains("终点未确认")); XCTAssertTrue(report.speech.contains("未测得"))
        XCTAssertFalse(report.speech.contains("到达目标共"))
        report.downloadRequested = false
        XCTAssertFalse(report.speech.contains("下载速度"))
        report.downloadMbps = 12.5; report.smallDownload = true
        XCTAssertTrue(report.speech.contains("12.50 Mbps")); XCTAssertTrue(report.speech.contains("仅供参考"))
    }
    func testTargetsSeparateTraceHostFromDownloadURLAndRejectInjection() throws {
        let target = try NetworkTestTarget(" https://github.com/a/file.zip?part=1#anchor ")
        XCTAssertEqual(target.host, "github.com")
        XCTAssertEqual(target.downloadURL.absoluteString, "https://github.com/a/file.zip?part=1")
        XCTAssertEqual(try NetworkTestTarget("2001:db8::1").host, "2001:db8::1")
        XCTAssertEqual(try NetworkTestTarget("https://[2001:db8::1]:443/x").host, "2001:db8::1")
        for input in ["", "-m", "--help", "x;touch", "x\ny", "$(id)", "file:///etc/passwd", "ftp://host/a", "https://user:pass@host/", "999.999.999.999", "http://example.com:0", "https://a..b", "https://a\\b", ":::"] {
            XCTAssertThrowsError(try NetworkTestTarget(input), input)
        }
    }
    func testTraceHandlesMultipathTimeoutsAnnotationsAndArrival() {
        var trace = RouteTrace()
        trace.ingest("traceroute to example.test (203.0.113.8), 30 hops max, 40 byte packets")
        trace.ingest(" 1  192.0.2.1  1.100 ms  192.0.2.2  2.200 ms  *")
        trace.ingest(" 2  * * *")
        XCTAssertEqual(trace.hops.count, 2)
        XCTAssertEqual(trace.hops[0].addresses, ["192.0.2.1", "192.0.2.2"])
        XCTAssertNil(trace.reachedHop)
        trace.ingest(" 3  203.0.113.8  8.123 ms !H * *")
        XCTAssertNil(trace.reachedHop)
        trace.ingest(" 3  203.0.113.8  8.123 ms 9.000 ms 10.000 ms")
        XCTAssertEqual(trace.reachedHop, 3)
        XCTAssertEqual(trace.hops.count, 3)
        XCTAssertFalse(trace.ingest(" 31 malformed 0.00 ms"))
    }
    func testMacOSMultilineMultipathPreservesAllThreeProbes() {
        var trace = RouteTrace()
        trace.ingest(" 4  192.0.2.1  7.873 ms 46.991 ms")
        trace.ingest("    192.0.2.2  6.782 ms")
        XCTAssertEqual(trace.hops.count, 1)
        XCTAssertEqual(trace.hops[0].probes.map(\.milliseconds), [7.873, 46.991, 6.782])
        XCTAssertEqual(trace.hops[0].addresses, ["192.0.2.1", "192.0.2.2"])
        XCTAssertFalse(trace.ingest("    192.0.2.3 9.000 ms"), "No extra fabricated fourth probe")
    }
    func testIPv6AndExhaustedRouteNeverInventHopCount() {
        var trace = RouteTrace()
        trace.ingest("traceroute6 to example.test (2001:db8::8) from 2001:db8::1, 30 hops max")
        trace.ingest(" 1  2001:db8::1  0.200 ms 0.100 ms *")
        trace.ingest(" 30  * * *")
        XCTAssertEqual(trace.destinationIP, "2001:db8::8")
        XCTAssertNil(trace.reachedHop)
        XCTAssertTrue(trace.summary.contains("尚未确认"))
    }
    func testCapacityUsesBitsAndRejectsZeroBooleanOrServiceErrors() throws {
        let result = try NetworkCapacityReading(json: Data(#"{"dl_throughput":80000000,"ul_throughput":20000000,"base_rtt":15.5}"#.utf8))
        XCTAssertEqual(result.downloadMbps, 80)
        XCTAssertEqual(result.uploadMbps, 20)
        for json in [#"{"dl_throughput":0}"#, #"{"dl_throughput":true}"#, #"{"dl_throughput":-1}"#, #"{"error_code":60,"dl_throughput":123}"#, "{}", "not json"] {
            XCTAssertThrowsError(try NetworkCapacityReading(json: Data(json.utf8)))
        }
    }
}
