#version 460 core

// Saving this file recompiles and reloads the shader in debug builds.
layout(location = 0) in vec4 v_color;
layout(location = 0) out vec4 frag_color;

void main() {
  float gray = (v_color.r + v_color.g + v_color.b) / 3.0;
  frag_color = vec4(gray, gray, gray, v_color.a);
}
