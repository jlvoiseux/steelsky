import Metal
import MetalKit
import simd

class VolumetricLightingRenderer {
	private let device: MTLDevice
	private let library: MTLLibrary
	private var volumetricPipelineState: MTLRenderPipelineState!
	private var raymarchPipelineState: MTLComputePipelineState!
	private var fillVolumePipelineState: MTLComputePipelineState!
	private var shadowDownsamplePipelineState: MTLRenderPipelineState!
	private var temporalReprojectionPipelineState: MTLComputePipelineState!
	
	private var uniformBuffer: MTLBuffer!
	private var prevVolumetricLightTexture: MTLTexture!
	private var volumetricLightTexture: MTLTexture!
	private var occlusionDepthTexture: MTLTexture!
	private var temporalOutputTexture: MTLTexture!
	
	private var volumetricTexture: MTLTexture!
	private var prevVolumetricTexture: MTLTexture!
	private var fogShadowMap: MTLTexture!
	private var noiseTexture: MTLTexture!
	private var frameCount: UInt = 0
	
	private var commandQueue: MTLCommandQueue!
	
	private var linearSampler: MTLSamplerState!
	
	struct VolumetricUniforms {
		var viewMatrix: matrix_float4x4
		var projectionMatrix: matrix_float4x4
		var viewProjectionMatrix: matrix_float4x4
		var inverseViewProjectionMatrix: matrix_float4x4
		var previousViewProjectionMatrix: matrix_float4x4
		var lightViewProjectionMatrix: matrix_float4x4
		
		var cameraPosition: SIMD3<Float>
		var sunDirection: SIMD3<Float>
		var sunIlluminance: SIMD3<Float>
		
		var planetRadius: Float
		var atmosphereRadius: Float
		
		var fogDensity: Float
		var fogScatteringCoeff: Float
		var godRayStrength: Float
		var godRayDecay: Float
		
		var screenWidth: Float
		var screenHeight: Float
		var time: Float
		
		var padding: SIMD2<Float> = .zero
	}
	
	init(device: MTLDevice, library: MTLLibrary) {
		self.device = device
		self.library = library
		self.commandQueue = device.makeCommandQueue()!
		
		setupPipelines()
		setupResources()
		createSamplerState()
	}
	
	private func setupPipelines() {
		
		// Volumetric blending pipeline
		let volumetricDesc = MTLRenderPipelineDescriptor()
		volumetricDesc.label = "Volumetric Lighting Pipeline"
		volumetricDesc.vertexFunction = library.makeFunction(name: "skyFullscreenQuadVertex")
		volumetricDesc.fragmentFunction = library.makeFunction(name: "volumetricBlendFragment")
		volumetricDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
		volumetricDesc.colorAttachments[0].isBlendingEnabled = true
		volumetricDesc.colorAttachments[0].rgbBlendOperation = .add
		volumetricDesc.colorAttachments[0].alphaBlendOperation = .add
		volumetricDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
		volumetricDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
		volumetricDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
		volumetricDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
		volumetricDesc.depthAttachmentPixelFormat = .depth32Float
		
		// Raymarch compute pipeline
		let raymarchDesc = MTLComputePipelineDescriptor()
		raymarchDesc.label = "Volumetric Raymarching Pipeline"
		raymarchDesc.computeFunction = library.makeFunction(name: "volumetricRaymarchCompute")
		
		// Shadown downsampling pipeline
		let shadowDownsampleDesc = MTLRenderPipelineDescriptor()
		shadowDownsampleDesc.label = "Shadow Downsampling Pipeline"
		shadowDownsampleDesc.vertexFunction = library.makeFunction(name: "shadowDownsampleVertex")
		shadowDownsampleDesc.fragmentFunction = library.makeFunction(name: "shadowDownsampleFragment")
		shadowDownsampleDesc.colorAttachments[0].pixelFormat = .r32Float
		
		// Fill 3D texture pipeline
		let fillVolumeDesc = MTLComputePipelineDescriptor()
		fillVolumeDesc.label = "Fill Volumetric Texture Pipeline"
		fillVolumeDesc.computeFunction = library.makeFunction(name: "fillVolumetricTexture")
		
		// Temporal reprojection pipeline
		let temporalReprojectionDesc = MTLComputePipelineDescriptor()
		temporalReprojectionDesc.label = "Temporal Reprojection Pipeline"
		temporalReprojectionDesc.computeFunction = library.makeFunction(name: "temporalReprojection")
		
		do {
			volumetricPipelineState = try device.makeRenderPipelineState(descriptor: volumetricDesc)
			raymarchPipelineState = try device.makeComputePipelineState(descriptor: raymarchDesc, options: [], reflection: nil)
			shadowDownsamplePipelineState = try device.makeRenderPipelineState(descriptor: shadowDownsampleDesc)
			fillVolumePipelineState = try device.makeComputePipelineState(descriptor: fillVolumeDesc, options: [], reflection: nil)
			temporalReprojectionPipelineState = try device.makeComputePipelineState(descriptor: temporalReprojectionDesc, options: [], reflection: nil)
		} catch {
			fatalError("Failed to create volumetric lighting pipeline: \(error)")
		}
	}
	
