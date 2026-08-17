import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'cube_renderer.dart';
import 'cube_settings.dart';

void main() => runApp(const CubeApp());

class CubeApp extends StatelessWidget {
  const CubeApp({super.key, this.rendererLoader = CubeRenderer.create});

  final CubeRendererLoader rendererLoader;

  @override
  Widget build(context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Flutter GPU Shader Hot Reload',
    home: CubePage(rendererLoader: rendererLoader),
  );
}

class CubePage extends StatefulWidget {
  const CubePage({super.key, this.rendererLoader = CubeRenderer.create});

  final CubeRendererLoader rendererLoader;

  @override
  State<CubePage> createState() => _CubePageState();
}

class _CubePageState extends State<CubePage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotation;
  late final Future<CubeFrameRenderer> _renderer;
  CubeFrameRenderer? _activeRenderer;

  var _dragRotationX = 0.0;
  var _dragRotationY = 0.0;

  @override
  void initState() {
    super.initState();
    _renderer = _loadRenderer();
    _rotation = AnimationController(vsync: this);
    _applyRotationSpeed();
  }

  @override
  void reassemble() {
    super.reassemble();
    _applyRotationSpeed();
  }

  @override
  void dispose() {
    _activeRenderer?.dispose();
    _rotation.dispose();
    super.dispose();
  }

  Future<CubeFrameRenderer> _loadRenderer() async {
    final renderer = await widget.rendererLoader();
    if (mounted) {
      _activeRenderer = renderer;
    } else {
      renderer.dispose();
    }
    return renderer;
  }

  void _rotateCube(DragUpdateDetails details) {
    setState(() {
      _dragRotationY += details.delta.dx * 0.012;
      _dragRotationX += details.delta.dy * 0.012;
    });
  }

  void _applyRotationSpeed() {
    if (CubeSettings.rotationsPerSecond <= 0) {
      _rotation.stop();
      return;
    }
    _rotation.repeat(period: CubeSettings.rotationPeriod);
  }

  @override
  Widget build(context) => Scaffold(
    backgroundColor: const Color(0xFF05070D),
    body: FutureBuilder<CubeFrameRenderer>(
      future: _renderer,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _RendererError(error: snapshot.error!);
        }
        final renderer = snapshot.data;
        if (renderer == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: GestureDetector(
            key: const Key('cube-viewport'),
            behavior: HitTestBehavior.opaque,
            onPanUpdate: _rotateCube,
            child: SizedBox.expand(
              child: AnimatedBuilder(
                animation: _rotation,
                builder: (context, child) {
                  return CustomPaint(
                    painter: CubePainter(
                      renderer: renderer,
                      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
                      cubeSize: CubeSettings.size,
                      rotationX: CubeSettings.tilt + _dragRotationX,
                      rotationY:
                          (_rotation.value * math.pi * 2) + _dragRotationY,
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _RendererError extends StatelessWidget {
  const _RendererError({required this.error});

  final Object error;

  @override
  Widget build(context) => Padding(
    padding: const EdgeInsets.all(32),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, size: 36, color: Color(0xFFFF738A)),
        const SizedBox(height: 12),
        const Text('Flutter GPU renderer failed to start.'),
        const SizedBox(height: 8),
        Text(
          '$error',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFF8994AA), fontSize: 12),
        ),
      ],
    ),
  );
}

class CubePainter extends CustomPainter {
  const CubePainter({
    required this.renderer,
    required this.devicePixelRatio,
    required this.cubeSize,
    required this.rotationX,
    required this.rotationY,
  }) : super(repaint: renderer);

  final CubeFrameRenderer renderer;
  final double devicePixelRatio;
  final double cubeSize;
  final double rotationX;
  final double rotationY;

  @override
  void paint(Canvas canvas, Size size) => renderer.paintFrame(
    canvas,
    size,
    devicePixelRatio: devicePixelRatio,
    cubeSize: cubeSize,
    rotationX: rotationX,
    rotationY: rotationY,
  );

  @override
  bool shouldRepaint(covariant CubePainter oldDelegate) =>
      oldDelegate.renderer != renderer ||
      oldDelegate.devicePixelRatio != devicePixelRatio ||
      oldDelegate.cubeSize != cubeSize ||
      oldDelegate.rotationX != rotationX ||
      oldDelegate.rotationY != rotationY;
}
