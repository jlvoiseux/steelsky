import MetalKit
import simd

class SceneRenderer: NSObject, MTKViewDelegate {
	private var device: MTLDevice!
	private var commandQueue: MTLCommandQueue!
	
	private var depthStencilState: MTLDepthStencilState!
	
	private var scenePipelineState: MTLRenderPipelineState!
	private var sceneDepthPipelineState: MTLRenderPipelineState!
	private var compositePipelineState: MTLRenderPipelineState!
	
	private var uniformBuffer: MTLBuffer!
	private var materialBuffer: MTLBuffer!
	
	private var textureSamplerState: MTLSamplerState!
	private var shadowMapSamplerState: MTLSamplerState!
		
	private var model: Model?
	
	private var skyRenderer: SkyAtmosphereRenderer!
	private var volumetricRenderer: VolumetricLightingRenderer!
	
	private var cameraPosition: SIMD3<Float> = SIMD3<Float>(0.0, 6400.0, 0.0)
	private var cameraRotation: SIMD2<Float> = SIMD2<Float>(0.0, 0.0)
	
	private var timeOfDay: Float = 0.5
	
	private var lutGenerationWorkItem: DispatchWorkItem?
	private var lastCameraUpdate: CFTimeInterval = 0
	
	struct Uniforms {
		var modelMatrix: matrix_float4x4
		var viewMatrix: matrix_float4x4
		var projectionMatrix: matrix_float4x4
		var lightViewProjectionMatrix: matrix_float4x4
		var cameraPosition: SIMD3<Float>
		var sunDirection: SIMD3<Float>
		var sunIlluminance: SIMD3<Float>
		var bottomRadius: Float
		var topRadius: Float
		var padding: SIMD2<Float> = SIMD2<Float>(0, 0)
	}
	
	struct MetalMaterial {
		var ambientColor: SIMD3<Float>
		var diffuseColor: SIMD3<Float>
		var specularColor: SIMD3<Float>
		var specularExponent: Float
		var opacity: Float
		var hasTexture: Bool
	}
	
	enum AtmosphereType {
		case earth
		case mars
	}

	init(metalView: MTKView, modelName: String = "model") {
		super.init()
		
		setupMetal(metalView: metalView)
		setupRenderPipelines()
		setupBuffers()
		loadModel(modelName: modelName)
	}
	
	private func setupMetal(metalView: MTKView) {
		device = MTLCreateSystemDefaultDevice()
		metalView.device = device
		metalView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
		metalView.delegate = self
		
		commandQueue = device.makeCommandQueue()
		
		let library = device.makeDefaultLibrary()
		skyRenderer = SkyAtmosphereRenderer(device: device, library: library!)
		skyRenderer.generateLUTs(cameraPosition: cameraPosition)
		
		volumetricRenderer = VolumetricLightingRenderer(device: device, library: library!)
	}
	
