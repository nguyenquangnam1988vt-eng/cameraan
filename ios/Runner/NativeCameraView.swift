import UIKit
import Flutter
import AVFoundation
import AVKit
import CoreMedia
import Vision // Thêm Vision Framework

class NativeCameraView: NSObject, FlutterPlatformView, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, FlutterStreamHandler {
    
    // MARK: - Properties
    private var _view: UIView
    private var methodChannel: FlutterMethodChannel
    private var eventChannel: FlutterEventChannel?
    private var eventSink: FlutterEventSink?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var pipController: AVPictureInPictureController?
    
    // Vision Request Handler
    private let sequenceHandler = VNSequenceRequestHandler()
    
    // MARK: - Initialization
    // ... (Giữ nguyên phần init, setupAudioSession, setupCamera, setupPip, onListen, onCancel) ...
    
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
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
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
        
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else { return }
        
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if captureSession.canAddInput(input) { captureSession.addInput(input) }
        } catch {
            print("Lỗi khi tạo input camera: \(error.localizedDescription)")
            return
        }

        videoDataOutput = AVCaptureVideoDataOutput()
        // Đảm bảo xử lý trên một queue riêng để không làm tắc UI
        videoDataOutput!.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
        videoDataOutput!.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

        if captureSession.canAddOutput(videoDataOutput!) { captureSession.addOutput(videoDataOutput!) }
        
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        guard let previewLayer = previewLayer else { return }
        
        previewLayer.frame = _view.bounds
        previewLayer.videoGravity = .resizeAspectFill
        _view.layer.addSublayer(previewLayer)

        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.startRunning()
        }
    }

    private func setupPip() {
        if !AVPictureInPictureController.isPictureInPictureSupported() { return }

        guard let previewLayer = previewLayer else { return }

        let contentSource = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: previewLayer)
        
        pipController = AVPictureInPictureController(contentSource: contentSource)
        pipController?.delegate = self
        pipController?.canStartPictureInPictureAutomaticallyFromInline = true
    }
    
    private func startPip() {
        if let pipController = pipController, pipController.isPictureInPicturePossible {
            pipController.startPictureInPicture()
        } else {
            print("Không thể bắt đầu PiP. Kiểm tra lại cài đặt.")
        }
    }
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (Xử lý Khung hình - Nơi chạy Vision)
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        guard self.pipController?.isPictureInPictureActive == true else {
            // Không xử lý nếu PiP chưa được kích hoạt
            return
        }

        // 1. Tạo CVPixelBuffer từ sampleBuffer
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        // 2. Tạo Vision Request: Phát hiện khuôn mặt và các mốc
        let faceRequest = VNDetectFaceLandmarksRequest { [weak self] request, error in
            guard let observations = request.results as? [VNFaceObservation],
                  let self = self else { return }
            
            // Xử lý kết quả nhận diện
            self.handleFaceObservations(observations)
        }
        
        // Cấu hình Vision để xử lý nhanh hơn
        faceRequest.uses.detectionTypes = [.face] 
        
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
            // Lấy khuôn mặt đầu tiên
            let face = observations.first!
            
            // Bổ sung Logic Kiểm tra sự Chú ý (Gaze Tracking)
            // Vision có thể cung cấp Euler Angles (góc Yaw, Pitch, Roll)
            // Ví dụ: Kiểm tra góc Pitch để xem người dùng có cúi đầu xuống không
            
            if let yaw = face.roll, abs(yaw.doubleValue) < 0.2 {
                 // Giá trị abs(yaw) < 0.2 radians (~11 độ) cho thấy đầu đang nhìn thẳng
                 status = "✅ ĐANG NHÌN ĐIỆN THOẠI"
            } else {
                 status = "⚠️ NHÌN ĐI NƠI KHÁC / Quay đầu"
            }
        }
        
        // Gửi kết quả về Flutter
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
    
    // MARK: - AVPictureInPictureControllerDelegate (Để theo dõi trạng thái PiP - Giữ nguyên)
    
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}
    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        return false
    }
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMtime, completion completionHandler: @escaping () -> Void) { completionHandler() }
}