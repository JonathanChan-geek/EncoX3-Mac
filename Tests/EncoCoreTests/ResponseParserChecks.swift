import Foundation
import EncoCore

func responseParserChecks(_ c: Checker) {
    c.group("ResponseParser")

    func response(_ cmd: UInt16, _ payload: [UInt8]) -> Frame {
        Frame(cmd: cmd, sequence: 0xF0, payload: payload, raw: (try? FrameCodec.encode(cmd: cmd, payload: payload)) ?? [])
    }

    var state = DeviceState()
    ResponseParser.apply(response(0x8103, [0x00, 0x10, 0x74, 0x06]), to: &state)
    c.expectEqual(state.productID, "067410", "product id is little endian (10 74 06 -> 067410)")
    c.expect(state.statusFailures.isEmpty, "a successful product id records no failure")

    state = DeviceState()
    ResponseParser.apply(response(0x8103, [0x03, 0x10, 0x74, 0x06]), to: &state)
    c.expect(state.productID == nil, "a failed status does not become a product id")
    c.expectEqual(state.statusFailures[0x8103], 0x03, "the failed status is recorded")
    c.expectEqual(state.rawResponses[0x8103], [0x03, 0x10, 0x74, 0x06], "the failed payload is still kept raw")
    c.expect(state.productIDUpdatedAt == nil, "a failed response does not refresh freshness")

    let failureTime = Date(timeIntervalSince1970: 100)
    let successTime = Date(timeIntervalSince1970: 200)
    ResponseParser.apply(response(0x8103, [0x00, 0x10, 0x74, 0x06]), to: &state, at: successTime)
    c.expectEqual(state.productID, "067410", "a later success sets the value")
    c.expectEqual(state.productIDUpdatedAt, successTime, "a later success refreshes freshness")
    c.expect(state.statusFailures[0x8103] == nil, "a later success clears the recorded failure")
    _ = failureTime

    state = DeviceState()
    ResponseParser.apply(response(0x8106, [0x02, 0x03, 0x01, 0x64, 0x02, 0x63, 0x03, 0x50]), to: &state)
    c.expect(state.battery.isEmpty, "a failed battery status produces no readings")
    c.expectEqual(state.statusFailures[0x8106], 0x02, "the failed battery status is recorded")
    c.expect(state.batteryUpdatedAt == nil, "a failed battery response does not refresh battery freshness")

    state = DeviceState()
    ResponseParser.apply(response(0x8106, [0x00, 0x03, 0x01, 0xE4, 0x02, 0x63, 0x03, 0xD0]), to: &state)
    c.expectEqual(state.battery[.left], BatteryReading(level: 100, charging: true, reportedLevel: 100), "left bud reading")
    c.expectEqual(state.battery[.right], BatteryReading(level: 99, charging: false, reportedLevel: 99), "right bud reading")
    c.expectEqual(state.battery[.chargingCase], BatteryReading(level: 80, charging: true, reportedLevel: 80), "case reading")

    state = DeviceState()
    ResponseParser.apply(response(0x8106, [0x00, 0x03, 0x01, 0x00, 0x02, 0x00, 0x03, 0x00]), to: &state)
    c.expect(state.battery.values.allSatisfy { $0.level == nil }, "reported 0 is unknown, not 0%")
    c.expectEqual(state.battery[.left]?.reportedLevel, 0, "the reported raw level is preserved")
    c.expectEqual(state.batteryUnknownSlots.count, 3, "all three slots count as unknown")

    state = DeviceState()
    ResponseParser.apply(response(0x8106, [0x00, 0x03, 0x01, 0x65, 0x02, 0x00, 0x03, 0x07]), to: &state)
    c.expect(state.battery[.left]?.level == nil, "101% is impossible and shown as unknown")
    c.expectEqual(state.battery[.left]?.reportedLevel, 101, "the impossible raw level is preserved")
    c.expectEqual(state.battery[.chargingCase]?.level, 7, "a valid slot in the same frame still lands")

    state = DeviceState()
    ResponseParser.apply(response(0x0204, [0x01, 0x03, 0x01, 0x64, 0x02, 0xE3, 0x03, 0x32]), to: &state)
    c.expectEqual(state.battery[.left], BatteryReading(level: 100, charging: false, reportedLevel: 100), "notification slot L")
    c.expectEqual(state.battery[.right], BatteryReading(level: 99, charging: true, reportedLevel: 99), "notification slot R charges on the high bit")
    c.expectEqual(state.battery[.chargingCase], BatteryReading(level: 50, charging: false, reportedLevel: 50), "notification slot C")
    c.expect(state.batteryUpdatedAt != nil, "a battery notification refreshes battery freshness")

    state = DeviceState()
    ResponseParser.apply(response(0x0204, [0x01, 0x03, 0x01, 0x64, 0x02, 0xE3]), to: &state)
    c.expect(state.battery.isEmpty, "a truncated battery notification is rejected as a whole")
    c.expectEqual(state.unparsedPayloads[0x0204], [0x01, 0x03, 0x01, 0x64, 0x02, 0xE3], "the truncated payload is kept raw")
    c.expect(state.batteryUpdatedAt == nil, "a truncated notification does not refresh battery freshness")

    state = DeviceState()
    ResponseParser.apply(response(0x0204, [0x01, 0x02, 0x01, 0x64, 0x02, 0x63, 0x03, 0x32]), to: &state)
    c.expectEqual(state.battery[.left]?.level, 100, "a full notification list is applied")
    c.expectEqual(state.battery[.right]?.level, 99, "a full notification list applies both buds")

    state = DeviceState()
    let ancTime = Date(timeIntervalSince1970: 300)
    ResponseParser.apply(response(0x810C, [0x00, 0x01, 0x01, 0x02]), to: &state, at: ancTime)
    c.expectEqual(state.noiseReductionRawValue, 0x02, "ANC bitmap is kept raw")
    c.expectEqual(state.noiseReductionSource, "0x810C", "ANC source command is recorded")
    c.expectEqual(state.noiseReductionUpdatedAt, ancTime, "ANC freshness advances with an ANC reply")
    c.expectEqual(state.rawResponses[0x810C], [0x00, 0x01, 0x01, 0x02], "ANC payload is kept raw")

    state = DeviceState()
    ResponseParser.apply(response(0x0204, [0x03, 0x01, 0x01, 0x03]), to: &state)
    c.expectEqual(state.noiseReductionRawValue, 0x03, "ANC notification bitmap is kept raw")
    c.expectEqual(state.noiseReductionSource, "0x0204", "ANC notification source is recorded")

    state = DeviceState()
    ResponseParser.apply(response(0x810C, [0x05, 0x01, 0x01, 0x02]), to: &state)
    c.expect(state.noiseReductionRawValue == nil, "a failed ANC status is not a mode value")
    c.expectEqual(state.statusFailures[0x810C], 0x05, "the failed ANC status is recorded")

    state = DeviceState()
    ResponseParser.apply(response(0x810C, [0x00, 0x09, 0x09]), to: &state)
    c.expect(state.noiseReductionRawValue == nil, "an unrecognised ANC layout is not interpreted")
    c.expectEqual(state.unparsedPayloads[0x810C], [0x00, 0x09, 0x09], "the unrecognised payload is kept raw")

    state = DeviceState()
    ResponseParser.apply(response(0x8105, [0x00, 0x07] + Array("1.2.3.4".utf8)), to: &state)
    c.expectEqual(state.firmwareVersion, "1.2.3.4", "firmware version decodes as UTF-8")

    state = DeviceState()
    ResponseParser.apply(response(0x8100, [0x00, 0x01, 0x80]), to: &state)
    c.expectEqual(state.capabilityBitString, "1000000000000001", "capability bits are low bit first")

    state = DeviceState()
    ResponseParser.apply(response(0x812A, [0x00, 0x02]), to: &state)
    c.expectEqual(state.rawResponses[0x812A], [0x00, 0x02], "raw-only commands are stored verbatim")
    c.expect(state.unparsedPayloads.isEmpty, "raw-only commands are not flagged as unrecognised")

    // Freshness isolation: an EQ reply and a failed reply must not refresh battery or ANC.
    state = DeviceState()
    let batteryTime = Date(timeIntervalSince1970: 400)
    ResponseParser.apply(response(0x8106, [0x00, 0x03, 0x01, 0x64, 0x02, 0x63, 0x03, 0x50]), to: &state, at: batteryTime)
    ResponseParser.apply(response(0x810F, [0x00, 0x01]), to: &state, at: Date(timeIntervalSince1970: 500))
    ResponseParser.apply(response(0x8103, [0x09, 0x10, 0x74, 0x06]), to: &state, at: Date(timeIntervalSince1970: 600))
    c.expectEqual(state.batteryUpdatedAt, batteryTime, "EQ and failed replies do not refresh battery freshness")
    c.expect(state.noiseReductionUpdatedAt == nil, "EQ and failed replies never create ANC freshness")
    c.expectEqual(state.rawResponses.count, 3, "every raw payload is still kept")
    c.expectEqual(state.responseCount, 3, "every response is counted")
}