	private func setupResources() {
		let uniformSize = MemoryLayout<VolumetricUniforms>.size
		uniformBuffer = device.makeBuffer(length: uniformSize, options: [.storageModeShared])
		
		updateParameters(
			fogDensity: 0.02,
			fogScatteringCoeff: 0.5,
			godRayStrength: 0.7,
			godRayDecay: 0.95
		)
		
		// 3D volumetric texture aligned with camera frustum
		let volumeTextureDesc = MTLTextureDescriptor()
		volumeTextureDesc.textureType = .type3D
		volumeTextureDesc.pixelFormat = .rgba16Float
		volumeTextureDesc.width = 160
		volumeTextureDesc.height = 90
		volumeTextureDesc.depth = 64
		volumeTextureDesc.mipmapLevelCount = 1
		volumeTextureDesc.usage = [.shaderRead, .shaderWrite]
		volumeTextureDesc.storageMode = .private
		volumetricTexture = device.makeTexture(descriptor: volumeTextureDesc)
		prevVolumetricTexture = device.makeTexture(descriptor: volumeTextureDesc)
		
		// Downsampled shadow map for fog
		let shadowMapDesc = MTLTextureDescriptor.texture2DDescriptor(
			pixelFormat: .r32Float,
			width: 256,
			height: 256,
			mipmapped: false
		)
		shadowMapDesc.usage = [.shaderRead, .renderTarget]
		fogShadowMap = device.makeTexture(descriptor: shadowMapDesc)
		
		createNoiseTexture()
		
		createOrUpdateTextures(width: 1, height: 1)
	}
	
	private func createNoiseTexture() {
		let noiseSize = 64
		let noiseTextureDesc = MTLTextureDescriptor()
		noiseTextureDesc.textureType = .type3D
		noiseTextureDesc.pixelFormat = .r8Unorm
		noiseTextureDesc.width = noiseSize
		noiseTextureDesc.height = noiseSize
		noiseTextureDesc.depth = noiseSize
		noiseTextureDesc.mipmapLevelCount = 5
		noiseTextureDesc.usage = [.shaderRead]
		noiseTexture = device.makeTexture(descriptor: noiseTextureDesc)
		
		var noiseData = [UInt8](repeating: 0, count: noiseSize * noiseSize * noiseSize)
		
		// Generate gradient vectors for Perlin noise
		let gradients = generatePerlinGradients(size: 17) // 16+1 for seamless wrapping
		
		for z in 0..<noiseSize {
			for y in 0..<noiseSize {
				for x in 0..<noiseSize {
					let fx = Float(x) / Float(noiseSize)
					let fy = Float(y) / Float(noiseSize)
					let fz = Float(z) / Float(noiseSize)
					
					let noise = perlinNoise3D(x: fx * 4.0, y: fy * 4.0, z: fz * 4.0, gradients: gradients) * 0.5 + 0.5
					let smoothedNoise = smoothstep(noise)
					
					noiseData[z * noiseSize * noiseSize + y * noiseSize + x] = UInt8(smoothedNoise * 255)
				}
			}
		}
		
		let region = MTLRegion(
			origin: MTLOrigin(x: 0, y: 0, z: 0),
			size: MTLSize(width: noiseSize, height: noiseSize, depth: noiseSize)
		)
		noiseTexture.replace(
			region: region,
			mipmapLevel: 0,
			slice: 0,
			withBytes: &noiseData,
			bytesPerRow: noiseSize,
			bytesPerImage: noiseSize * noiseSize
		)
		
		let commandBuffer = commandQueue.makeCommandBuffer()!
		let blitEncoder = commandBuffer.makeBlitCommandEncoder()!
		blitEncoder.generateMipmaps(for: noiseTexture)
		blitEncoder.endEncoding()
		commandBuffer.commit()
	}
	
