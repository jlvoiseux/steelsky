#include <metal_stdlib>
#include "Common.h"

using namespace metal;

struct Vertex {
	float3 position [[attribute(0)]];
	float3 normal [[attribute(1)]];
	float2 texCoord [[attribute(2)]];
};

struct VertexOut {
	float4 position [[position]];
	float3 worldPosition;
	float3 normal;
	float2 texCoord;
};

struct Uniforms {
	float4x4 modelMatrix;
	float4x4 viewMatrix;
	float4x4 projectionMatrix;
	float4x4 lightViewProjectionMatrix;
	float3 cameraPosition;
	float3 sunDirection;
	float3 sunIlluminance;
	float bottomRadius;
	float topRadius;
};

struct Material {
	float3 ambientColor;
	float3 diffuseColor;
	float3 specularColor;
	float specularExponent;
	float opacity;
	bool hasTexture;
};

vertex VertexOut sceneVertex(uint vertexID [[vertex_id]],
							constant Vertex *vertices [[buffer(0)]],
							constant Uniforms &uniforms [[buffer(1)]]) {
	VertexOut out;
	
	float3 position = vertices[vertexID].position;
	float4x4 mvpMatrix = uniforms.projectionMatrix * uniforms.viewMatrix * uniforms.modelMatrix;
	float3x3 normalMatrix = float3x3(uniforms.modelMatrix.columns[0].xyz,
									 uniforms.modelMatrix.columns[1].xyz,
									 uniforms.modelMatrix.columns[2].xyz);
	
	out.normal = normalize(normalMatrix * vertices[vertexID].normal);
	out.texCoord = vertices[vertexID].texCoord;
	out.position = mvpMatrix * float4(position, 1.0);
	out.worldPosition = (uniforms.modelMatrix * float4(position, 1.0)).xyz;
	
	return out;
}

