import Foundation
import Metal
import MetalKit
import simd

struct AtmosphereParameters {
	// Planet parameters
	var bottomRadius: Float
	var topRadius: Float
	
	var rayleighDensityExpScale: Float
	var rayleighScattering: SIMD3<Float>
	
	var mieDensityExpScale: Float
	var mieScattering: SIMD3<Float>
	var mieExtinction: SIMD3<Float>
	var mieAbsorption: SIMD3<Float>
	var miePhaseG: Float
	
	// Absorption (ozone) parameters
	var absorptionDensity0LayerWidth: Float
	var absorptionDensity0ConstantTerm: Float
	var absorptionDensity0LinearTerm: Float
	var absorptionDensity1ConstantTerm: Float
	var absorptionDensity1LinearTerm: Float
	var absorptionExtinction: SIMD3<Float>
	
	var groundAlbedo: SIMD3<Float>
	
	static func earthAtmosphere() -> AtmosphereParameters {
		return AtmosphereParameters(
			bottomRadius: 6360.0,
			topRadius: 6460.0,
			
			rayleighDensityExpScale: -1.0 / 8.0,
			rayleighScattering: SIMD3<Float>(5.802, 13.558, 33.1) * 1e-3,
			
			mieDensityExpScale: -1.0 / 1.2,
			mieScattering: SIMD3<Float>(3.996, 3.996, 3.996) * 1e-3,
			mieExtinction: SIMD3<Float>(4.4, 4.4, 4.4) * 1e-3,
			mieAbsorption: SIMD3<Float>(0.4, 0.4, 0.4) * 1e-3,
			miePhaseG: 0.8,
			
			absorptionDensity0LayerWidth: 25.0,
			absorptionDensity0ConstantTerm: 0.0,
			absorptionDensity0LinearTerm: 1.0 / 15.0,
			absorptionDensity1ConstantTerm: -2.0 / 3.0,
			absorptionDensity1LinearTerm: -1.0 / 15.0,
			absorptionExtinction: SIMD3<Float>(0.650, 1.881, 0.085) * 1e-6,
			
			groundAlbedo: SIMD3<Float>(0.3, 0.3, 0.3)
		)
	}
	
	static func marsAtmosphere() -> AtmosphereParameters {
		var params = earthAtmosphere()
		params.rayleighScattering = SIMD3<Float>(20.0, 5.0, 2.0) * 1e-3
		params.groundAlbedo = SIMD3<Float>(0.5, 0.2, 0.1)
		return params
	}
}

struct AtmosphereLUTSizes {
	var transmittanceWidth: Int = 256
	var transmittanceHeight: Int = 128
	
	var multiScatteringRes: Int = 64
	
	var skyViewWidth: Int = 256
	var skyViewHeight: Int = 144
	
	var aerialPerspectiveDepth: Int = 32
	var aerialPerspectiveWidth: Int = 32
	var aerialPerspectiveHeight: Int = 32
}

struct AtmosphereUniforms {
	// Planet and atmosphere properties
	var bottomRadius: Float
	var topRadius: Float
	
	var rayleighDensityExpScale: Float
	var rayleighScattering: SIMD3<Float>
	
	var mieDensityExpScale: Float
	var mieScattering: SIMD3<Float>
	var mieExtinction: SIMD3<Float>
	var mieAbsorption: SIMD3<Float>
	var miePhaseG: Float
	
	var absorptionDensity0LayerWidth: Float
	var absorptionDensity0ConstantTerm: Float
	var absorptionDensity0LinearTerm: Float
	var absorptionDensity1ConstantTerm: Float
	var absorptionDensity1LinearTerm: Float
	var absorptionExtinction: SIMD3<Float>
	
	var groundAlbedo: SIMD3<Float>
	
	var viewMatrix: matrix_float4x4
	var projectionMatrix: matrix_float4x4
	var viewProjectionMatrix: matrix_float4x4
	var inverseViewProjectionMatrix: matrix_float4x4
	var inverseViewMatrix: matrix_float4x4
	var inverseProjectionMatrix: matrix_float4x4
	
	var cameraPosition: SIMD3<Float>
	var sunDirection: SIMD3<Float>
	var sunIlluminance: SIMD3<Float>
	
