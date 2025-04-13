// SkyAtmosphere.metal
#include <metal_stdlib>
#include "Common.h"

using namespace metal;

constant float PLANET_RADIUS_OFFSET = 0.01f;

struct AtmosphereUniforms {
	float bottomRadius;
	float topRadius;
	
	float rayleighDensityExpScale;
	float3 rayleighScattering;
	
	float mieDensityExpScale;
	float3 mieScattering;
	float3 mieExtinction;
	float3 mieAbsorption;
	float miePhaseG;
	
	float absorptionDensity0LayerWidth;
	float absorptionDensity0ConstantTerm;
	float absorptionDensity0LinearTerm;
	float absorptionDensity1ConstantTerm;
	float absorptionDensity1LinearTerm;
	float3 absorptionExtinction;
	
	float3 groundAlbedo;
	
	float4x4 viewMatrix;
	float4x4 projectionMatrix;
	float4x4 viewProjectionMatrix;
	float4x4 inverseViewProjectionMatrix;
	float4x4 inverseViewMatrix;
	float4x4 inverseProjectionMatrix;
	
	float3 cameraPosition;
	float3 sunDirection;
	float3 sunIlluminance;
	
	float multiScatteringLUTRes;
	float multipleScatteringFactor;
};

struct VertexOut {
	float4 position [[position]];
	float2 texCoord;
};

struct MediumSampleRGB {
	float3 scattering;
	float3 absorption;
	float3 extinction;
	
	float3 scatteringMie;
	float3 absorptionMie;
	float3 extinctionMie;
	
	float3 scatteringRay;
	float3 absorptionRay;
	float3 extinctionRay;
	
	float3 scatteringOzo;
	float3 absorptionOzo;
	float3 extinctionOzo;
	
	float3 albedo;
};

struct SingleScatteringResult {
	float3 luminance;
	float3 opticalDepth;
	float3 transmittance;
	float3 multiScatteringAs1;
	
	float3 newMultiScatteringStep0Out;
	float3 newMultiScatteringStep1Out;
};

//////////////////////////////////
// Atmosphere Specific Utilities
//////////////////////////////////

// Move ray origin to top atmosphere boundary if needed
bool moveToTopAtmosphere(thread float3& worldPos, float3 worldDir, float atmosphereTopRadius) {
	float viewHeight = length(worldPos);
	if (viewHeight > atmosphereTopRadius) {
		Ray ray = createRay(worldPos, worldDir);
		float tTop = raySphereIntersectNearest(ray, float3(0.0f, 0.0f, 0.0f), atmosphereTopRadius);
		if (tTop >= 0.0f) {
			float3 upVector = worldPos / viewHeight;
			float3 upOffset = upVector * -PLANET_RADIUS_OFFSET;
			worldPos = worldPos + worldDir * tTop + upOffset;
		} else {
			return false; // Ray is not intersecting the atmosphere
		}
	}
	return true; // ok to start tracing
}

float getAlbedo(float scattering, float extinction) {
	return scattering / max(0.001, extinction);
}

float3 getAlbedo(float3 scattering, float3 extinction) {
	return scattering / max(0.001, extinction);
}