	private func setupRenderPipelines() {
		let library = device.makeDefaultLibrary()
		
		let vertexDescriptor = MTLVertexDescriptor()
		// Position attribute
		vertexDescriptor.attributes[0].format = .float3
		vertexDescriptor.attributes[0].offset = 0
		vertexDescriptor.attributes[0].bufferIndex = 0
		// Normal attribute
		vertexDescriptor.attributes[1].format = .float3
		vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
		vertexDescriptor.attributes[1].bufferIndex = 0
		// Texture coordinate attribute
		vertexDescriptor.attributes[2].format = .float2
		vertexDescriptor.attributes[2].offset = MemoryLayout<SIMD3<Float>>.stride * 2
		vertexDescriptor.attributes[2].bufferIndex = 0
		// Define layout
		vertexDescriptor.layouts[0].stride = MemoryLayout<Vertex>.stride
		vertexDescriptor.layouts[0].stepRate = 1
		vertexDescriptor.layouts[0].stepFunction = .perVertex
		
		let scenePipelineDesc = MTLRenderPipelineDescriptor()
		scenePipelineDesc.label = "sceneRenderPipeline"
		scenePipelineDesc.vertexFunction = library?.makeFunction(name: "sceneVertex")
		scenePipelineDesc.fragmentFunction = library?.makeFunction(name: "sceneFragment")
		scenePipelineDesc.vertexDescriptor = vertexDescriptor
		scenePipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
		scenePipelineDesc.depthAttachmentPixelFormat = .depth32Float
		
		let sceneDepthPipelineDesc = MTLRenderPipelineDescriptor()
		sceneDepthPipelineDesc.label = "sceneDepthRenderPipeline"
		sceneDepthPipelineDesc.vertexFunction = library?.makeFunction(name: "sceneVertex")
		sceneDepthPipelineDesc.fragmentFunction = library?.makeFunction(name: "depthOnlyFragment")
		sceneDepthPipelineDesc.vertexDescriptor = vertexDescriptor
		sceneDepthPipelineDesc.colorAttachments[0].pixelFormat = .invalid
		sceneDepthPipelineDesc.depthAttachmentPixelFormat = .depth32Float
		
		let compositeDesc = MTLRenderPipelineDescriptor()
		compositeDesc.label = "compositeRenderPipeline"
		compositeDesc.vertexFunction = library?.makeFunction(name: "skyFullscreenQuadVertex")
		compositeDesc.fragmentFunction = library?.makeFunction(name: "compositeFragment")
		compositeDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
		
		do {
			scenePipelineState = try device.makeRenderPipelineState(descriptor: scenePipelineDesc)
			sceneDepthPipelineState = try device.makeRenderPipelineState(descriptor: sceneDepthPipelineDesc)
			compositePipelineState = try device.makeRenderPipelineState(descriptor: compositeDesc)
		} catch {
			fatalError("Failed to create pipeline state: \(error)")
		}
		
		let depthStencilDescriptor = MTLDepthStencilDescriptor()
		depthStencilDescriptor.label = "depthStencil"
		depthStencilDescriptor.depthCompareFunction = .lessEqual
		depthStencilDescriptor.isDepthWriteEnabled = true
		depthStencilState = device.makeDepthStencilState(descriptor: depthStencilDescriptor)
		
		let samplerDescriptor = MTLSamplerDescriptor()
		samplerDescriptor.minFilter = .linear
		samplerDescriptor.magFilter = .linear
		samplerDescriptor.mipFilter = .linear
		samplerDescriptor.sAddressMode = .repeat
		samplerDescriptor.tAddressMode = .repeat
		textureSamplerState = device.makeSamplerState(descriptor: samplerDescriptor)
		
		let shadowSamplerDescriptor = MTLSamplerDescriptor()
		shadowSamplerDescriptor.minFilter = .linear
		shadowSamplerDescriptor.magFilter = .linear
		shadowSamplerDescriptor.sAddressMode = .clampToEdge
		shadowSamplerDescriptor.tAddressMode = .clampToEdge
		shadowMapSamplerState = device.makeSamplerState(descriptor: shadowSamplerDescriptor)
	}
	