	private func createSamplerState() {
		let samplerDescriptor = MTLSamplerDescriptor()
		samplerDescriptor.minFilter = .linear
		samplerDescriptor.magFilter = .linear
		samplerDescriptor.mipFilter = .linear
		samplerDescriptor.normalizedCoordinates = true
		samplerDescriptor.sAddressMode = .clampToEdge
		samplerDescriptor.tAddressMode = .clampToEdge
		
		linearSampler = device.makeSamplerState(descriptor: samplerDescriptor)
	}
	
	private func createOrUpdateTextures(width: Int, height: Int) {
		let lightTextureDesc = MTLTextureDescriptor.texture2DDescriptor(
			pixelFormat: .rgba16Float,
			width: width,
			height: height,
			mipmapped: false
		)
		lightTextureDesc.usage = [.shaderRead, .shaderWrite]
		lightTextureDesc.storageMode = .private
		
		let depthTextureDesc = MTLTextureDescriptor.texture2DDescriptor(
			pixelFormat: .r32Float,
			width: width,
			height: height,
			mipmapped: false
		)
		depthTextureDesc.usage = [.shaderRead, .shaderWrite]
		depthTextureDesc.storageMode = .private
		
		// Only create new textures if they don't exist or if the size changed
		if volumetricLightTexture == nil ||
		   volumetricLightTexture.width != width ||
		   volumetricLightTexture.height != height {
			prevVolumetricLightTexture = device.makeTexture(descriptor: lightTextureDesc)
			volumetricLightTexture = device.makeTexture(descriptor: lightTextureDesc)
			occlusionDepthTexture = device.makeTexture(descriptor: depthTextureDesc)
		}
		
		if temporalOutputTexture == nil ||
		   temporalOutputTexture.width != width ||
		   temporalOutputTexture.height != height {
			temporalOutputTexture = device.makeTexture(descriptor: lightTextureDesc)
		}
	}
	
	func updateParameters(
		fogDensity: Float,
		fogScatteringCoeff: Float,
		godRayStrength: Float,
		godRayDecay: Float
	) {
		guard let contents = uniformBuffer?.contents() else { return }
		
		let uniforms = contents.bindMemory(to: VolumetricUniforms.self, capacity: 1)
		uniforms.pointee.fogDensity = fogDensity
		uniforms.pointee.fogScatteringCoeff = fogScatteringCoeff
		uniforms.pointee.godRayStrength = godRayStrength
		uniforms.pointee.godRayDecay = godRayDecay
	}
	
	func updateMatrices(
		viewMatrix: matrix_float4x4,
		projectionMatrix: matrix_float4x4,
		lightViewProjectionMatrix: matrix_float4x4,
		cameraPosition: SIMD3<Float>,
		sunDirection: SIMD3<Float>,
		sunIlluminance: SIMD3<Float>,
		planetRadius: Float,
		atmosphereRadius: Float,
		screenWidth: Float,
		screenHeight: Float
	) {
		guard let contents = uniformBuffer?.contents() else { return }
		
		let viewProjectionMatrix = matrix_multiply(projectionMatrix, viewMatrix)
		let inverseViewProjectionMatrix = viewProjectionMatrix.inverse
		
		// Store previous view-projection matrix for temporal effects
		let previousViewProjectionMatrix = (contents.bindMemory(to: VolumetricUniforms.self, capacity: 1)).pointee.viewProjectionMatrix
		
		var uniforms = VolumetricUniforms(
			viewMatrix: viewMatrix,
			projectionMatrix: projectionMatrix,
			viewProjectionMatrix: viewProjectionMatrix,
			inverseViewProjectionMatrix: inverseViewProjectionMatrix,
			previousViewProjectionMatrix: previousViewProjectionMatrix,
			lightViewProjectionMatrix: lightViewProjectionMatrix,
			
			cameraPosition: cameraPosition,
			sunDirection: sunDirection,
			sunIlluminance: sunIlluminance,
			
			planetRadius: planetRadius,
			atmosphereRadius: atmosphereRadius,
			
			fogDensity: (contents.bindMemory(to: VolumetricUniforms.self, capacity: 1)).pointee.fogDensity,
			fogScatteringCoeff: (contents.bindMemory(to: VolumetricUniforms.self, capacity: 1)).pointee.fogScatteringCoeff,
			godRayStrength: (contents.bindMemory(to: VolumetricUniforms.self, capacity: 1)).pointee.godRayStrength,
			godRayDecay: (contents.bindMemory(to: VolumetricUniforms.self, capacity: 1)).pointee.godRayDecay,
			
			screenWidth: screenWidth,
			screenHeight: screenHeight,
			time: Float(CACurrentMediaTime())
		)
		
		memcpy(contents, &uniforms, MemoryLayout<VolumetricUniforms>.size)
		
		createOrUpdateTextures(width: Int(screenWidth), height: Int(screenHeight))
	}
	
