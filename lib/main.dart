import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'dart:io'; // Bắt buộc phải thêm để kiểm tra Platform

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: CameraPipScreen());
  }
}

class CameraPipScreen extends StatefulWidget {
  const CameraPipScreen({super.key});

  @override
  State<CameraPipScreen> createState() => _CameraPipScreenState();
}

class _CameraPipScreenState extends State<CameraPipScreen> {
  // Channel để gửi lệnh và nhận dữ liệu
  MethodChannel? _methodChannel;
  EventChannel? _eventChannel;
  String _status = "Chưa kết nối camera.";

  // Hàm format thời gian
  String _formatTimestamp(double timestamp) {
    final dateTime = DateTime.fromMillisecondsSinceEpoch(
      (timestamp * 1000).toInt(),
    );
    return DateFormat('HH:mm:ss').format(dateTime);
  }

  // Khởi tạo và kết nối các Channel sau khi View native được tạo (Chỉ xảy ra trên iOS)
  void _onPlatformViewCreated(int id) {
    _methodChannel = MethodChannel('com.example/camera_pip_method_$id');
    _eventChannel = EventChannel('com.example/face_events_$id');

    // Bắt đầu lắng nghe sự kiện từ Swift
    _eventChannel!
        .receiveBroadcastStream()
        .listen((data) {
          if (mounted) {
            setState(() {
              final timestamp = data['time'] as double;
              final status = data['status'] as String;

              _status =
                  'Kết quả từ nền: $status (${_formatTimestamp(timestamp)})';
            });
          }
        })
        .onError((error) {
          setState(() {
            _status = 'Lỗi nhận sự kiện: $error';
          });
        });

    setState(() {
      _status = "Đã kết nối Camera Native. Sẵn sàng bật PiP.";
    });
  }

  // Gửi lệnh bật PiP (Chỉ hoạt động trên iOS)
  Future<void> _startPip() async {
    // Chỉ thực hiện lệnh PiP nếu đang ở iOS
    if (Platform.isIOS && _methodChannel != null) {
      try {
        await _methodChannel!.invokeMethod('startPip');
        setState(() {
          _status = 'Đã gửi lệnh kích hoạt PiP. Nhấn Home để thấy kết quả.';
        });
      } on PlatformException catch (e) {
        setState(() {
          _status = "Lỗi khi gọi PiP: '${e.message}'.";
        });
      }
    } else {
      // Thông báo khi chạy trên Windows/Android
      setState(() {
        _status = 'Lỗi: Tính năng PiP chỉ hỗ trợ trên iOS.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const String viewType = 'NativeCameraView';

    // Xây dựng widget camera view dựa trên nền tảng
    Widget cameraView;
    if (Platform.isIOS) {
      // Widget camera thực tế chỉ dành cho iOS
      cameraView = UiKitView(
        viewType: viewType,
        creationParams: const <String, dynamic>{},
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onPlatformViewCreated,
      );
    } else {
      // Widget giữ chỗ cho Windows, Android, v.v.
      cameraView = Container(
        color: Colors.grey.shade900,
        child: const Center(
          child: Text(
            'CAMERA NATIVE (iOS PiP) CHẠY TẠI ĐÂY\n(Không hỗ trợ trên Windows)',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('PiP Camera Monitor')),
      body: Column(
        children: [
          Expanded(
            flex: 4,
            child: cameraView, // Sử dụng widget đã định nghĩa
          ),
          Expanded(
            flex: 1,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(_status),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _startPip,
        label: const Text('Bật PiP (Chạy nền)'),
        icon: const Icon(Icons.picture_in_picture_alt),
      ),
    );
  }
}