fragment float4 sceneFragment(VertexOut in [[stage_in]],
						  constant Material &material [[buffer(0)]],
						  constant Uniforms &uniforms [[buffer(1)]],
						  texture2d<float> diffuseTexture [[texture(0)]],
						  texture2d<float> shadowMap [[texture(1)]], // Add shadow map
						  texture2d<float> transmittanceLUT [[texture(2)]],
						  texture2d<float> multiScatteringLUT [[texture(3)]],
						  sampler textureSampler [[sampler(0)]],
						  sampler shadowSampler [[sampler(1)]]) {
	
	float3 normal = normalize(in.normal);
	float3 lightDirection = normalize(uniforms.sunDirection);
	float3 viewDirection = normalize(uniforms.cameraPosition - in.worldPosition);
	
	float3 positionRelativeToPlanet = in.worldPosition;
	float height = length(positionRelativeToPlanet);
	float3 upVector = positionRelativeToPlanet / height;
	
	float edgeFactor = pow(abs(dot(normal, viewDirection)), 0.5);
	
	float NdotL = dot(upVector, lightDirection);
	float earthShadow = smoothstep(-0.1, 0.1, NdotL);
	
	float sunZenithCosAngle = NdotL;
	float sunHeight = lightDirection.y;
	
	// Calculate atmospheric transmittance
	float3 transmittanceToSun;
	if (sunHeight > 0.7) {
		// At noon, use white light with minimal atmospheric extinction
		transmittanceToSun = float3(1.0, 1.0, 1.0) * (0.9 + 0.1 * sunZenithCosAngle);
	} else if (sunHeight < 0.0) {
		// Night side gets darker but never completely black
		transmittanceToSun = float3(0.05, 0.05, 0.1);
	} else {
		// Dawn/dusk transition - simplified atmospheric scattering
		float t = sunHeight / 0.7;
		
		float scatterStrength = 1.0 - t;
		float3 rayleighAttenuation = exp(-float3(0.2, 0.5, 1.0) * scatterStrength);
		float3 sunsetColors = float3(1.0, 0.6, 0.3) * (1.0 - t);
		transmittanceToSun = mix(rayleighAttenuation + sunsetColors, float3(1.0), t);
	}
	
	float3 skyColorDay = float3(0.4, 0.6, 0.8);
	float3 skyColorNight = float3(0.02, 0.02, 0.04);
	
	float dayWeight = smoothstep(-0.1, 0.1, sunHeight);
	float3 skyColor = mix(skyColorNight, skyColorDay, dayWeight);
	
	float hemiWeight = 0.5 + 0.5 * dot(normal, upVector);
	float skyDomeWeight = 0.5 + 0.5 * (1.0 - abs(dot(normal, upVector)));
	float constAmbient = 0.1;
	
	// Add rim lighting for untextured models
	float rimFactor = 1.0 - max(0.0, dot(normal, viewDirection));
	rimFactor = smoothstep(0.3, 0.7, rimFactor) * 0.3;
	
	float3 hemiAmbient = mix(material.ambientColor * 0.2, material.ambientColor, hemiWeight);
	float3 skyAmbient = skyColor * skyDomeWeight;
	float3 ambient = (hemiAmbient + skyAmbient) * (dayWeight * 0.8 + 0.2) + constAmbient * skyColor;
	
	float wrapFactor = material.hasTexture ? 0.3 : 0.45;
	float diffuseFactor = max(0.0, (dot(normal, lightDirection) + wrapFactor) / (1.0 + wrapFactor));
	diffuseFactor *= earthShadow;
	
	float shadowFactor = sampleShadow(
		in.worldPosition,
		uniforms.sunDirection,
		uniforms.bottomRadius,
		shadowMap,
		shadowSampler,
		uniforms.lightViewProjectionMatrix
	);
	
	if (!material.hasTexture) {
		shadowFactor = mix(0.3, 1.0, shadowFactor);
	}
	diffuseFactor *= shadowFactor;
	
	float3 diffuse;
	if (material.hasTexture) {
		float4 textureColor = diffuseTexture.sample(textureSampler, in.texCoord);
		float3 moderatedSunColor = mix(float3(1.0, 1.0, 1.0), transmittanceToSun, 0.6);
		diffuse = textureColor.rgb * diffuseFactor * uniforms.sunIlluminance * moderatedSunColor;
	} else {
		float3 moderatedSunColor = mix(float3(1.0, 1.0, 1.0), transmittanceToSun, 0.6);
		float3 enhancedDiffuseColor = material.diffuseColor;
		enhancedDiffuseColor += normal.y * 0.05;
		diffuse = enhancedDiffuseColor * diffuseFactor * uniforms.sunIlluminance * moderatedSunColor;
	}
	
	float roughness = material.hasTexture ? 0.3 : 0.5;
	float3 halfVector = normalize(lightDirection + viewDirection);
	float NdotH = max(0.0, dot(normal, halfVector));
	float specularFactor = pow(NdotH, (1.0/roughness) * material.specularExponent) * diffuseFactor;
	specularFactor *= (material.specularExponent + 8.0) / 25.1327; // Energy conservation factor
	float3 moderatedSpecularColor = mix(float3(1.0, 1.0, 1.0), transmittanceToSun, 0.5);
	float3 specular = material.specularColor * specularFactor * moderatedSpecularColor;
	
	float3 fresnel = float3(0);
	if (!material.hasTexture) {
		fresnel = material.specularColor * pow(1.0 - max(0.0, dot(normal, viewDirection)), 5.0) * 0.2;
	}
	
	float3 rim = float3(0);
	if (!material.hasTexture) {
		rim = material.diffuseColor * rimFactor * uniforms.sunIlluminance * 0.2;
	}
	
	float3 finalColor = ambient + diffuse + specular + rim + fresnel;
	
	if (!material.hasTexture) {
		finalColor *= mix(0.9, 1.0, edgeFactor);
	}
	
	// Atmosphere fog with height-based density
	float fogDensity = 0.00015 * exp(-max(0.0, height - uniforms.bottomRadius) * 0.0001);
	float distanceToCamera = length(in.worldPosition - uniforms.cameraPosition);
	float fogFactor = 1.0 - exp(-distanceToCamera * fogDensity);
	float3 fogColor = skyColor;
	finalColor = mix(finalColor, fogColor, fogFactor);
	
	float tonemapExposure = material.hasTexture ? 0.9 : 0.8;
	finalColor = finalColor / (finalColor + tonemapExposure);
	
	return float4(finalColor, material.opacity);
}

fragment void depthOnlyFragment(VertexOut in [[stage_in]]) {
	// This function intentionally does nothing - we only care about depth
}

fragment float4 compositeFragment(VertexOut in [[stage_in]],
								 texture2d<float> colorTexture [[texture(0)]],
								 texture2d<float> volumeLightTexture [[texture(1)]],
								 sampler textureSampler [[sampler(0)]]) {
	
	float2 flippedUV = float2(in.texCoord.x, 1.0 - in.texCoord.y);
	
	float4 sceneColor = colorTexture.sample(textureSampler, flippedUV);
	float4 volumeLighting = volumeLightTexture.sample(textureSampler, flippedUV);
	
	float3 finalColor = sceneColor.rgb + volumeLighting.rgb;
	
	return float4(finalColor, 1.0);
}