	func renderVolumetrics(
		commandBuffer: MTLCommandBuffer,
		colorTexture: MTLTexture,
		depthTexture: MTLTexture,
		shadowTexture: MTLTexture,
		renderPassDescriptor: MTLRenderPassDescriptor
	) {
		frameCount += 1
		
		// Step 1: Downsample shadow map
		downsampleShadowMap(commandBuffer: commandBuffer, sourceTexture: shadowTexture)
		
		// Step 2: Fill volumetric texture with density and lighting
		fillVolumetricTexture(commandBuffer: commandBuffer, depthTexture: depthTexture)
		
		// Step 3: Raymarch through volume to accumulate scattering
		generateVolumetricLightTexture(commandBuffer: commandBuffer, depthTexture: depthTexture)
		
		// Step 4: Apply temporal reprojection if needed
		if frameCount > 1 {
			applyTemporalReprojection(commandBuffer: commandBuffer)
		}
		
		// Step 5: Apply to screen
		applyVolumetricLighting(commandBuffer: commandBuffer, renderPassDescriptor: renderPassDescriptor)
		
		// Swap current and previous textures for next frame
		swap(&volumetricLightTexture, &prevVolumetricLightTexture)
		swap(&volumetricTexture, &prevVolumetricTexture)
	}
	
	private func downsampleShadowMap(commandBuffer: MTLCommandBuffer, sourceTexture: MTLTexture) {
		let descriptor = MTLRenderPassDescriptor()
		descriptor.colorAttachments[0].texture = fogShadowMap
		descriptor.colorAttachments[0].loadAction = .clear
		descriptor.colorAttachments[0].storeAction = .store
		descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)

		guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
		encoder.label = "Shadow Map Downsampling"
		
		encoder.setRenderPipelineState(shadowDownsamplePipelineState)
		
