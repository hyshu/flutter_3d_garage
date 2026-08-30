import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maplibre_flutter_gpu/maplibre_flutter_gpu.dart';
import 'package:url_launcher/url_launcher.dart';

import 'map_style.dart';
import 'map_settings_dialog.dart';
import 'plateau_mesh_renderer.dart';

void main() => runApp(const ShinjukuApp());

final class const ShinjukuApp({super.key}) extends StatelessWidget {
  @override
  Widget build(context) =>
      const MaterialApp(debugShowCheckedModeBanner: false, home: ShinjukuMap());
}

final class const ShinjukuMap({super.key}) extends StatefulWidget {
  @override
  State<ShinjukuMap> createState() => _ShinjukuMapState();
}

final class _ShinjukuMapState extends State<ShinjukuMap> {
  static const _camera = CameraPosition(
    target: LatLng(35.6904, 139.6933),
    zoom: 16.45,
    bearing: 86,
    tilt: 52,
  );

  final _meshRenderer = PlateauMeshRenderer();
  MapLibreMapController? _controller;
  var _styleReady = false;
  var _isMapVisible = false;
  var _labelsVisible = osmLabelsInitiallyVisible;
  var _updatingLabelVisibility = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initializeRenderer());
  }

  Future<void> _initializeRenderer() async {
    try {
      await _meshRenderer.initialize();
      await _updateBuildingPriority();
    } catch (error, stackTrace) {
      debugPrint('Unable to initialize PLATEAU renderer: $error\n$stackTrace');
    }
  }

  void _onMapCreated(MapLibreMapController controller) {
    _controller = controller;
  }

  void _onStyleLoaded() {
    _styleReady = true;
    if (mounted && !_isMapVisible) {
      setState(() => _isMapVisible = true);
    }
    unawaited(_updateBuildingPriority());
  }

  Future<void> _updateBuildingPriority() async {
    final controller = _controller;
    if (controller == null || !_styleReady) return;
    try {
      final camera = await controller.queryCameraPosition();
      if (!mounted || !identical(controller, _controller)) return;
      if (camera != null) {
        _meshRenderer.updateCenter(camera.target);
      }
    } catch (error, stackTrace) {
      debugPrint('Unable to update PLATEAU buildings: $error\n$stackTrace');
    }
  }

  Future<bool> _setLabelsVisible(bool visible) async {
    final controller = _controller;
    if (controller == null || !_styleReady || _updatingLabelVisibility) {
      return false;
    }
    setState(() => _updatingLabelVisibility = true);
    try {
      await _applyLabelVisibility(controller, visible);
      if (mounted && identical(controller, _controller)) {
        setState(() => _labelsVisible = visible);
        return true;
      }
      return false;
    } catch (error, stackTrace) {
      await _restoreLabelVisibility(controller);
      debugPrint('Unable to update OSM label visibility: $error\n$stackTrace');
      return false;
    } finally {
      if (mounted) setState(() => _updatingLabelVisibility = false);
    }
  }

  Future<void> _applyLabelVisibility(
    MapLibreMapController controller,
    bool visible,
  ) async {
    for (final layerId in osmLabelLayerIds) {
      await controller.setLayerVisibility(layerId, visible);
    }
  }

  Future<void> _restoreLabelVisibility(MapLibreMapController controller) async {
    for (final layerId in osmLabelLayerIds) {
      try {
        await controller.setLayerVisibility(layerId, _labelsVisible);
      } catch (_) {
        // Continue so one failed layer does not prevent the remaining rollback.
      }
    }
  }

  Future<void> _showSettings() async {
    await showDialog<void>(
      context: context,
      builder: (context) => MapSettingsDialog(
        labelsVisible: _labelsVisible,
        labelsEnabled: _styleReady,
        onLabelsChanged: _setLabelsVisible,
      ),
    );
  }

  @override
  void dispose() {
    _meshRenderer.dispose();
    super.dispose();
  }

  @override
  Widget build(context) => Scaffold(
    extendBodyBehindAppBar: true,
    appBar: AppBar(
      automaticallyImplyLeading: false,
      forceMaterialTransparency: true,
      actions: [
        IconButton.filledTonal(
          tooltip: 'Map settings',
          onPressed: () => unawaited(_showSettings()),
          icon: const Icon(Icons.settings),
        ),
        const SizedBox(width: 8),
      ],
    ),
    body: Stack(
      children: [
        Positioned.fill(
          child: MapLibreMap(
            styleString: buildShinjukuStyle(),
            initialCameraPosition: _camera,
            cameraTargetBounds: const CameraTargetBounds(
              plateauTexturedAreaBounds,
            ),
            minMaxZoomPreference: const MinMaxZoomPreference(15.5, 20.5),
            minMaxTiltPreference: const MinMaxTiltPreference(0, 80),
            compassEnabled: false,
            logoEnabled: false,
            scaleControlEnabled: false,
            attributionButtonBuilder: _buildAttribution,
            onAttributionLinkTap: (uri) => unawaited(launchUrl(uri)),
            gpuMapRenderCallback: _meshRenderer.render,
            gpuRepaint: _meshRenderer,
            onMapCreated: _onMapCreated,
            onStyleLoadedCallback: _onStyleLoaded,
            onCameraIdle: () => unawaited(_updateBuildingPriority()),
          ),
        ),
        if (!_isMapVisible)
          const Positioned.fill(child: ColoredBox(color: Color(0xffdfdfdc))),
      ],
    ),
  );
}

Widget _buildAttribution(BuildContext context, VoidCallback onPressed) =>
    TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: const Color(0xff222222),
        backgroundColor: const Color(0xddffffff),
        minimumSize: Size.zero,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 10),
      ),
      child: const Text('PLATEAU · OSM'),
    );
