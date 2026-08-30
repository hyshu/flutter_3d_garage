#version 460 core

layout(location = 0) in vec3 position;
layout(location = 1) in vec2 tex_coord;

layout(location = 0) out vec2 v_tex_coord;

layout(binding = 0) uniform FrameInfo {
  mat4 view_projection;
  vec4 anchor;
} frame_info;

void main() {
  vec3 map_position = vec3(
    frame_info.anchor.x + position.x * frame_info.anchor.w,
    frame_info.anchor.y - position.y * frame_info.anchor.w,
    frame_info.anchor.z + position.z
  );
  gl_Position = frame_info.view_projection * vec4(map_position, 1.0);
  v_tex_coord = tex_coord;
}
