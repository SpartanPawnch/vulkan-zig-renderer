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
layout(set=0,binding=2) uniform sampler2D texMetallicRoughness;

layout(set=1,binding=0) uniform SceneInfo{
    vec3 lightPos;
    vec3 lightColor;
    vec3 lightAmbient;
    vec3 camPos;
}sceneInfoFrag;

layout(location = 0) out vec4 outColor;

void main() {
    const float PI = 3.14159265359;
    //lookup textures
    float metalness=materialUniform.metallicFactor*texture(texMetallicRoughness,v2fTex).b;
    float roughness=materialUniform.roughnessFactor*texture(texMetallicRoughness,v2fTex).g;
    vec3 cmat=texture(colorTex,v2fTex).rgb;

    //calculate vectors
    vec3 lightDir=normalize(sceneInfoFrag.lightPos-v2fWorldPos);
    vec3 viewDir=normalize(sceneInfoFrag.camPos-v2fWorldPos);
    vec3 halfVec=normalize((lightDir+viewDir)/2.f);
    float shininess=(2.f/(pow(roughness,4)+1e-9))-2.f;

    //calculate dot product
    float hv=dot(halfVec,viewDir);
    float nvPlus=clamp(dot(v2fNormal,halfVec),1e-9f,1.f);
    float nhPlus=clamp(dot(v2fNormal,halfVec),1e-9f,1.f);
    float nlPlus=clamp(dot(v2fNormal,halfVec),1e-9f,1.f);

    //calculate subfunctions
    vec3 f0=(1.f-metalness)*vec3(.04f)+metalness*cmat;
    vec3 fresnel=f0+(1-f0)*pow(1-hv,5);

    //calculate diffuse
    vec3 diffuse=(cmat/PI)*(vec3(1.f)-fresnel)*(1.f-metalness);

    //calculate specular
    float normalDist=(shininess+2.f)*pow(nhPlus,shininess)/(2.f*PI);
    float masking=min(1.f,min(2.f*nhPlus*nvPlus/hv,2.f*nhPlus*nlPlus/hv));

    vec3 specular=(normalDist*fresnel*masking)/(4*nvPlus*nhPlus);

    vec3 light=sceneInfoFrag.lightAmbient*cmat+(diffuse+specular)*sceneInfoFrag.lightColor*nlPlus;
    outColor=vec4(light,1.f);
    
}
