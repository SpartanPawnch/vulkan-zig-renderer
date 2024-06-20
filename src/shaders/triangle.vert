#version 450

layout(location=0) in vec3 inPos;
layout(location=1) in vec3 inNormal;
layout(location=2) in vec2 inTex;

layout(push_constant,std430) uniform camInfo{
    mat4 viewProj;
};

layout(location=0) out vec3 v2fWorldPos;
layout(location=1) out vec3 v2fNormal;
layout(location=2) out vec2 v2fTex;

void main() {
    vec3 world_pos=.01*inPos;
    gl_Position = viewProj*vec4(world_pos, 1.0);
    v2fWorldPos=world_pos;
    v2fNormal=inNormal;
    v2fTex=inTex;
}