	var multiScatteringLUTRes: Float
	var multipleScatteringFactor: Float
	
	var padding: SIMD2<Float> = SIMD2<Float>(0, 0)
}


class SkyAtmosphereRenderer {
	private let device: MTLDevice
	private let library: MTLLibrary
	private var commandQueue: MTLCommandQueue
	
	private var transmittanceLutPipeline: MTLRenderPipelineState!
	private var multiScatteringLutPipeline: MTLComputePipelineState!
	private var skyViewLutPipeline: MTLRenderPipelineState!
	private var skyRenderingPipeline: MTLRenderPipelineState!
	
	private let lutSizes = AtmosphereLUTSizes()
	private var atmosphereUniformBuffer: MTLBuffer!

	private var currentTransmittanceLUT: MTLTexture!
	private var nextTransmittanceLUT: MTLTexture!
	private var currentMultiScatteringLUT: MTLTexture!
	private var nextMultiScatteringLUT: MTLTexture!
	private var currentSkyViewLUT: MTLTexture!
	private var nextSkyViewLUT: MTLTexture!
	
	private var isGeneratingLUTs = false
	private var lutSemaphore = DispatchSemaphore(value: 1)
	
	private var atmosphereParams = AtmosphereParameters.earthAtmosphere()
	private var sunIlluminance = SIMD3<Float>(1.0, 1.0, 1.0)
	private var sunDirection = SIMD3<Float>(0.0, 0.2, -1.0)
	
	private var linearSampler: MTLSamplerState!
	
	init(device: MTLDevice, library: MTLLibrary) {
		self.device = device
		self.library = library
		self.commandQueue = device.makeCommandQueue()!
		
		setupPipelines()
		setupResources()
		createSamplerState()
	}
	
	private func setupResources() {
		let uniformSize = MemoryLayout<AtmosphereUniforms>.size
		atmosphereUniformBuffer = device.makeBuffer(length: uniformSize, options: [.storageModeShared])
		
		let transmittanceDesc = MTLTextureDescriptor.texture2DDescriptor(
			pixelFormat: .rgba16Float,
			width: lutSizes.transmittanceWidth,
			height: lutSizes.transmittanceHeight,
			mipmapped: false)
		transmittanceDesc.usage = [.shaderRead, .renderTarget]
		currentTransmittanceLUT = device.makeTexture(descriptor: transmittanceDesc)
		nextTransmittanceLUT = device.makeTexture(descriptor: transmittanceDesc)
		
		let multiScatteringDesc = MTLTextureDescriptor.texture2DDescriptor(
			pixelFormat: .rgba16Float,
			width: lutSizes.multiScatteringRes,
			height: lutSizes.multiScatteringRes,
			mipmapped: false)
		multiScatteringDesc.usage = [.shaderRead, .shaderWrite]
		currentMultiScatteringLUT = device.makeTexture(descriptor: multiScatteringDesc)
		nextMultiScatteringLUT = device.makeTexture(descriptor: multiScatteringDesc)
		
		let skyViewDesc = MTLTextureDescriptor.texture2DDescriptor(
			pixelFormat: .rgba16Float,
			width: lutSizes.skyViewWidth,
			height: lutSizes.skyViewHeight,
			mipmapped: false)
		skyViewDesc.usage = [.shaderRead, .renderTarget]
		currentSkyViewLUT = device.makeTexture(descriptor: skyViewDesc)
		nextSkyViewLUT = device.makeTexture(descriptor: skyViewDesc)
		
		let initialCommandBuffer = commandQueue.makeCommandBuffer()!
		generateTransmittanceLUT(commandBuffer: initialCommandBuffer, texture: currentTransmittanceLUT, cameraPosition: SIMD3<Float>(0.0, 6400.0, 0.0))
		generateMultiScatteringLUT(commandBuffer: initialCommandBuffer, texture: currentMultiScatteringLUT, cameraPosition: SIMD3<Float>(0.0, 6400.0, 0.0))
		generateSkyViewLUT(commandBuffer: initialCommandBuffer, texture: currentSkyViewLUT, cameraPosition: SIMD3<Float>(0.0, 6400.0, 0.0))
		initialCommandBuffer.commit()
		initialCommandBuffer.waitUntilCompleted()
	}
	