MediumSampleRGB sampleMediumRGB(float3 worldPos, constant AtmosphereUniforms& atmosphere) {
	const float viewHeight = length(worldPos) - atmosphere.bottomRadius;
	
	const float densityMie = exp(atmosphere.mieDensityExpScale * viewHeight);
	const float densityRay = exp(atmosphere.rayleighDensityExpScale * viewHeight);
	const float densityOzo = saturate(viewHeight < atmosphere.absorptionDensity0LayerWidth ?
									 atmosphere.absorptionDensity0LinearTerm * viewHeight + atmosphere.absorptionDensity0ConstantTerm :
									 atmosphere.absorptionDensity1LinearTerm * viewHeight + atmosphere.absorptionDensity1ConstantTerm);
	
	MediumSampleRGB s;
	
	s.scatteringMie = densityMie * atmosphere.mieScattering;
	s.absorptionMie = densityMie * atmosphere.mieAbsorption;
	s.extinctionMie = densityMie * atmosphere.mieExtinction;
	
	s.scatteringRay = densityRay * atmosphere.rayleighScattering;
	s.absorptionRay = 0.0f;
	s.extinctionRay = s.scatteringRay + s.absorptionRay;
	
	s.scatteringOzo = 0.0;
	s.absorptionOzo = densityOzo * atmosphere.absorptionExtinction;
	s.extinctionOzo = s.scatteringOzo + s.absorptionOzo;
	
	s.scattering = s.scatteringMie + s.scatteringRay + s.scatteringOzo;
	s.absorption = s.absorptionMie + s.absorptionRay + s.absorptionOzo;
	s.extinction = s.extinctionMie + s.extinctionRay + s.extinctionOzo;
	s.albedo = getAlbedo(s.scattering, s.extinction);
	
	return s;
}

//////////////////////////////////
// LUT functions
//////////////////////////////////

float fromUnitToSubUvs(float u, float resolution) {
	return (u + 0.5f / resolution) * (resolution / (resolution + 1.0f));
}

float fromSubUvsToUnit(float u, float resolution) {
	return (u - 0.5f / resolution) * (resolution / (resolution - 1.0f));
}

void LUTTransmittanceParamsToUV(constant AtmosphereUniforms& atmosphere, float viewHeight, float viewZenithCosAngle, thread float2& uv) {
	float h = sqrt(max(0.0f, atmosphere.topRadius * atmosphere.topRadius - atmosphere.bottomRadius * atmosphere.bottomRadius));
	float rho = sqrt(max(0.0f, viewHeight * viewHeight - atmosphere.bottomRadius * atmosphere.bottomRadius));
	
	float discriminant = viewHeight * viewHeight * (viewZenithCosAngle * viewZenithCosAngle - 1.0) + atmosphere.topRadius * atmosphere.topRadius;
	float d = max(0.0, (-viewHeight * viewZenithCosAngle + sqrt(discriminant)));
	
	float dMin = atmosphere.topRadius - viewHeight;
	float dMax = rho + h;
	float xMu = (d - dMin) / (dMax - dMin);
	float xR = rho / h;
	
	uv = float2(xMu, xR);
}

void UVToLUTTransmittanceParams(constant AtmosphereUniforms& atmosphere, thread float& viewHeight, thread float& viewZenithCosAngle, float2 uv) {
	float xMu = uv.x;
	float xR = uv.y;
	
	float h = sqrt(atmosphere.topRadius * atmosphere.topRadius - atmosphere.bottomRadius * atmosphere.bottomRadius);
	float rho = h * xR;
	viewHeight = sqrt(rho * rho + atmosphere.bottomRadius * atmosphere.bottomRadius);
	
	float dMin = atmosphere.topRadius - viewHeight;
	float dMax = rho + h;
	float d = dMin + xMu * (dMax - dMin);
	viewZenithCosAngle = d == 0.0 ? 1.0f : (h * h - rho * rho - d * d) / (2.0 * viewHeight * d);
	viewZenithCosAngle = clamp(viewZenithCosAngle, -1.0, 1.0);
}

// Convert UV coordinates to Sky-View LUT parameters
void UVToSkyViewLUTParams(constant AtmosphereUniforms& atmosphere, thread float& viewZenithCosAngle, thread float& lightViewCosAngle, float viewHeight, float2 uv) {
	uv = clamp(uv, float2(0.001, 0.001), float2(0.999, 0.999));
	uv = float2(fromSubUvsToUnit(uv.x, 256.0f), fromSubUvsToUnit(uv.y, 144.0f));
	
	float vHorizon = sqrt(viewHeight * viewHeight - atmosphere.bottomRadius * atmosphere.bottomRadius);
	float cosBeta = vHorizon / viewHeight;
	float beta = acos(cosBeta);
	float zetaHorizonAngle = PI - beta;
	
	if (uv.y < 0.5f) {
		float coord = 2.0*uv.y;
		coord = 1.0 - coord;
		coord *= coord;
		coord = 1.0 - coord;
		viewZenithCosAngle = cos(zetaHorizonAngle * coord);
	} else {
		float coord = uv.y*2.0 - 1.0;
		coord *= coord;
		viewZenithCosAngle = cos(zetaHorizonAngle + beta * coord);
	}
	
	float coord = uv.x;
	coord *= coord;
	lightViewCosAngle = -(coord*2.0 - 1.0);
}

