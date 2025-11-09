import UIKit
import Flutter
import AVFoundation
import AVKit
import CoreMedia
import Vision

class NativeCameraView: NSObject, FlutterPlatformView, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, FlutterStreamHandler {
    
    // MARK: - Properties
    private var _view: UIView
    private var methodChannel: FlutterMethodChannel
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?

    private var captureSession: AVCaptureSession?
    // Sử dụng AVSampleBufferDisplayLayer để hỗ trợ PiP
    private var displayLayer: AVSampleBufferDisplayLayer? 
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var pipController: AVPictureInPictureController?
    
    // Vision Request Handler
    private let sequenceHandler = VNSequenceRequestHandler()
    
    // MARK: - Initialization
    
    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        binaryMessenger messenger: FlutterBinaryMessenger?
    ) {
        _view = UIView(frame: frame)
        _view.backgroundColor = .black

        methodChannel = FlutterMethodChannel(name: "com.example/camera_pip_method_\(viewId)",
                                             binaryMessenger: messenger!)
        
        eventChannel = FlutterEventChannel(name: "com.example/face_events_\(viewId)",
                                             binaryMessenger: messenger!)

        super.init()
        
        eventChannel?.setStreamHandler(self)

        methodChannel.setMethodCallHandler({
            [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
            
            if call.method == "startPip" {
                self?.startPip()
                result(nil)
            } else {
                result(FlutterMethodNotImplemented)
            }
        })

        setupAudioSession()
        setupCamera()
        setupPip()
    }
    
    func view() -> UIView {
        return _view
    }
    
    private func setupAudioSession() {
        do {
            // Sử dụng .playAndRecord để cho phép ghi và phát đồng thời
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoChat, options: [.mixWithOthers, .allowBluetooth])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Lỗi cài đặt AVAudioSession: \(error.localizedDescription)")
        }
    }

    private func setupCamera() {
        captureSession = AVCaptureSession()
        guard let captureSession = captureSession else { return }

        if #available(iOS 16.0, *) {
            if captureSession.isMultitaskingCameraAccessSupported {
                captureSession.isMultitaskingCameraAccessEnabled = true
            }
        }
        
        captureSession.sessionPreset = .vga640x480
        
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else { return }
        
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if captureSession.canAddInput(input) { captureSession.addInput(input) }
        } catch {
            print("Lỗi khi tạo input camera: \(error.localizedDescription)")
            return
        }

        videoDataOutput = AVCaptureVideoDataOutput()
        videoDataOutput!.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
        // Định dạng tốt nhất cho Vision
        videoDataOutput!.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] 

        if captureSession.canAddOutput(videoDataOutput!) { captureSession.addOutput(videoDataOutput!) }
        
        // Khởi tạo AVSampleBufferDisplayLayer để hiển thị
        displayLayer = AVSampleBufferDisplayLayer()
        guard let displayLayer = displayLayer else { return }
        
        displayLayer.frame = _view.bounds
        displayLayer.videoGravity = .resizeAspectFill
        _view.layer.addSublayer(displayLayer)

        if let videoConnection = videoDataOutput!.connection(with: .video), videoConnection.isVideoOrientationSupported {
            videoConnection.videoOrientation = .portrait
        }

        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.startRunning()
        }
    }

    private func setupPip() {
        if !AVPictureInPictureController.isPictureInPictureSupported() { return }

        guard let displayLayer = displayLayer else { return }

        // FIX LỖI: Sử dụng initializer chính xác, cung cấp layer VÀ playbackDelegate
        pipController = AVPictureInPictureController(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        
        pipController?.delegate = self
        
        // Kiểm tra phiên bản iOS 14.2+
        if #available(iOS 14.2, *) {
            pipController?.canStartPictureInPictureAutomaticallyFromInline = true
        }
    }
    
    private func startPip() {
        if let pipController = pipController, pipController.isPictureInPicturePossible {
            pipController.startPictureInPicture()
        } else {
            print("Không thể bắt đầu PiP. Kiểm tra lại cài đặt.")
        }
    }
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (Xử lý Khung hình & Hiển thị)
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        // 1. Hiển thị khung hình lên AVSampleBufferDisplayLayer (Phải chạy trên Main Thread)
        DispatchQueue.main.async {
            if self.displayLayer?.isReadyForMoreMediaData == true {
                self.displayLayer?.enqueue(sampleBuffer)
            }
        }
        
        // 2. Xử lý Vision
        if self.pipController?.isPictureInPictureActive != true {
             // Chỉ xử lý Vision khi PiP đang bật
             return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let faceRequest = VNDetectFaceLandmarksRequest { [weak self] request, error in
            guard let observations = request.results as? [VNFaceObservation],
                  let self = self else { return }
            
            self.handleFaceObservations(observations)
        }
        
        // 3. Thực hiện Request
        do {
            try sequenceHandler.perform([faceRequest], on: pixelBuffer)
        } catch {
            print("Lỗi Vision Request: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Face Analysis
    
    private func handleFaceObservations(_ observations: [VNFaceObservation]) {
        var status: String
        
        if observations.isEmpty {
            status = "KHÔNG PHÁT HIỆN KHUÔN MẶT"
        } else {
            let face = observations.first!
            
            // Kiểm tra góc Roll (xoay quanh trục Z)
            if let roll = face.roll, abs(roll.doubleValue) < 0.25 { 
                 status = "✅ ĐANG NHÌN ĐIỆN THOẠI"
            } else {
                 status = "⚠️ NHÌN ĐI NƠI KHÁC / Quay đầu"
            }
        }
        
        let timestamp = Date().timeIntervalSince1970
        let result: [String: Any] = ["time": timestamp, "status": status]
        
        // Gửi kết quả về Flutter (Phải chạy trên Main Thread)
        DispatchQueue.main.async {
            self.eventSink?(result)
        }
    }

    // MARK: - FlutterStreamHandler (Event Channel)
    
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.eventSink = nil
        return nil
    }
    
    // MARK: - AVPictureInPictureControllerDelegate
    
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self._view.isHidden = true
        }
    }
    
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self._view.isHidden = false
        }
    }
    
    // MARK: - AVPictureInPictureSampleBufferPlaybackDelegate
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        // Xử lý PiP play/pause (Không cần thay đổi gì cho luồng camera liên tục)
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // Phạm vi thời gian vô hạn cho luồng camera liên tục
        return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return false // Luôn là false vì đây là luồng live camera
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) { 
        completionHandler() 
    }
}