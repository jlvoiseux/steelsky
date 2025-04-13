#include <metal_stdlib>
#include "Common.h"

using namespace metal;

struct VolumetricUniforms {
	float4x4 viewMatrix;
	float4x4 projectionMatrix;
	float4x4 viewProjectionMatrix;
	float4x4 inverseViewProjectionMatrix;
	float4x4 previousViewProjectionMatrix;
	float4x4 lightViewProjectionMatrix;
	
	float3 cameraPosition;
	float3 sunDirection;
	float3 sunIlluminance;
	
	float planetRadius;
	float atmosphereRadius;
	
	float fogDensity;
	float fogScatteringCoeff;
	float godRayStrength;
	float godRayDecay;
	
	float screenWidth;
	float screenHeight;
	float time;
};

//////////////////////////////////
// Position Reconstruction
//////////////////////////////////

float3 reconstructWorldPosition(float2 uv, float depth, float4x4 inverseViewProjMatrix) {
	float4 clipSpacePosition = float4(uv * 2.0f - 1.0f, depth, 1.0f);
	float4 viewSpacePosition = inverseViewProjMatrix * clipSpacePosition;
	return viewSpacePosition.xyz / viewSpacePosition.w;
}

//////////////////////////////////
// Density Sampling
//////////////////////////////////

// Enhanced density function with noise
float sampleDensity(float3 position, float3 cameraPosition, float planetRadius, float atmosphereRadius,
				texture3d<float> noiseTexture, sampler noiseSampler, float time) {
	float height = length(position) - planetRadius;
	float normalizedHeight = height / (atmosphereRadius - planetRadius);
	
	// Base exponential height-based density
	float heightDensity = exp(-normalizedHeight * 4.0) * saturate(normalizedHeight * 8.0);
	
	// Sample multiple octaves of noise directly from texture for better variety
	float3 noisePos1 = position * 0.001 + float3(0, 0, time * 0.05);
	float noise1 = noiseTexture.sample(noiseSampler, fract(noisePos1)).r;
	
	float3 noisePos2 = position * 0.005 + float3(0, time * 0.1, 0);
	float noise2 = noiseTexture.sample(noiseSampler, fract(noisePos2)).r;
	
	float3 noisePos3 = position * 0.02 + float3(time * 0.2, 0, 0);
	float noise3 = noiseTexture.sample(noiseSampler, fract(noisePos3)).r;
	
	float noise = noise1 * 0.5 + noise2 * 0.3 + noise3 * 0.2;
	noise = pow(noise, 1.5);
	
	float contrastBoost = mix(0.4, 1.2, noise);
	
	float verticalGradient = exp(-max(0.0, height) * 0.005);
	
	float distanceToCam = length(position - cameraPosition);
	float distanceFog = 1.0 - exp(-distanceToCam * 0.002);
	
	return heightDensity * contrastBoost * verticalGradient + distanceFog * 0.01;
}

//////////////////////////////////
// Phase Functions
//////////////////////////////////

float combinedPhaseFn(float cosTheta, float g, float godRayStrength) {
	float miePhase = cornetteShanksPhase(g, -cosTheta) * 3.0;
	
	float rayleighValue = rayleighPhase(cosTheta);
	
	float godRay = pow(max(0.0, cosTheta), 8.0) * godRayStrength * 3.0;
	
	return miePhase * 0.65 + rayleighValue * 0.35 + godRay;
}

//////////////////////////////////
// Volumetric Effects
//////////////////////////////////

