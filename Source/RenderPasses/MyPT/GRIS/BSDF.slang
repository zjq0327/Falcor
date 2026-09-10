import RenderPasses.MyPT.MyPTCommon;
import PathState;
__exported import Rendering.Materials.StandardMaterialInstance;

ShadingData loadRcShadingData(PathSample sample, float3 direction)
{
    ShadingData sd = loadShadingData(HitInfo(sample.rcHit), direction);
    sd.posW = sample.rcPositionW;
    sd.uv = sample.rcTexCoord;
    sd.frame = sample.rcFrame;
    sd.tangentW = sample.rcTangentW;
    sd.faceN = sample.rcFaceN;
    sd.V = -direction;
    sd.frontFacing = dot(sd.V, sd.faceN) >= 0.f;
    return sd;
}

// A dot intrinsic may use different reduction instructions across independently
// compiled passes, even in precise mode. At grazing angles that changes BSDF*cos
// noticeably. Keep the same scalar reduction in generation, replay and shift.
[ForceInline]
float grisDot(float3 a, float3 b)
{
    precise float x = a.x * b.x;
    precise float y = a.y * b.y;
    precise float z = a.z * b.z;
    precise float xy = x + y;
    precise float value = xy + z;
    return value;
}

float3 grisToLocal(ShadingFrame sf, float3 direction)
{
    return float3(grisDot(direction, sf.T), grisDot(direction, sf.B), grisDot(direction, sf.N));
}

float3 evalGRISBSDF(ShadingData sd, IMaterialInstance material, float3 direction, inout SampleGenerator sg)
{
    let typed = material as StandardMaterialInstance;
    if (!typed.hasValue) return material.eval(sd, direction, sg);
    // Use the already prepared instance, including textures and adjusted normals.
    StandardMaterialInstance standard = typed.value;
    float3 wi = grisToLocal(standard.sf, sd.V);
    float3 wo = grisToLocal(standard.sf, direction);
    if (!isValidHemisphereReflectionOrTransmission(sd, standard.sf, wi, wo, direction)) return 0.f;
    StandardBSDF bsdf = StandardBSDF(wi, sd.mtl, standard.data);
    precise float3 value = bsdf.eval(wi, wo, sg, BSDFContext());
    return value;
}

float evalGRISBSDFPdf(ShadingData sd, IMaterialInstance material, float3 direction, bool importance)
{
    let typed = material as StandardMaterialInstance;
    if (!typed.hasValue) return evalMyPTBSDFPdf(sd, material, direction, importance);
    StandardMaterialInstance standard = typed.value;
    float3 wi = grisToLocal(standard.sf, sd.V);
    float3 wo = grisToLocal(standard.sf, direction);
    if (!isValidHemisphereReflectionOrTransmission(sd, standard.sf, wi, wo, direction)) return 0.f;
    if (!importance) return abs(standard.evalPdfReference(sd, wi, wo));
    StandardBSDF bsdf = StandardBSDF(wi, sd.mtl, standard.data);
    precise float value = bsdf.evalPdf(wi, wo, BSDFContext());
    return value;
}
