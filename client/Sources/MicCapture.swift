import Foundation
import AVFoundation

/// 持久化麦克风采集会话（热麦续命）。
///
/// 问题：原本每次录音都 new AVCaptureSession + startRunning，硬件冷启动 ~150ms，
/// 这段时间话音还没进来 → 丢前若干字（蓝牙更严重）。
/// 方案：把 AVCaptureSession 的生命周期从「单次录音」抽出来常驻管理——
/// 录音结束不立刻 stopRunning，而是续命 keepAliveSec 秒；期间再次录音直接复用热会话（零冷启动）。
/// 续命超时无人用 → stopRunning 释放麦克风（橙点灭、设备还给会议 / 视频，不常驻热麦）。
///
/// 与会议冲突的窗口因此被压到「停手后 keepAliveSec 秒内」，平时不持麦。
@MainActor
final class MicCapture {
    static let shared = MicCapture()
    private init() {}

    /// 续命时长：录音结束后麦克风保持热多久（秒）。停手超过此值才真正释放。
    var keepAliveSec: Double = 6.0

    /// 采集 delegate 回调队列（供 VoiceSession setSampleBufferDelegate 用）。
    let captureQueue = DispatchQueue(label: "com.lengmo.mk.audio-capture")

    private var session: AVCaptureSession?
    private var deviceInput: AVCaptureDeviceInput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var currentDeviceID: String?
    private var idleStopTask: Task<Void, Never>?

    var isWarm: Bool { session?.isRunning ?? false }

    /// 录音开始时调：返回正在运行的 audioOutput（必要时冷启动 / 设备变更则重建），
    /// 调用方拿到后 setSampleBufferDelegate 即开始收样本。
    /// 返回 coldStarted：true = 这次吃了硬件热身；false = 复用热会话（零冷启动）。
    func acquire() throws -> (output: AVCaptureAudioDataOutput, coldStarted: Bool) {
        idleStopTask?.cancel()
        idleStopTask = nil

        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw VoiceError.noAudioDevice
        }

        // 复用条件：会话在跑 + 设备没换（拔插耳机会换 uniqueID → 落到重建分支）
        if let session, session.isRunning, let audioOutput, currentDeviceID == device.uniqueID {
            Logger.log("Mic", "复用热会话（零冷启动）device=\(device.localizedName)")
            return (audioOutput, false)
        }

        teardownNow()

        let t0 = CFAbsoluteTimeGetCurrent()
        let session = AVCaptureSession()
        let deviceInput = try AVCaptureDeviceInput(device: device)
        session.addInput(deviceInput)
        let audioOutput = AVCaptureAudioDataOutput()
        session.addOutput(audioOutput)
        session.startRunning()   // 冷启动：~150ms 硬件 / 路由热身（蓝牙更久）

        self.session = session
        self.deviceInput = deviceInput
        self.audioOutput = audioOutput
        self.currentDeviceID = device.uniqueID

        Logger.log("Mic", "冷启动 \(Int((CFAbsoluteTimeGetCurrent() - t0) * 1000))ms device=\(device.localizedName)")
        return (audioOutput, true)
    }

    /// 录音结束时调：摘掉 delegate + 启动续命计时器；keepAliveSec 内没人 acquire 就真正释放。
    func release() {
        audioOutput?.setSampleBufferDelegate(nil, queue: captureQueue)
        idleStopTask?.cancel()
        let keep = keepAliveSec
        idleStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(keep))
            if Task.isCancelled { return }
            self?.teardownNow()
            Logger.log("Mic", "续命超时 \(keep)s，麦克风已释放（橙点灭，设备已交还）")
        }
    }

    private func teardownNow() {
        session?.stopRunning()
        audioOutput?.setSampleBufferDelegate(nil, queue: captureQueue)
        session = nil
        deviceInput = nil
        audioOutput = nil
        currentDeviceID = nil
    }
}
