#version 460 core

layout(location = 0) in vec2 v_tex_coord;
layout(location = 0) out vec4 frag_color;

layout(binding = 0) uniform sampler2D u_texture;

void main() {
  frag_color = texture(u_texture, v_tex_coord);
}