void skyViewLutParamsToUv(constant AtmosphereUniforms& atmosphere, bool intersectGround, float viewZenithCosAngle, float lightViewCosAngle, float viewHeight, thread float2& uv) {
	float vHorizon = sqrt(viewHeight * viewHeight - atmosphere.bottomRadius * atmosphere.bottomRadius);
	float cosBeta = vHorizon / viewHeight;
	float beta = acos(cosBeta);
	float zenithHorizonAngle = PI - beta;
	
	if (!intersectGround) {
		float coord = acos(viewZenithCosAngle) / zenithHorizonAngle;
		coord = 1.0 - coord;
		coord = sqrt(coord);
		coord = 1.0 - coord;
		uv.y = coord * 0.5f;
	} else {
		float coord = (acos(viewZenithCosAngle) - zenithHorizonAngle) / beta;
		coord = sqrt(coord);
		uv.y = coord * 0.5f + 0.5f;
	}
	
	{
		float coord = -lightViewCosAngle * 0.5f + 0.5f;
		coord = sqrt(coord);
		uv.x = coord;
	}
	
	uv = float2(fromUnitToSubUvs(uv.x, 256.0f), fromUnitToSubUvs(uv.y, 144.0f));
}

float3 getMultipleScattering(constant AtmosphereUniforms& atmosphere, float3 scattering, float3 extinction, float3 worldPos, float viewZenithCosAngle, texture2d<float> multiScatteringTexture, sampler linearSampler) {
	float2 uv = saturate(float2(viewZenithCosAngle*0.5f + 0.5f, (length(worldPos) - atmosphere.bottomRadius) / (atmosphere.topRadius - atmosphere.bottomRadius)));
	uv = float2(fromUnitToSubUvs(uv.x, atmosphere.multiScatteringLUTRes), fromUnitToSubUvs(uv.y, atmosphere.multiScatteringLUTRes));
	
	float3 multiScatteredLuminance = multiScatteringTexture.sample(linearSampler, uv).rgb;
	return multiScatteredLuminance;
}

float3 getSunLuminance(float3 worldPos, float3 worldDir, float3 sunDir, float planetRadius) {
	if (dot(worldDir, sunDir) > cos(0.5 * PI / 180.0)) {
		Ray ray = createRay(worldPos, worldDir);
		float t = raySphereIntersectNearest(ray, float3(0.0f, 0.0f, 0.0f), planetRadius);
		if (t < 0.0f) { // no intersection
			return float3(1000000.0); // Arbitrary bright value for sun disk
		}
	}
	return float3(0.0);
}

//////////////////////////////////
// Core rendering functions
//////////////////////////////////