kernel void fillVolumetricTexture(
	uint3 tid [[thread_position_in_grid]],
	constant VolumetricUniforms& uniforms [[buffer(0)]],
	constant float2& jitter [[buffer(1)]],
	texture3d<float, access::write> volumeTexture [[texture(0)]],
	texture2d<float> shadowMap [[texture(1)]],
	texture3d<float> noiseTexture [[texture(2)]],
	texture2d<float> depthTexture [[texture(3)]],
	sampler linearSampler [[sampler(0)]])
{
	if (tid.x >= volumeTexture.get_width() || tid.y >= volumeTexture.get_height() || tid.z >= volumeTexture.get_depth()) {
		return;
	}
	
	float3 texCoord = float3(
		(float(tid.x) + jitter.x) / volumeTexture.get_width(),
		(float(tid.y) + jitter.y) / volumeTexture.get_height(),
		float(tid.z) / volumeTexture.get_depth()
	);
	
	float linearDepth = texCoord.z;
	float exponentialDepth = pow(linearDepth, 4.0);
	
	float2 screenPos = texCoord.xy * 2.0 - 1.0;
	float4 clipPos = float4(screenPos, exponentialDepth * 2.0 - 1.0, 1.0);
	float4 worldPos4 = uniforms.inverseViewProjectionMatrix * clipPos;
	float3 worldPos = worldPos4.xyz / worldPos4.w;
	
	float density = sampleDensity(
		worldPos,
		uniforms.cameraPosition,
		uniforms.planetRadius,
		uniforms.atmosphereRadius,
		noiseTexture,
		linearSampler,
		uniforms.time
	) * uniforms.fogDensity;
	
	if (density < 0.0001) {
		volumeTexture.write(float4(0, 0, 0, density), tid);
		return;
	}
	
	float3 lightDir = uniforms.sunDirection;
	float3 viewDir = normalize(worldPos - uniforms.cameraPosition);
	float cosTheta = dot(viewDir, lightDir);
	
	// Anisotropy factor
	float g = 0.76;
	
	float shadow = sampleShadow(
		worldPos,
		uniforms.sunDirection,
		uniforms.planetRadius,
		shadowMap,
		linearSampler,
		uniforms.lightViewProjectionMatrix
	);
	
	float phase = combinedPhaseFn(cosTheta, g, uniforms.godRayStrength);
	
	float3 directScattering = uniforms.sunIlluminance * shadow * phase * density;
	
	float3 upVector = normalize(worldPos);
	float skyVisibility = 0.5 + 0.5 * dot(upVector, float3(0, 1, 0));
	float3 skyColor = mix(float3(0.1, 0.1, 0.2), float3(0.4, 0.6, 0.8), skyVisibility);
	float3 ambientScattering = skyColor * density * 0.2;
	
	float3 totalScattering = directScattering + ambientScattering;
	
	volumeTexture.write(float4(totalScattering, density), tid);
}

kernel void volumetricRaymarchCompute(
	uint2 tid [[thread_position_in_grid]],
	constant VolumetricUniforms& uniforms [[buffer(0)]],
	texture2d<float, access::sample> depthTexture [[texture(0)]],
	texture3d<float, access::sample> volumeTexture [[texture(1)]],
	texture2d<float, access::write> volumeLightTexture [[texture(2)]],
	texture2d<float, access::write> occlusionDepthTexture [[texture(3)]],
	sampler linearSampler [[sampler(0)]])
{
	float2 uv = float2(tid) / float2(uniforms.screenWidth, uniforms.screenHeight);
	float depth = depthTexture.sample(linearSampler, uv).r;
	
	// Skip sky pixels
	if (depth >= 1.0) {
		volumeLightTexture.write(float4(0, 0, 0, 0), tid);
		occlusionDepthTexture.write(float4(1.0), tid);
		return;
	}
	
	const int numSteps = 64;
	float3 accumLight = float3(0);
	float transmittance = 1.0;
	
	float3 rayStart = float3(uv, 0.0);
	float3 rayEnd = float3(uv, depth);
	
	for (int i = 0; i < numSteps; i++) {
		float t = float(i) / float(numSteps - 1);
		
		float exponentialT = pow(t, 1.0/4.0);
		
		float3 samplePos = mix(rayStart, rayEnd, exponentialT);
		
		float4 volumeSample = volumeTexture.sample(linearSampler, samplePos);
		
		float3 inscattering = volumeSample.rgb;
		float density = volumeSample.a;
		
		float3 contribution = inscattering * transmittance;
		
		float stepDistance = exponentialT * uniforms.atmosphereRadius;
		float decay = pow(uniforms.godRayDecay, stepDistance * 0.01);
		contribution *= decay;
		
		accumLight += contribution;
		
		transmittance *= exp(-density * 0.1);
		
		if (transmittance < 0.01) break;
	}
		
	volumeLightTexture.write(float4(accumLight, 1.0 - transmittance), tid);
	occlusionDepthTexture.write(float4(depth), tid);
}

