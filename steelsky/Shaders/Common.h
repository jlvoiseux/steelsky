#pragma once

#include <metal_stdlib>

using namespace metal;

//////////////////////////////////
// Constants
//////////////////////////////////
constant float PI = 3.14159265359;
constant float ESM_FACTOR = 100.0;

//////////////////////////////////
// Common Structures
//////////////////////////////////
struct Ray {
	float3 origin;
	float3 direction;
};

//////////////////////////////////
// Ray Utilities
//////////////////////////////////
Ray createRay(float3 origin, float3 direction);
bool raySphereIntersect(Ray ray, float3 sphereCenter, float sphereRadius, thread float& t0, thread float& t1);
float raySphereIntersectNearest(Ray ray, float3 sphereCenter, float sphereRadius);

//////////////////////////////////
// Lighting Utilities
//////////////////////////////////
float sampleShadow(float3 position, float3 lightDir, float planetRadius,
				   texture2d<float> shadowMap, sampler shadowSampler, float4x4 lightViewProj);

//////////////////////////////////
// Phase Functions
//////////////////////////////////
float rayleighPhase(float cosTheta);
float cornetteShanksPhase(float g, float cosTheta);
float dualLobPhase(float g0, float g1, float w, float cosTheta);
float uniformPhase();

//////////////////////////////////
// Math Utilities
//////////////////////////////////
float3 mix(float3 a, float3 b, float t);
float mean(float3 v);