SingleScatteringResult integrateScatteredLuminance(
	float2 pixPos, float3 worldPos, float3 worldDir, float3 sunDir,
	constant AtmosphereUniforms& atmosphere, bool ground, float sampleCountIni,
	float depthBufferValue, bool variableSampleCount, bool mieRayPhase,
	texture2d<float> transmittanceLutTexture, texture2d<float> multiScatteringTexture,
	sampler linearSampler, float3 baseIlluminance, float tMaxMax = 9000000.0f)
{
	SingleScatteringResult result = {};
	
	// Compute next intersection with atmosphere or ground
	Ray ray = createRay(worldPos, worldDir);
	float tBottom = raySphereIntersectNearest(ray, float3(0.0f, 0.0f, 0.0f), atmosphere.bottomRadius);
	float tTop = raySphereIntersectNearest(ray, float3(0.0f, 0.0f, 0.0f), atmosphere.topRadius);
	float tMax = 0.0f;
	
	if (tBottom < 0.0f) {
		if (tTop < 0.0f) {
			tMax = 0.0f; // No intersection with earth nor atmosphere: stop right away
			return result;
		} else {
			tMax = tTop;
		}
	} else {
		if (tTop > 0.0f) {
			tMax = min(tTop, tBottom);
		}
	}
	
	if (depthBufferValue >= 0.0f) {
		float3 clipSpace = float3((pixPos / float2(atmosphere.multiScatteringLUTRes))*float2(2.0, -2.0) - float2(1.0, -1.0), depthBufferValue);
		if (clipSpace.z < 1.0f) {
			float4 depthBufferWorldPos = atmosphere.inverseViewProjectionMatrix * float4(clipSpace, 1.0);
			depthBufferWorldPos /= depthBufferWorldPos.w;
			
			float tDepth = length(depthBufferWorldPos.xyz - (worldPos + float3(0.0, 0.0, -atmosphere.bottomRadius)));
			if (tDepth < tMax) {
				tMax = tDepth;
			}
		}
	}
	
	tMax = min(tMax, tMaxMax);
	
	float sampleCount = sampleCountIni;
	float sampleCountFloor = sampleCountIni;
	float tMaxFloor = tMax;
	
	if (variableSampleCount) {
		sampleCount = mix(10.0, 30.0, saturate(tMax*0.01));
		sampleCountFloor = floor(sampleCount);
		tMaxFloor = tMax * sampleCountFloor / sampleCount;
	}
	
	float dt = tMax / sampleCount;
	
	// Phase functions
	const float uniformPhaseValue = uniformPhase();
	const float3 wi = sunDir;
	const float3 wo = worldDir;
	float cosTheta = dot(wi, wo);
	float miePhaseValue = cornetteShanksPhase(atmosphere.miePhaseG, -cosTheta) * 3;
	float rayleighPhaseValue = rayleighPhase(cosTheta);
		
	// Ray march the atmosphere to integrate optical depth
	float3 luminance = 0.0f;
	float3 throughput = 1.0;
	float3 opticalDepth = 0.0;
	float t = 0.0f;
	float tPrev = 0.0;
	const float sampleSegmentT = 0.3f;
	
	for (float s = 0.0f; s < sampleCount; s += 1.0f) {
		if (variableSampleCount) {
			float t0 = (s) / sampleCountFloor;
			float t1 = (s + 1.0f) / sampleCountFloor;
			t0 = t0 * t0;
			t1 = t1 * t1;
			t0 = tMaxFloor * t0;
			
			if (t1 > 1.0) {
				t1 = tMax;
			} else {
				t1 = tMaxFloor * t1;
			}
			
			t = t0 + (t1 - t0)*sampleSegmentT;
			dt = t1 - t0;
		} else {
			float newT = tMax * (s + sampleSegmentT) / sampleCount;
			dt = newT - t;
			t = newT;
		}
		
		float3 pos = worldPos + t * worldDir;
		
		MediumSampleRGB medium = sampleMediumRGB(pos, atmosphere);
		const float3 sampleOpticalDepth = medium.extinction * dt;
		const float3 sampleTransmittance = exp(-sampleOpticalDepth);
		opticalDepth += sampleOpticalDepth;
		
		float pHeight = length(pos);
		const float3 upVector = pos / pHeight;
		float sunZenithCosAngle = dot(sunDir, upVector);
		float2 uv;
		LUTTransmittanceParamsToUV(atmosphere, pHeight, sunZenithCosAngle, uv);
		float3 transmittanceToSun = transmittanceLutTexture.sample(linearSampler, uv).rgb;

		float3 phaseTimesScattering;
		if (mieRayPhase) {
			phaseTimesScattering = medium.scatteringMie * miePhaseValue + medium.scatteringRay * rayleighPhaseValue;
		} else {
			phaseTimesScattering = medium.scattering * uniformPhaseValue;
		}

		Ray shadowRay = createRay(pos, sunDir);
		float tEarth = raySphereIntersectNearest(shadowRay, float3(0, 0, 0) + PLANET_RADIUS_OFFSET * upVector, atmosphere.bottomRadius);
		float earthShadow = tEarth >= 0.0f ? 0.0f : 1.0f;

		// Multi-scattering contribution
		float3 multiScatteredLuminance = getMultipleScattering(atmosphere, medium.scattering, medium.extinction, pos, sunZenithCosAngle, multiScatteringTexture, linearSampler);
		float3 scattering = baseIlluminance * (earthShadow * transmittanceToSun * phaseTimesScattering + multiScatteredLuminance * medium.scattering);
		float3 mediumScattering = medium.scattering * 1.0;
		float3 mediumScatteringInt = (mediumScattering - mediumScattering * sampleTransmittance) / medium.extinction;
		result.multiScatteringAs1 += throughput * mediumScatteringInt;

		{
			float3 newMediumScattering;
			
			newMediumScattering = earthShadow * transmittanceToSun * medium.scattering * uniformPhaseValue * 1;
			result.newMultiScatteringStep0Out += throughput * (newMediumScattering - newMediumScattering * sampleTransmittance) / medium.extinction;
			
			newMediumScattering = medium.scattering * uniformPhaseValue * multiScatteredLuminance;
			result.newMultiScatteringStep1Out += throughput * (newMediumScattering - newMediumScattering * sampleTransmittance) / medium.extinction;
		}

		// Accumulate in-scattered light along the ray segment
		float3 inScattering = (scattering - scattering * sampleTransmittance) / medium.extinction;
		luminance += throughput * inScattering;
		throughput *= sampleTransmittance;

		tPrev = t;
	}

	if (ground && tMax == tBottom && tBottom > 0.0) {
		// Account for bounced light off the earth
		float3 pos = worldPos + tBottom * worldDir;
		float pHeight = length(pos);
		
		const float3 upVector = pos / pHeight;
		float sunZenithCosAngle = dot(sunDir, upVector);
		float2 uv;
		LUTTransmittanceParamsToUV(atmosphere, pHeight, sunZenithCosAngle, uv);
		float3 transmittanceToSun = transmittanceLutTexture.sample(linearSampler, uv).rgb;
		
		const float nDotL = saturate(dot(normalize(upVector), normalize(sunDir)));
		luminance += baseIlluminance * transmittanceToSun * throughput * nDotL * atmosphere.groundAlbedo / PI;
	}

	result.luminance = luminance;
	result.opticalDepth = opticalDepth;
	result.transmittance = throughput;
	return result;
}