// Temporal reprojection to reduce noise
kernel void temporalReprojection(
	uint2 tid [[thread_position_in_grid]],
	constant VolumetricUniforms& uniforms [[buffer(0)]],
	texture2d<float, access::read> currentFrame [[texture(0)]],
	texture2d<float, access::read> previousFrame [[texture(1)]],
	texture2d<float, access::read> depthTexture [[texture(2)]],
	texture2d<float, access::write> outputTexture [[texture(3)]])
{
	if (tid.x >= outputTexture.get_width() || tid.y >= outputTexture.get_height()) {
		return;
	}
	
	float4 currentColor = currentFrame.read(tid);
	
	float2 uv = float2(tid) / float2(uniforms.screenWidth, uniforms.screenHeight);
	
	float depth = depthTexture.read(tid).r;
	
	float3 worldPos = reconstructWorldPosition(uv, depth, uniforms.inverseViewProjectionMatrix);
	float4 previousPos = uniforms.previousViewProjectionMatrix * float4(worldPos, 1.0);
	previousPos /= previousPos.w;
	
	float2 previousUV = previousPos.xy * 0.5 + 0.5;
	
	if (previousUV.x >= 0.0 && previousUV.x <= 1.0 && previousUV.y >= 0.0 && previousUV.y <= 1.0) {
		uint2 previousTid = uint2(previousUV * float2(uniforms.screenWidth, uniforms.screenHeight));
		
		float4 previousColor = previousFrame.read(previousTid);
		
		float2 velocity = abs(previousUV - uv);
		float velocityMagnitude = length(velocity) * 10.0;
		float temporalWeight = max(0.1, min(0.9, 1.0 - velocityMagnitude));
		
		currentColor = mix(currentColor, previousColor, temporalWeight);
	}
	
	outputTexture.write(currentColor, tid);
}

fragment float4 volumetricBlendFragment(
	float4 position [[position]],
	float2 texCoord [[stage_in]],
	constant VolumetricUniforms& uniforms [[buffer(0)]],
	texture2d<float> volumeLightTexture [[texture(0)]],
	sampler textureSampler [[sampler(0)]])
{
	float4 volumetrics = volumeLightTexture.sample(textureSampler, texCoord);
	
	float3 glow = float3(0);
	float2 pixelSize = float2(1.0 / uniforms.screenWidth, 1.0 / uniforms.screenHeight);
	
	float3 sunDir = normalize(uniforms.sunDirection);
	float2 sunProjection = normalize(sunDir.xy);
	
	for (int i = -8; i <= 8; i++) {
		float2 offset = sunProjection * float(i) * pixelSize * 0.08;
		float4 sample = volumeLightTexture.sample(textureSampler, texCoord + offset);
		float weight = 1.0 - abs(float(i)) / 8.0;
		glow += sample.rgb * weight;
	}
	
	float3 viewDir = normalize(float3(texCoord * 2.0 - 1.0, 1.0));
	float sunCosAngle = dot(viewDir, sunDir);
	float sunGlow = pow(max(0.0, sunCosAngle), 32.0) * 4.0 * uniforms.godRayStrength;
	
	float3 finalColor = volumetrics.rgb + glow * 0.3 + float3(sunGlow) * uniforms.sunIlluminance * 0.2;
	
	finalColor = finalColor / (finalColor + 1.0);
	
	return float4(finalColor, volumetrics.a);
}

vertex float4 shadowDownsampleVertex(uint vertexID [[vertex_id]]) {
	float2 position;
	
	switch(vertexID) {
		case 0: position = float2(-1.0, -1.0); break;
		case 1: position = float2( 1.0, -1.0); break;
		case 2: position = float2( 1.0,  1.0); break;
		case 3: position = float2(-1.0, -1.0); break;
		case 4: position = float2( 1.0,  1.0); break;
		case 5: position = float2(-1.0,  1.0); break;
		default: position = float2(0.0, 0.0); break;
	}
	
	return float4(position, 0.0, 1.0);
}

fragment float shadowDownsampleFragment(
	float4 position [[position]],
	constant float& esmFactor [[buffer(0)]],
	texture2d<float> sourceTexture [[texture(0)]],
	sampler textureSampler [[sampler(0)]])
{
	float2 texCoord = float2(position.xy) / float2(256.0, 256.0);
	
	float depth = sourceTexture.sample(textureSampler, texCoord).r;
	
	float esmDepth = exp(esmFactor * depth);
	
	return esmDepth;
}