	private func setupPipelines() {
		do {
			let transmittanceDesc = MTLRenderPipelineDescriptor()
			transmittanceDesc.label = "Transmittance LUT Pipeline"
			transmittanceDesc.vertexFunction = library.makeFunction(name: "skyFullscreenQuadVertex")
			transmittanceDesc.fragmentFunction = library.makeFunction(name: "transmittanceLutFragment")
			transmittanceDesc.colorAttachments[0].pixelFormat = .rgba16Float
			transmittanceLutPipeline = try device.makeRenderPipelineState(descriptor: transmittanceDesc)
			
			let multiScatteringDesc = MTLComputePipelineDescriptor()
			multiScatteringDesc.label = "Multi-scattering LUT Pipeline"
			multiScatteringDesc.computeFunction = library.makeFunction(name: "multiScatteringLutCompute")
			multiScatteringLutPipeline = try device.makeComputePipelineState(descriptor: multiScatteringDesc, options: [], reflection: nil)
			
			let skyViewDesc = MTLRenderPipelineDescriptor()
			skyViewDesc.label = "Sky View LUT Pipeline"
			skyViewDesc.vertexFunction = library.makeFunction(name: "skyFullscreenQuadVertex")
			skyViewDesc.fragmentFunction = library.makeFunction(name: "skyViewLutFragment")
			skyViewDesc.colorAttachments[0].pixelFormat = .rgba16Float
			skyViewLutPipeline = try device.makeRenderPipelineState(descriptor: skyViewDesc)
			
			let skyRenderDesc = MTLRenderPipelineDescriptor()
			skyRenderDesc.label = "Sky Rendering Pipeline"
			skyRenderDesc.vertexFunction = library.makeFunction(name: "skyFullscreenQuadVertex")
			skyRenderDesc.fragmentFunction = library.makeFunction(name: "skyRenderingFragment")
			skyRenderDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
			skyRenderDesc.depthAttachmentPixelFormat = .depth32Float
			skyRenderingPipeline = try device.makeRenderPipelineState(descriptor: skyRenderDesc)
		} catch {
			fatalError("Failed to create pipeline states: \(error)")
		}
	}
		
	public func generateLUTs(cameraPosition: SIMD3<Float>) {
		// Avoid multiple simultaneous generations
		if isGeneratingLUTs { return }
		
		lutSemaphore.wait()
		isGeneratingLUTs = true
		
		let commandBuffer = commandQueue.makeCommandBuffer()!
		commandBuffer.label = "LUT Generation Command Buffer"
		
		// Generate LUTs using the "next" textures
		generateTransmittanceLUT(commandBuffer: commandBuffer, texture: nextTransmittanceLUT, cameraPosition: cameraPosition)
		generateMultiScatteringLUT(commandBuffer: commandBuffer, texture: nextMultiScatteringLUT, cameraPosition: cameraPosition)
		generateSkyViewLUT(commandBuffer: commandBuffer, texture: nextSkyViewLUT, cameraPosition: cameraPosition)
		
		// When all LUTs are generated, swap buffers atomically
		commandBuffer.addCompletedHandler { [weak self] _ in
			guard let self = self else { return }
			
			// Swap the textures
			swap(&self.currentTransmittanceLUT, &self.nextTransmittanceLUT)
			swap(&self.currentMultiScatteringLUT, &self.nextMultiScatteringLUT)
			swap(&self.currentSkyViewLUT, &self.nextSkyViewLUT)
			
			self.isGeneratingLUTs = false
			self.lutSemaphore.signal()
		}
		
		commandBuffer.commit()
	}
	
	private func generateTransmittanceLUT(commandBuffer: MTLCommandBuffer, texture: MTLTexture, cameraPosition: SIMD3<Float>) {
		let renderPassDescriptor = MTLRenderPassDescriptor()
		
		renderPassDescriptor.colorAttachments[0].texture = texture
		renderPassDescriptor.colorAttachments[0].loadAction = .clear
		renderPassDescriptor.colorAttachments[0].storeAction = .store
		renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
		
		guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
		encoder.label = "Transmittance LUT Encoder"
		
		encoder.setRenderPipelineState(transmittanceLutPipeline)
		updateUniformBuffer(viewMatrix: matrix4x4_identity(), projectionMatrix: matrix4x4_identity(), cameraPosition: cameraPosition)
		encoder.setFragmentBuffer(atmosphereUniformBuffer, offset: 0, index: 0)
		
		encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
		encoder.endEncoding()
	}
	