//////////////////////////////////
// Vertex and Fragment shaders
//////////////////////////////////

vertex VertexOut skyFullscreenQuadVertex(uint vertexID [[vertex_id]]) {
	VertexOut out;
	
	float2 uv = float2(-1.0f);
	uv = vertexID == 1 ? float2(-1.0f, 3.0f) : uv;
	uv = vertexID == 2 ? float2(3.0f, -1.0f) : uv;
	out.position = float4(uv, 0.0, 1.0);
	
	out.texCoord = (uv + 1.0) * 0.5;
	
	return out;
}

fragment float4 transmittanceLutFragment(VertexOut in [[stage_in]],
										 constant AtmosphereUniforms& uniforms [[buffer(0)]]) {
	constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
	float viewHeight, viewZenithCosAngle;
	UVToLUTTransmittanceParams(uniforms, viewHeight, viewZenithCosAngle, in.texCoord);
	
	float3 worldPos = float3(0.0f, 0.0f, viewHeight);
	float3 worldDir = float3(0.0f, sqrt(1.0 - viewZenithCosAngle * viewZenithCosAngle), viewZenithCosAngle);
	
	const bool ground = false;
	const float sampleCountIni = 40.0f;
	const float depthBufferValue = -1.0;
	const bool variableSampleCount = false;
	const bool mieRayPhase = false;
	
	float3 transmittance = exp(-integrateScatteredLuminance(
		in.position.xy, worldPos, worldDir, uniforms.sunDirection, uniforms,
		ground, sampleCountIni, depthBufferValue, variableSampleCount, mieRayPhase,
		texture2d<float>(), texture2d<float>(), linearSampler, float3(1.0)
	).opticalDepth);
	
	return float4(transmittance, 1.0f);
}

