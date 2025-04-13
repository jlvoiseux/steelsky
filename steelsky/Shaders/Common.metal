#include <metal_stdlib>

using namespace metal;
#include "Common.h"

//////////////////////////////////
// Ray Utilities Implementation
//////////////////////////////////

Ray createRay(float3 origin, float3 direction) {
	Ray ray;
	ray.origin = origin;
	ray.direction = direction;
	return ray;
}

bool raySphereIntersect(Ray ray, float3 sphereCenter, float sphereRadius, thread float& t0, thread float& t1) {
	float3 oc = ray.origin - sphereCenter;
	float a = dot(ray.direction, ray.direction);
	float b = 2.0 * dot(oc, ray.direction);
	float c = dot(oc, oc) - sphereRadius * sphereRadius;
	float discriminant = b * b - 4 * a * c;
	
	if (discriminant < 0) {
		return false;
	} else {
		float sqrtDiscriminant = sqrt(discriminant);
		t0 = (-b - sqrtDiscriminant) / (2.0 * a);
		t1 = (-b + sqrtDiscriminant) / (2.0 * a);
		return true;
	}
}

float raySphereIntersectNearest(Ray ray, float3 sphereCenter, float sphereRadius) {
	float3 oc = ray.origin - sphereCenter;
	float a = dot(ray.direction, ray.direction);
	float b = 2.0 * dot(oc, ray.direction);
	float c = dot(oc, oc) - (sphereRadius * sphereRadius);
	float delta = b * b - 4.0*a*c;
	
	if (delta < 0.0 || a == 0.0) {
		return -1.0;
	}
	
	float sol0 = (-b - sqrt(delta)) / (2.0*a);
	float sol1 = (-b + sqrt(delta)) / (2.0*a);
	
	if (sol0 < 0.0 && sol1 < 0.0) {
		return -1.0;
	}
	
	if (sol0 < 0.0) {
		return max(0.0, sol1);
	} else if (sol1 < 0.0) {
		return max(0.0, sol0);
	}
	
	return max(0.0, min(sol0, sol1));
}

//////////////////////////////////
// Shadow Sampling
//////////////////////////////////

float sampleShadow(float3 position, float3 lightDir, float planetRadius,
				  texture2d<float> shadowMap, sampler shadowSampler, float4x4 lightViewProj) {
	// Check for planet shadow with softer falloff
	Ray shadowRay = createRay(position, lightDir);
	float t0, t1;
	if (raySphereIntersect(shadowRay, float3(0, 0, 0), planetRadius, t0, t1)) {
		if (t0 > 0 && t0 < 100.0) {
			// Softer planet shadow transition
			return 0.05;
		}
	}

	// Improved shadow map sampling
	float4 lightSpacePos = lightViewProj * float4(position, 1.0);
	lightSpacePos /= lightSpacePos.w;
	
	// Convert to 0-1 UV space
	float2 shadowUV = lightSpacePos.xy * 0.5 + 0.5;
	
	// Check if position is in shadow map bounds
	if (shadowUV.x >= 0.0 && shadowUV.x <= 1.0 && shadowUV.y >= 0.0 && shadowUV.y <= 1.0) {
		// Improved soft shadow with PCF filtering
		float shadow = 0.0;
		float currentDepth = lightSpacePos.z;
		float bias = 0.001;
		
		// Use percentage-closer filtering with multiple samples
		float2 texelSize = float2(1.0) / float2(shadowMap.get_width(), shadowMap.get_height());
		for(int x = -1; x <= 1; ++x) {
			for(int y = -1; y <= 1; ++y) {
				float pcfDepth = shadowMap.sample(shadowSampler, shadowUV + float2(x, y) * texelSize).r;
				shadow += exp(ESM_FACTOR * (pcfDepth - (currentDepth - bias)));
			}
		}
		shadow /= 9.0;
		
		return min(shadow, 1.0);
	}
	
	return 1.0;
}

//////////////////////////////////
// Phase Functions
//////////////////////////////////

float rayleighPhase(float cosTheta) {
	float factor = 3.0f / (16.0f * PI);
	return factor * (1.0f + cosTheta * cosTheta);
}

float cornetteShanksPhase(float g, float cosTheta) {
	float k = 3.0 / (8.0 * PI) * (1.0 - g * g) / (2.0 + g * g);
	return k * (1.0 + cosTheta * cosTheta) / pow(1.0 + g * g - 2.0 * g * -cosTheta, 1.5);
}

float dualLobPhase(float g0, float g1, float w, float cosTheta) {
	return mix(cornetteShanksPhase(g0, cosTheta), cornetteShanksPhase(g1, cosTheta), w);
}

float uniformPhase() {
	return 1.0f / (4.0f * PI);
}

//////////////////////////////////
// Utility Math Functions
//////////////////////////////////

float mean(float3 v) {
	return dot(v, float3(1.0f / 3.0f, 1.0f / 3.0f, 1.0f / 3.0f));
}

float3 mix(float3 a, float3 b, float t) {
	return a + (b - a) * t;
}
