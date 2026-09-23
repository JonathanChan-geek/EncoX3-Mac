import Foundation
import EncoCore
import EncoBluetooth

@MainActor
func asyncTransactionChecks(_ c: Checker) async {
    c.group("异步事务：相关性、响应性、取消及精确回读")
    let sdp = SDPQueryWaiter()
    var discoveryCallbackObserved = false
    sdp.onComplete = { status in
        discoveryCallbackObserved = sdp.finished && sdp.status == status
    }
    sdp.sdpQueryComplete(nil, status: 0)
    c.expect(discoveryCallbackObserved, "新服务发现完成后唤醒异步打开路径")
    var controller: TransactionController!
    var sequence: UInt8 = 0
    var sends = 0
    var reply: [UInt8]? = [0, 4]
    var rejectACK = false
    controller = TransactionController(defaultTimeout: 0.08) { cmd, _ in
        sends += 1
        sequence &+= 1
        let seq = sequence
        let payload: [UInt8]? = cmd == EncoCommand.setEqualizer.rawValue ? [rejectACK ? 1 : 0] : reply
        if let payload {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                let wrong = Frame(cmd: ResponseCorrelation.responseCommand(for: cmd), sequence: seq &+ 1, payload: payload, raw: [])
                c.expect(!controller.accept(wrong), "忽略不匹配序号")
                let frame = Frame(cmd: ResponseCorrelation.responseCommand(for: cmd), sequence: seq, payload: payload, raw: [])
                c.expect(controller.accept(frame), "接收当前事务的匹配序号")
            }
        }
        return seq
    }
    let first = await controller.queryAsync(cmd: EncoCommand.queryEqualizer.rawValue)
    c.expectEqual(first.outcome, .ok, "异步查询收到成功响应")
    reply = nil
    var heartbeat = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { heartbeat = true }
    let timed = await controller.queryAsync(cmd: EncoCommand.queryEqualizer.rawValue)
    c.expectEqual(timed.outcome, .timedOut, "丢包有界超时")
    c.expect(heartbeat, "等待响应期间主队列仍可执行 UI 工作")
    let pending = Task { @MainActor in await controller.queryAsync(cmd: EncoCommand.queryEqualizer.rawValue) }
    await Task.yield()
    let busy = await controller.queryAsync(cmd: EncoCommand.queryEqualizer.rawValue)
    if case .notSent = busy.outcome { c.expect(true, "禁止并发事务") }
    else { c.expect(false, "禁止并发事务") }
    controller.cancel()
    let cancelled = await pending.value
    if case .notSent = cancelled.outcome { c.expect(true, "取消立即结束挂起查询") }
    else { c.expect(false, "取消立即结束挂起查询") }
    c.expect(!controller.accept(Frame(cmd: 0x810F, sequence: sequence, payload: [0, 4], raw: [])), "丢弃取消后的迟到响应")
    let countBefore = sends
    _ = await controller.queryAsync(cmd: EncoCommand.queryEqualizer.rawValue)
    c.expectEqual(sends, countBefore, "关闭会话不再发送请求")

    controller = TransactionController(defaultTimeout: 0.06) { cmd, _ in
        sends += 1; sequence &+= 1
        let seq = sequence
        let payload: [UInt8]? = cmd == EncoCommand.setEqualizer.rawValue ? [rejectACK ? 1 : 0] : reply
        if let payload {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) {
                _ = controller.accept(Frame(cmd: ResponseCorrelation.responseCommand(for: cmd), sequence: seq, payload: payload, raw: []))
            }
        }
        return seq
    }
    reply = [0, 4]
    let exact = await controller.setEqualizerAsync(id: 4, readbackBudget: 0, settle: 0)
    c.expectEqual(exact.outcome, .verified, "ACK 加精确回读才能成功")
    reply = [0, 3]
    let mismatch = await controller.setEqualizerAsync(id: 4, readbackBudget: 0, settle: 0)
    c.expectEqual(mismatch.outcome, .readbackMismatch, "不同回读不报成功")
    reply = nil
    let missing = await controller.setEqualizerAsync(id: 4, readbackBudget: 0, settle: 0)
    c.expectEqual(missing.outcome, .readbackMismatch, "仅 ACK 不报成功")
    rejectACK = true
    let before = sends
    let rejected = await controller.setEqualizerAsync(id: 4, readbackBudget: 0, settle: 0)
    c.expectEqual(rejected.outcome, .rejected(status: 1), "设备拒绝保持拒绝结果")
    c.expectEqual(sends, before + 1, "拒绝后不继续发回读")
}