kernel void multiScatteringLutCompute(uint2 tid [[thread_position_in_grid]],
									 constant AtmosphereUniforms& uniforms [[buffer(0)]],
									 texture2d<float> transmittanceLUT [[texture(0)]],
									 texture2d<float, access::write> multiScatterLUT [[texture(1)]]) {
	constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
	
	float2 pixPos = float2(tid) + 0.5f;
	float2 uv = pixPos / uniforms.multiScatteringLUTRes;
	
	uv = float2(fromSubUvsToUnit(uv.x, uniforms.multiScatteringLUTRes),
				fromSubUvsToUnit(uv.y, uniforms.multiScatteringLUTRes));
	
	float cosSunZenithAngle = uv.x * 2.0 - 1.0;
	float3 sunDir = float3(0.0, sqrt(saturate(1.0 - cosSunZenithAngle * cosSunZenithAngle)), cosSunZenithAngle);
	float viewHeight = uniforms.bottomRadius + saturate(uv.y + PLANET_RADIUS_OFFSET) *
					 (uniforms.topRadius - uniforms.bottomRadius - PLANET_RADIUS_OFFSET);
	
	float3 worldPos = float3(0.0f, 0.0f, viewHeight);
	
	const float sphereSolidAngle = 4.0 * PI;
	const float isotropicPhase = 1.0 / sphereSolidAngle;
	
	float3 totalMultiScatAs1 = float3(0.0);
	float3 totalL = float3(0.0);
	
	const int SQRTSAMPLECOUNT = 8;
	for (int i = 0; i < SQRTSAMPLECOUNT; i++) {
		for (int j = 0; j < SQRTSAMPLECOUNT; j++) {
			float randA = (float(i) + 0.5f) / float(SQRTSAMPLECOUNT);
			float randB = (float(j) + 0.5f) / float(SQRTSAMPLECOUNT);
			float theta = 2.0f * PI * randA;
			float phi = acos(1.0f - 2.0f * randB);
			
			float3 worldDir;
			worldDir.x = cos(theta) * sin(phi);
			worldDir.y = sin(theta) * sin(phi);
			worldDir.z = cos(phi);
			
			SingleScatteringResult ss = integrateScatteredLuminance(
				pixPos, worldPos, worldDir, sunDir, uniforms,
				true,
				20.0,
				-1.0,
				false,
				false,
				transmittanceLUT, texture2d<float>(), linearSampler, float3(1.0)
			);
			
			float sampleWeight = sphereSolidAngle / float(SQRTSAMPLECOUNT * SQRTSAMPLECOUNT);
			totalMultiScatAs1 += ss.multiScatteringAs1 * sampleWeight;
			totalL += ss.luminance * sampleWeight;
		}
	}
	
	float3 multiScatAs1 = totalMultiScatAs1 * isotropicPhase;
	float3 inScatteredLuminance = totalL * isotropicPhase;
	
	// Apply geometric series for multiple scattering
	const float3 r = multiScatAs1;
	const float3 sumOfAllMultiScatteringEvents = 1.0f / max(float3(0.01), 1.0 - r);
	float3 luminance = inScatteredLuminance * sumOfAllMultiScatteringEvents;
	
	multiScatterLUT.write(float4(uniforms.multipleScatteringFactor * luminance, 1.0f), tid);
}