	private func generateMultiScatteringLUT(commandBuffer: MTLCommandBuffer, texture: MTLTexture, cameraPosition: SIMD3<Float>) {
		guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
		encoder.label = "Multi-scattering LUT Encoder"
		
		encoder.setComputePipelineState(multiScatteringLutPipeline)
		updateUniformBuffer(viewMatrix: matrix4x4_identity(), projectionMatrix: matrix4x4_identity(), cameraPosition: cameraPosition)
		encoder.setBuffer(atmosphereUniformBuffer, offset: 0, index: 0)
		encoder.setTexture(currentTransmittanceLUT, index: 0) // Use current for computing
		encoder.setTexture(texture, index: 1)
		
		let threadgroupSize = MTLSize(width: 8, height: 8, depth: 1)
		let threadgroupCount = MTLSize(
			width: (lutSizes.multiScatteringRes + threadgroupSize.width - 1) / threadgroupSize.width,
			height: (lutSizes.multiScatteringRes + threadgroupSize.height - 1) / threadgroupSize.height,
			depth: 1)
		
		encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
		encoder.endEncoding()
	}
	
	private func generateSkyViewLUT(commandBuffer: MTLCommandBuffer, texture: MTLTexture, cameraPosition: SIMD3<Float>) {
		let renderPassDescriptor = MTLRenderPassDescriptor()
		
		renderPassDescriptor.colorAttachments[0].texture = texture
		renderPassDescriptor.colorAttachments[0].loadAction = .clear
		renderPassDescriptor.colorAttachments[0].storeAction = .store
		renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
		
		guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
		encoder.label = "Sky View LUT Encoder"
		
		encoder.setRenderPipelineState(skyViewLutPipeline)
		updateUniformBuffer(viewMatrix: matrix4x4_identity(), projectionMatrix: matrix4x4_identity(), cameraPosition: cameraPosition)
		encoder.setFragmentBuffer(atmosphereUniformBuffer, offset: 0, index: 0)
		encoder.setFragmentTexture(currentTransmittanceLUT, index: 0)
		encoder.setFragmentTexture(currentMultiScatteringLUT, index: 1)
		
		encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
		encoder.endEncoding()
	}
	
	func renderSky(commandBuffer: MTLCommandBuffer, renderPassDescriptor: MTLRenderPassDescriptor,
				  viewMatrix: matrix_float4x4, projectionMatrix: matrix_float4x4,
				  depthTexture: MTLTexture, cameraPosition: SIMD3<Float>) {
		
		guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
		encoder.label = "Sky Rendering Encoder"
		
		encoder.setFragmentSamplerState(linearSampler, index: 0)
		
		encoder.setRenderPipelineState(skyRenderingPipeline)
		updateUniformBuffer(viewMatrix: viewMatrix, projectionMatrix: projectionMatrix, cameraPosition: cameraPosition)
		encoder.setFragmentBuffer(atmosphereUniformBuffer, offset: 0, index: 0)

		encoder.setFragmentTexture(currentTransmittanceLUT, index: 0)
		encoder.setFragmentTexture(currentMultiScatteringLUT, index: 1)
		encoder.setFragmentTexture(currentSkyViewLUT, index: 2)
		encoder.setFragmentTexture(depthTexture, index: 3)
		
		encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
		encoder.endEncoding()
	}
	
