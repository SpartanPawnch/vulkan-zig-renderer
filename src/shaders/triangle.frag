#version 450

layout(location=0) in vec3 v2fWorldPos;
layout(location=1) in vec3 v2fNormal;
layout(location=2) in vec2 v2fTex;

layout(set=0,binding=0) uniform MaterialUniform{
    vec4 baseColorFactor;
    float metallicFactor;
    float roughnessFactor;
}materialUniform;

layout(set=0,binding=1) uniform sampler2D colorTex;

layout(location = 0) out vec4 outColor;

void main() {
    vec3 lightVec=normalize(-v2fWorldPos);
    float specular=clamp(dot(v2fNormal,lightVec),1e-9,1.f);
    vec4 colorFactor=materialUniform.baseColorFactor*texture(colorTex,v2fTex);
    outColor=vec4(colorFactor.rgb*specular,colorFactor.a);
    // outColor=vec4(vec3(.2)*specular,1.);
}