fragment float4 skyViewLutFragment(VertexOut in [[stage_in]],
								  constant AtmosphereUniforms& uniforms [[buffer(0)]],
								  texture2d<float> transmittanceLUT [[texture(0)]],
								  texture2d<float> multiScatteringLUT [[texture(1)]]) {
	constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
	
	float viewZenithCosAngle;
	float lightViewCosAngle;
	float viewHeight = length(uniforms.cameraPosition);
	
	UVToSkyViewLUTParams(uniforms, viewZenithCosAngle, lightViewCosAngle, viewHeight, in.texCoord);
	
	float3 sunDir = normalize(uniforms.sunDirection);
	
	float viewZenithSinAngle = sqrt(max(0.0, 1.0 - viewZenithCosAngle * viewZenithCosAngle));
	float3 worldDir = float3(
		viewZenithSinAngle * lightViewCosAngle,
		viewZenithSinAngle * sqrt(max(0.0, 1.0 - lightViewCosAngle * lightViewCosAngle)),
		viewZenithCosAngle);
	worldDir = normalize(worldDir);
	
	float3 worldPos = float3(0.0f, 0.0f, viewHeight);
	
	// Move to top atmosphere
	if (!moveToTopAtmosphere(worldPos, worldDir, uniforms.topRadius)) {
		// Ray is not intersecting the atmosphere
		return float4(0, 0, 0, 1);
	}
	
	const bool ground = false;
	const float sampleCountIni = 30;
	const float depthBufferValue = -1.0;
	const bool variableSampleCount = true;
	const bool mieRayPhase = true;
	
	SingleScatteringResult ss = integrateScatteredLuminance(
		in.position.xy, worldPos, worldDir, sunDir, uniforms,
		ground, sampleCountIni, depthBufferValue, variableSampleCount, mieRayPhase,
		transmittanceLUT, multiScatteringLUT, linearSampler, float3(1.0)
	);
	
	return float4(ss.luminance, 1);
}

fragment float4 skyRenderingFragment(VertexOut in [[stage_in]],
									constant AtmosphereUniforms& uniforms [[buffer(0)]],
									texture2d<float> transmittanceLUT [[texture(0)]],
									texture2d<float> multiScatteringLUT [[texture(1)]],
									texture2d<float> skyViewLUT [[texture(2)]],
									depth2d<float> depthTexture [[texture(3)]],
									sampler linearSampler [[sampler(0)]]) {
	
	float3 clipSpace = float3(in.texCoord * 2.0 - 1.0, 0.0);
	float4 viewPos = uniforms.inverseProjectionMatrix * float4(clipSpace, 1.0);
	viewPos /= viewPos.w;
	
	float3 worldDir = normalize((uniforms.inverseViewMatrix * float4(viewPos.xyz, 0.0)).xyz);
	float3 worldPos = uniforms.cameraPosition;
	float depth = depthTexture.sample(linearSampler, in.texCoord);
	
	float3 luminance = getSunLuminance(worldPos, worldDir, uniforms.sunDirection, uniforms.bottomRadius);
	
	// Move to top atmosphere as the starting point for ray marching
	if (!moveToTopAtmosphere(worldPos, worldDir, uniforms.topRadius)) {
		// Ray is not intersecting the atmosphere
		return float4(luminance, 1.0);
	}
	
	// Parameters for scattering integration
	const bool ground = false;
	const float sampleCountIni = 0.0f;
	const bool variableSampleCount = true;
	const bool mieRayPhase = true;
	
	// Integrate scattered luminance
	SingleScatteringResult ss = integrateScatteredLuminance(
		in.position.xy, worldPos, worldDir, uniforms.sunDirection, uniforms,
		ground, sampleCountIni, depth, variableSampleCount, mieRayPhase,
		transmittanceLUT, multiScatteringLUT, linearSampler, uniforms.sunIlluminance
	);
	
	luminance += ss.luminance;
	
	return float4(luminance, 1.0);
}