	private func updateUniformBuffer(viewMatrix: matrix_float4x4, projectionMatrix: matrix_float4x4, cameraPosition: SIMD3<Float>) {
		guard let buffer = atmosphereUniformBuffer?.contents() else { return }
		
		let viewProjectionMatrix = matrix_multiply(projectionMatrix, viewMatrix)
		let inverseViewProjectionMatrix = viewProjectionMatrix.inverse
		let inverseViewMatrix = viewMatrix.inverse
		let inverseProjectionMatrix = projectionMatrix.inverse
		
		var uniforms = AtmosphereUniforms(
			bottomRadius: atmosphereParams.bottomRadius,
			topRadius: atmosphereParams.topRadius,
			
			rayleighDensityExpScale: atmosphereParams.rayleighDensityExpScale,
			rayleighScattering: atmosphereParams.rayleighScattering,
			
			mieDensityExpScale: atmosphereParams.mieDensityExpScale,
			mieScattering: atmosphereParams.mieScattering,
			mieExtinction: atmosphereParams.mieExtinction,
			mieAbsorption: atmosphereParams.mieAbsorption,
			miePhaseG: atmosphereParams.miePhaseG,
			
			absorptionDensity0LayerWidth: atmosphereParams.absorptionDensity0LayerWidth,
			absorptionDensity0ConstantTerm: atmosphereParams.absorptionDensity0ConstantTerm,
			absorptionDensity0LinearTerm: atmosphereParams.absorptionDensity0LinearTerm,
			absorptionDensity1ConstantTerm: atmosphereParams.absorptionDensity1ConstantTerm,
			absorptionDensity1LinearTerm: atmosphereParams.absorptionDensity1LinearTerm,
			absorptionExtinction: atmosphereParams.absorptionExtinction,
			
			groundAlbedo: atmosphereParams.groundAlbedo,
			
			viewMatrix: viewMatrix,
			projectionMatrix: projectionMatrix,
			viewProjectionMatrix: viewProjectionMatrix,
			inverseViewProjectionMatrix: inverseViewProjectionMatrix,
			inverseViewMatrix: inverseViewMatrix,
			inverseProjectionMatrix: inverseProjectionMatrix,
			
			cameraPosition: cameraPosition,
			sunDirection: sunDirection,
			sunIlluminance: sunIlluminance,
			
			multiScatteringLUTRes: Float(lutSizes.multiScatteringRes),
			multipleScatteringFactor: 1.0
		)
		
		memcpy(buffer, &uniforms, MemoryLayout<AtmosphereUniforms>.size)
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
		
	func getSunDirection() -> SIMD3<Float> {
		return sunDirection
	}
	
	func getSunIlluminance() -> SIMD3<Float> {
		return sunIlluminance
	}
	
	func updateSunPosition(timeOfDay: Float) {
		// Map time of day to (-π to π) for a full day cycle
		let dayAngle = (timeOfDay * 2.0 - 1.0) * Float.pi
		
		let eastWestPosition = sin(dayAngle)
		let heightPosition = cos(dayAngle) * 0.8
		let northSouthPosition = sin(dayAngle) * 0.3
		
		sunDirection = normalize(SIMD3<Float>(
			eastWestPosition,
			heightPosition,
			northSouthPosition
		))
		
		// Illuminance based on sun height (only when above horizon)
		let baseIlluminance: Float = 10.0
		let sunHeight = max(0.0, heightPosition)
		let dayIntensity = baseIlluminance + 15.0 * pow(sunHeight, 1.5)
		
		// Color temperature shifts with sun height
		let sunriseWeight = smoothstep(0.0, 0.7, 1.0 - min(1.0, heightPosition / 0.8))
		let dayColor = SIMD3<Float>(1.0, 1.0, 1.0)
		let sunriseColor = SIMD3<Float>(1.0, 0.5, 0.3)
		
		sunIlluminance = mix(dayColor, sunriseColor, sunriseWeight) * dayIntensity
	}
	
	func setAtmosphereParameters(_ params: AtmosphereParameters) {
		atmosphereParams = params
	}
	
	func getTransmittanceLUT() -> MTLTexture {
		return currentTransmittanceLUT
	}

	func getMultiScatteringLUT() -> MTLTexture {
		return currentMultiScatteringLUT
	}

	func getSkyViewLUT() -> MTLTexture {
		return currentSkyViewLUT
	}
	
	func getBottomRadius() -> Float {
		return atmosphereParams.bottomRadius
	}
	
	func getTopRadius() -> Float {
		return atmosphereParams.topRadius
	}
}

private func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
	let t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
}

private func clamp(_ x: Float, _ min: Float, _ max: Float) -> Float {
	return x < min ? min : (x > max ? max : x)
}

private func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
	return a + (b - a) * t
}