	private func setupBuffers() {
		uniformBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.size, options: [])
		materialBuffer = device.makeBuffer(length: MemoryLayout<Material>.size, options: [])
	}
	
	private func loadModel(modelName: String = "model") {
		let objLoader = ObjLoader(device: device)
		objLoader.progressHandler = { progress in
			print("Loading progress: \(Int(progress * 100))%")
		}
		
		if let modelURL = Bundle.main.url(forResource: modelName, withExtension: "obj") {
			model = objLoader.loadModel(objURL: modelURL)
		} else {
			print("Failed to find \(modelName).obj in app bundle")
		}
	}
		
	func draw(in view: MTKView) {
		guard let drawable = view.currentDrawable,
			  let renderPassDescriptor = view.currentRenderPassDescriptor else { return }
		
		let commandBuffer = commandQueue.makeCommandBuffer()!
		
		//
		// Initialize matrices
		//
		
		let sunDirection = skyRenderer.getSunDirection()
		let aspect = Float(view.drawableSize.width / view.drawableSize.height)
		let projectionMatrix = matrix_perspective_right_hand(fovyRadians: radians_from_degrees(65), aspectRatio: aspect, nearZ: 0.1, farZ: 100000.0)
		let viewMatrix = calculateViewMatrix(cameraPosition: cameraPosition)
		let modelMatrix = matrix_multiply(matrix4x4_identity(), matrix_scale(6360, 6360, 6360))
		let lightPosition = cameraPosition + sunDirection * 500.0
		let lightUp = SIMD3<Float>(0, 1, 0)
		let lightViewMatrix = matrix_look_at(eye: lightPosition, center: cameraPosition, up: lightUp)
		let lightProjectionMatrix = matrix_orthographic_projection(left: -100, right: 100, bottom: -100, top: 100, nearZ: 1, farZ: 1000)
		let lightViewProjectionMatrix = matrix_multiply(lightProjectionMatrix, lightViewMatrix)
		
		var uniforms = Uniforms(
			modelMatrix: modelMatrix,
			viewMatrix: viewMatrix,
			projectionMatrix: projectionMatrix,
			lightViewProjectionMatrix: lightViewProjectionMatrix,
			cameraPosition: cameraPosition,
			sunDirection: sunDirection,
			sunIlluminance: skyRenderer.getSunIlluminance(),
			bottomRadius: skyRenderer.getBottomRadius(),
			topRadius: skyRenderer.getTopRadius()
		)
		memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<Uniforms>.size)
		
		//
		// Initialize textures
		//
		
		let depthTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
			pixelFormat: .depth32Float,
			width: Int(view.drawableSize.width),
			height: Int(view.drawableSize.height),
			mipmapped: false
		)
		depthTextureDescriptor.usage = [.renderTarget, .shaderRead]
		depthTextureDescriptor.storageMode = .private
		let depthTexture = device.makeTexture(descriptor: depthTextureDescriptor)!
		
		let colorTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
			pixelFormat: .bgra8Unorm,
			width: Int(view.drawableSize.width),
			height: Int(view.drawableSize.height),
			mipmapped: false
		)
		colorTextureDescriptor.usage = [.renderTarget, .shaderRead]
		colorTextureDescriptor.storageMode = .private
		let colorTexture = device.makeTexture(descriptor: colorTextureDescriptor)!
		
		let shadowMapDesc = MTLTextureDescriptor.texture2DDescriptor(
			pixelFormat: .depth32Float,
			width: 1024,
			height: 1024,
			mipmapped: false
		)
		shadowMapDesc.usage = [.renderTarget, .shaderRead]
		shadowMapDesc.storageMode = .private
		let shadowMapTexture = device.makeTexture(descriptor: shadowMapDesc)!
		
		//
		// Step 1: Compute shadow map
		//
		
		let shadowPassDesc = MTLRenderPassDescriptor()
		shadowPassDesc.depthAttachment.texture = shadowMapTexture
		shadowPassDesc.depthAttachment.loadAction = .clear
		shadowPassDesc.depthAttachment.storeAction = .store
		shadowPassDesc.depthAttachment.clearDepth = 1.0
				
		let shadowEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: shadowPassDesc)!
		shadowEncoder.label = "Shadow Map Encoder"
		shadowEncoder.setRenderPipelineState(sceneDepthPipelineState)
		shadowEncoder.setDepthStencilState(depthStencilState)
		
		var shadowUniforms = Uniforms(
			modelMatrix: modelMatrix,
			viewMatrix: lightViewMatrix,
			projectionMatrix: lightProjectionMatrix,
			lightViewProjectionMatrix: lightViewProjectionMatrix,
			cameraPosition: lightPosition,
			sunDirection: sunDirection,
			sunIlluminance: skyRenderer.getSunIlluminance(),
			bottomRadius: skyRenderer.getBottomRadius(),
			topRadius: skyRenderer.getTopRadius()
		)
		let shadowUniformBuffer = device.makeBuffer(bytes: &shadowUniforms, length: MemoryLayout<Uniforms>.size, options: [])
		shadowEncoder.setVertexBuffer(shadowUniformBuffer, offset: 0, index: 1)
		
		// Draw model (depth only)
		if let model = model {
			for (i, mesh) in model.meshes.enumerated() {
				shadowEncoder.setVertexBuffer(model.vertexBuffers[i], offset: 0, index: 0)
				shadowEncoder.drawIndexedPrimitives(
					type: .triangle,
					indexCount: mesh.indexCount,
					indexType: .uint32,
					indexBuffer: model.indexBuffers[i],
					indexBufferOffset: 0
				)
			}
		}
		
		shadowEncoder.endEncoding()
		
		//
		// Step 2: Compute depth buffer
		//
		
		let depthPassDescriptor = MTLRenderPassDescriptor()
		depthPassDescriptor.depthAttachment.texture = depthTexture
		depthPassDescriptor.depthAttachment.loadAction = .clear
		depthPassDescriptor.depthAttachment.storeAction = .store
		depthPassDescriptor.depthAttachment.clearDepth = 1.0
		
		let depthEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: depthPassDescriptor)!
		depthEncoder.label = "Depth Pass"
		depthEncoder.setRenderPipelineState(sceneDepthPipelineState)
		depthEncoder.setDepthStencilState(depthStencilState)
		depthEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
		
		if let model = model {
			for (i, mesh) in model.meshes.enumerated() {
				depthEncoder.setVertexBuffer(model.vertexBuffers[i], offset: 0, index: 0)
				depthEncoder.drawIndexedPrimitives(
					type: .triangle,
					indexCount: mesh.indexCount,
					indexType: .uint32,
					indexBuffer: model.indexBuffers[i],
					indexBufferOffset: 0
				)
			}
		}
		
		depthEncoder.endEncoding()
		
		//
		// Step 3: Render sky with depth information to the main color buffer
		//
		
		let skyPassDescriptor = MTLRenderPassDescriptor()
		skyPassDescriptor.colorAttachments[0].texture = colorTexture
		skyPassDescriptor.colorAttachments[0].loadAction = .clear
		skyPassDescriptor.colorAttachments[0].storeAction = .store
		skyPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
		skyPassDescriptor.depthAttachment.texture = depthTexture
		skyPassDescriptor.depthAttachment.loadAction = .load
		skyPassDescriptor.depthAttachment.storeAction = .store
		
		skyRenderer.renderSky(
			commandBuffer: commandBuffer,
			renderPassDescriptor: skyPassDescriptor,
			viewMatrix: viewMatrix,
			projectionMatrix: projectionMatrix,
			depthTexture: depthTexture,
			cameraPosition: cameraPosition
		)
		
		//
		// Step 4: Render model with color, compositing over the sky
		//
		
		let modelPassDescriptor = MTLRenderPassDescriptor()
		modelPassDescriptor.colorAttachments[0].texture = colorTexture
		modelPassDescriptor.colorAttachments[0].loadAction = .load
		modelPassDescriptor.colorAttachments[0].storeAction = .store
		modelPassDescriptor.depthAttachment.texture = depthTexture
		modelPassDescriptor.depthAttachment.loadAction = .load
		modelPassDescriptor.depthAttachment.storeAction = .store
		
		let modelEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: modelPassDescriptor)!
		modelEncoder.label = "Model Pass"
		modelEncoder.setRenderPipelineState(scenePipelineState)
		modelEncoder.setDepthStencilState(depthStencilState)
		
		modelEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
		modelEncoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)
		modelEncoder.setFragmentSamplerState(textureSamplerState, index: 0)
		modelEncoder.setFragmentSamplerState(shadowMapSamplerState, index: 1)
		modelEncoder.setFragmentTexture(shadowMapTexture, index: 1)
		modelEncoder.setFragmentTexture(skyRenderer.getTransmittanceLUT(), index: 2)
		modelEncoder.setFragmentTexture(skyRenderer.getMultiScatteringLUT(), index: 3)
		modelEncoder.setFragmentTexture(skyRenderer.getSkyViewLUT(), index: 4)
		
		var defaultMaterial = MetalMaterial(
			ambientColor: SIMD3<Float>(0.2, 0.2, 0.2),
			diffuseColor: SIMD3<Float>(0.8, 0.8, 0.8),
			specularColor: SIMD3<Float>(1.0, 1.0, 1.0),
			specularExponent: 10.0,
			opacity: 1.0,
			hasTexture: false
		)
		
		memcpy(materialBuffer.contents(), &defaultMaterial, MemoryLayout<MetalMaterial>.size)
		modelEncoder.setFragmentBuffer(materialBuffer, offset: 0, index: 0)
		
		// Draw model
		if let model = model {
			for (i, mesh) in model.meshes.enumerated() {
				let materialIndex = mesh.materialIndex
				if materialIndex >= 0 && materialIndex < model.materials.count {
					let material = model.materials[materialIndex]
					
					var metalMaterial = MetalMaterial(
						ambientColor: material.ambientColor,
						diffuseColor: material.diffuseColor,
						specularColor: material.specularColor,
						specularExponent: material.specularExponent,
						opacity: material.opacity,
						hasTexture: material.hasTexture
					)
					
					memcpy(materialBuffer.contents(), &metalMaterial, MemoryLayout<MetalMaterial>.size)
					modelEncoder.setFragmentBuffer(materialBuffer, offset: 0, index: 0)
					
					if material.hasTexture, let texture = material.texture {
						modelEncoder.setFragmentTexture(texture, index: 0)
					}
				}
				
				modelEncoder.setVertexBuffer(model.vertexBuffers[i], offset: 0, index: 0)
				modelEncoder.drawIndexedPrimitives(
					type: .triangle,
					indexCount: mesh.indexCount,
					indexType: .uint32,
					indexBuffer: model.indexBuffers[i],
					indexBufferOffset: 0
				)
			}
		}
		modelEncoder.endEncoding()
		
		//
		// Step 5: Apply volumetric lighting as a post-process
		//
		
		let finalPassDescriptor = renderPassDescriptor
		finalPassDescriptor.colorAttachments[0].loadAction = .clear
				
		volumetricRenderer.updateMatrices(
			viewMatrix: viewMatrix,
			projectionMatrix: projectionMatrix,
			lightViewProjectionMatrix: lightViewProjectionMatrix,
			cameraPosition: cameraPosition,
			sunDirection: skyRenderer.getSunDirection(),
			sunIlluminance: skyRenderer.getSunIlluminance(),
			planetRadius: skyRenderer.getBottomRadius(),
			atmosphereRadius: skyRenderer.getTopRadius(),
			screenWidth: Float(view.drawableSize.width),
			screenHeight: Float(view.drawableSize.height),
		)
		
		volumetricRenderer.renderVolumetrics(
			commandBuffer: commandBuffer,
			colorTexture: colorTexture,
			depthTexture: depthTexture,
			shadowTexture: shadowMapTexture,
			renderPassDescriptor: finalPassDescriptor
		)
		
		// Final composite pass to combine the scene with volumetric lighting
		let compositeDesc = MTLRenderPassDescriptor()
		compositeDesc.colorAttachments[0].texture = drawable.texture
		compositeDesc.colorAttachments[0].loadAction = .clear
		compositeDesc.colorAttachments[0].storeAction = .store
		compositeDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
		
		let compositeEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: compositeDesc)!
		compositeEncoder.label = "Composite Pass"
		compositeEncoder.setRenderPipelineState(compositePipelineState)
		compositeEncoder.setFragmentSamplerState(textureSamplerState, index: 0)
		compositeEncoder.setFragmentTexture(colorTexture, index: 0)
		compositeEncoder.setFragmentTexture(volumetricRenderer.getVolumetricLightTexture(), index: 1)
		compositeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
		compositeEncoder.endEncoding()
		
		commandBuffer.present(drawable)
		commandBuffer.commit()
	}
	
	func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
		// Handle window size changes
	}
	
	func setCameraDistance(_ distance: Float) {
		let oldCamY = cameraPosition.y
		cameraPosition.y = distance
		
		// Only trigger LUT regeneration after movement has stabilized
		let currentTime = CACurrentMediaTime()
		if abs(distance - oldCamY) > 5.0 && (currentTime - lastCameraUpdate) > 1.0 {
			lutGenerationWorkItem?.cancel()
			
			let workItem = DispatchWorkItem { [weak self] in
				guard let self = self else { return }
				self.skyRenderer.generateLUTs(cameraPosition: self.cameraPosition)
			}
			
			lutGenerationWorkItem = workItem
			DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
			lastCameraUpdate = currentTime
		}
	}

	func updateCameraRotation(rotationX: Float, rotationY: Float) {
		cameraRotation.x += rotationX
		cameraRotation.y += rotationY
		
		if cameraRotation.x > Float.pi/2 - 0.01 {
			cameraRotation.x = Float.pi/2 - 0.01
		}
		if cameraRotation.x < -Float.pi/2 + 0.01 {
			cameraRotation.x = -Float.pi/2 + 0.01
		}
		
		while cameraRotation.y > 2 * Float.pi {
			cameraRotation.y -= 2 * Float.pi
		}
		while cameraRotation.y < 0 {
			cameraRotation.y += 2 * Float.pi
		}
	}
	
	func updateTimeOfDay(_ newTimeOfDay: Float) {
		timeOfDay = newTimeOfDay
		skyRenderer.updateSunPosition(timeOfDay: timeOfDay)
	}
	
	func updateAtmosphereType(_ type: AtmosphereType) {
		switch type {
		case .earth:
			skyRenderer.setAtmosphereParameters(AtmosphereParameters.earthAtmosphere())
		case .mars:
			skyRenderer.setAtmosphereParameters(AtmosphereParameters.marsAtmosphere())
		}
	}
	
	func updateVolumetricParameters(fogDensity: Float, godRayStrength: Float) {
		volumetricRenderer.updateParameters(
			fogDensity: fogDensity,
			fogScatteringCoeff: 0.5,
			godRayStrength: godRayStrength,
			godRayDecay: 0.95
		)
	}
		
	private func calculateViewMatrix(cameraPosition: SIMD3<Float>) -> matrix_float4x4 {
		let upVector = normalize(cameraPosition)
		
		let worldUp = SIMD3<Float>(0, 1, 0)
		let alignment = abs(dot(upVector, worldUp))
		let referenceVector = alignment > 0.99 ? SIMD3<Float>(1, 0, 0) : worldUp
		
		let rightVector = normalize(cross(upVector, referenceVector))
		let forwardVector = normalize(cross(rightVector, upVector))
		
		let yawRotated = rotateVector(forwardVector, around: upVector, by: cameraRotation.y)
		
		let pitchRightVector = normalize(cross(upVector, yawRotated))
		let finalForward = rotateVector(yawRotated, around: pitchRightVector, by: cameraRotation.x)
		
		return matrix_look_at(
			eye: cameraPosition,
			center: cameraPosition + finalForward * 100.0,
			up: upVector
		)
	}
	
	func moveCameraForward(distance: Float) {
		var viewDir = SIMD3<Float>(0, 0, 0)
		
		let worldUp = SIMD3<Float>(0, 1, 0)
		let alignment = abs(dot(normalize(cameraPosition), worldUp))
		let referenceVector = alignment > 0.99 ? SIMD3<Float>(1, 0, 0) : worldUp
		
		let upVector = normalize(cameraPosition)
		let rightVector = normalize(cross(upVector, referenceVector))
		let forwardVector = normalize(cross(rightVector, upVector))
		
		viewDir = rotateVector(forwardVector, around: upVector, by: cameraRotation.y)
		
		viewDir.y = 0
		if length(viewDir) > 0.01 {
			viewDir = normalize(viewDir)
		} else {
			viewDir = SIMD3<Float>(1, 0, 0)
		}
		
		cameraPosition += viewDir * distance
		
		let currentHeight = length(cameraPosition)
		if currentHeight > 0.01 {
			cameraPosition = normalize(cameraPosition) * currentHeight
		}
	}
	
	func getCameraPosition() -> SIMD3<Float> {
		return cameraPosition
	}

	func setCameraPosition(_ position: SIMD3<Float>) {
		cameraPosition = position
	}
	
	func getCameraRotation() -> SIMD2<Float> {
		return cameraRotation
	}
	
	func setCameraRotation(_ rotation: SIMD2<Float>) {
		cameraRotation.x = rotation.x
		if cameraRotation.x > Float.pi/2 - 0.01 {
			cameraRotation.x = Float.pi/2 - 0.01
		}
		if cameraRotation.x < -Float.pi/2 + 0.01 {
			cameraRotation.x = -Float.pi/2 + 0.01
		}
		
		cameraRotation.y = rotation.y
		while cameraRotation.y > 2 * Float.pi {
			cameraRotation.y -= 2 * Float.pi
		}
		while cameraRotation.y < 0 {
			cameraRotation.y += 2 * Float.pi
		}
	}
}
