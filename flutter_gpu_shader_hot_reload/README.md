# Shader Hot Reload with Flutter GPU

A 3D cube rendered with Flutter GPU on Flutter 3.47.

In debug builds, changes to files in `shaders/` are watched automatically.
The app runs `impellerc`, reloads the generated shader bundle with
`ShaderLibrary.reinitializeFromBytes`, and rebuilds the render pipeline.

## Related

- [`ShaderLibrary.fromBytes`](https://api.flutter.dev/flutter/flutter_gpu/ShaderLibrary/fromBytes.html)
- [[Flutter GPU] Load a ShaderLibrary from shader bundle bytes](https://github.com/flutter/flutter/pull/188596)