		encoder.setFragmentTexture(sourceTexture, index: 0)
		encoder.setFragmentSamplerState(linearSampler, index: 0)
		var esmFactor: Float = 80.0
		let paramBuffer = device.makeBuffer(bytes: &esmFactor, length: MemoryLayout<Float>.size, options: [])
		encoder.setFragmentBuffer(paramBuffer, offset: 0, index: 0)
		encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
		encoder.endEncoding()
	}
	
	private func fillVolumetricTexture(commandBuffer: MTLCommandBuffer, depthTexture: MTLTexture) {
		guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else { return }
		computeEncoder.label = "Fill Volumetric Texture"
		
		computeEncoder.setComputePipelineState(fillVolumePipelineState)
		
		computeEncoder.setBuffer(uniformBuffer, offset: 0, index: 0)
		computeEncoder.setTexture(volumetricTexture, index: 0)
		computeEncoder.setTexture(fogShadowMap, index: 1)
		computeEncoder.setTexture(noiseTexture, index: 2)
		computeEncoder.setTexture(depthTexture, index: 3)
		computeEncoder.setSamplerState(linearSampler, index: 0)
		
		// Apply jittering for temporal sampling
		var jitter = SIMD2<Float>(
			Float(frameCount % 8) / 8.0,
			Float((frameCount / 8) % 8) / 8.0
		)
		let jitterBuffer = device.makeBuffer(bytes: &jitter, length: MemoryLayout<SIMD2<Float>>.size, options: [])
		computeEncoder.setBuffer(jitterBuffer, offset: 0, index: 1)
		
		let threadgroupSize = MTLSize(width: 8, height: 8, depth: 4)
		let threadgroupCount = MTLSize(
			width: (volumetricTexture.width + threadgroupSize.width - 1) / threadgroupSize.width,
			height: (volumetricTexture.height + threadgroupSize.height - 1) / threadgroupSize.height,
			depth: (volumetricTexture.depth + threadgroupSize.depth - 1) / threadgroupSize.depth
		)
		
		computeEncoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
		computeEncoder.endEncoding()
	}
	
	private func generateVolumetricLightTexture(commandBuffer: MTLCommandBuffer, depthTexture: MTLTexture) {
		guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else { return }
		computeEncoder.label = "Volumetric Light Generation"
		
		computeEncoder.setComputePipelineState(raymarchPipelineState)
		computeEncoder.setBuffer(uniformBuffer, offset: 0, index: 0)
		computeEncoder.setTexture(depthTexture, index: 0)
		computeEncoder.setTexture(volumetricTexture, index: 1)
		computeEncoder.setTexture(volumetricLightTexture, index: 2)
		computeEncoder.setTexture(occlusionDepthTexture, index: 3)
		computeEncoder.setSamplerState(linearSampler, index: 0)
		
		let threadgroupSize = MTLSize(width: 8, height: 8, depth: 1)
		let threadgroupCount = MTLSize(
			width: (volumetricLightTexture.width + threadgroupSize.width - 1) / threadgroupSize.width,
			height: (volumetricLightTexture.height + threadgroupSize.height - 1) / threadgroupSize.height,
			depth: 1
		)
		
		computeEncoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
		computeEncoder.endEncoding()
	}
	
	private func applyTemporalReprojection(commandBuffer: MTLCommandBuffer) {
		guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else { return }
		computeEncoder.label = "Temporal Reprojection"
		
		computeEncoder.setComputePipelineState(temporalReprojectionPipelineState)
		// Set resources
		computeEncoder.setBuffer(uniformBuffer, offset: 0, index: 0)
		
		computeEncoder.setTexture(volumetricLightTexture, index: 0)  // Current frame
		computeEncoder.setTexture(prevVolumetricLightTexture, index: 1)  // Previous frame
		computeEncoder.setTexture(occlusionDepthTexture, index: 2)  // Depth texture
		computeEncoder.setTexture(temporalOutputTexture, index: 3)  // Output texture
		
		let threadgroupSize = MTLSize(width: 8, height: 8, depth: 1)
		let threadgroupCount = MTLSize(
			width: (volumetricLightTexture.width + threadgroupSize.width - 1) / threadgroupSize.width,
			height: (volumetricLightTexture.height + threadgroupSize.height - 1) / threadgroupSize.height,
			depth: 1
		)
		
		computeEncoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
		computeEncoder.endEncoding()
		
		// After temporal reprojection, copy result back to volumetricLightTexture
		let blitEncoder = commandBuffer.makeBlitCommandEncoder()!
		blitEncoder.copy(from: temporalOutputTexture,
			 sourceSlice: 0,
			 sourceLevel: 0,
			 sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
			 sourceSize: MTLSize(width: temporalOutputTexture.width,
								height: temporalOutputTexture.height,
								depth: 1),
			 to: volumetricLightTexture,
			 destinationSlice: 0,
			 destinationLevel: 0,
			 destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
		blitEncoder.endEncoding()
	}
	
	private func applyVolumetricLighting(commandBuffer: MTLCommandBuffer, renderPassDescriptor: MTLRenderPassDescriptor) {
		guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
		renderEncoder.label = "Volumetric Lighting Blending"
		
		renderEncoder.setRenderPipelineState(volumetricPipelineState)
		renderEncoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
		renderEncoder.setFragmentTexture(volumetricLightTexture, index: 0)
		renderEncoder.setFragmentSamplerState(linearSampler, index: 0)
		
		renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
		renderEncoder.endEncoding()
	}
	
	func getVolumetricLightTexture() -> MTLTexture {
		return volumetricLightTexture
	}
}
