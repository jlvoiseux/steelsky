import MetalKit
import simd

struct Vertex {
	var position: SIMD3<Float>
	var normal: SIMD3<Float>
	var texCoord: SIMD2<Float>
}

struct Material {
	var name: String
	var ambientColor: SIMD3<Float>
	var diffuseColor: SIMD3<Float>
	var specularColor: SIMD3<Float>
	var specularExponent: Float
	var opacity: Float
	var texture: MTLTexture?
	var hasTexture: Bool
	
	init(name: String) {
		self.name = name
		self.ambientColor = SIMD3<Float>(0.2, 0.2, 0.2)
		self.diffuseColor = SIMD3<Float>(0.8, 0.8, 0.8)
		self.specularColor = SIMD3<Float>(1.0, 1.0, 1.0)
		self.specularExponent = 10.0
		self.opacity = 1.0
		self.texture = nil
		self.hasTexture = false
	}
}

struct BoundingSphere {
	var center: SIMD3<Float>
	var radius: Float
}

struct Mesh {
	var vertexCount: Int
	var indexCount: Int
	var materialIndex: Int
	var boundingSphere: BoundingSphere
}

class Model {
	var meshes: [Mesh] = []
	var materials: [Material] = []
	var vertexBuffers: [MTLBuffer] = []
	var indexBuffers: [MTLBuffer] = []
}

class ObjLoader {
	private let device: MTLDevice
	private let textureLoader: MTKTextureLoader
	
	var progressHandler: ((Float) -> Void)? = nil
	
	init(device: MTLDevice) {
		self.device = device
		self.textureLoader = MTKTextureLoader(device: device)
	}
	
	private func computeBoundingSphere(vertices: [Vertex]) -> BoundingSphere {
		// Find the center (average of vertices)
		var center = SIMD3<Float>(0, 0, 0)
		for vertex in vertices {
			center += vertex.position
		}
		center /= Float(vertices.count)
		
		var maxDistSquared: Float = 0
		for vertex in vertices {
			let distSquared = distance_squared(center, vertex.position)
			maxDistSquared = max(maxDistSquared, distSquared)
		}
		
		return BoundingSphere(center: center, radius: sqrt(maxDistSquared))
	}
	
	private func createBuffersForMesh(_ vertices: [Vertex], _ indices: [UInt32], materialIndex: Int, model: Model) {
		if vertices.isEmpty || indices.isEmpty {
			return
		}
		
		let vertexBufferSize = vertices.count * MemoryLayout<Vertex>.stride
		let vertexBuffer = device.makeBuffer(bytes: vertices, length: vertexBufferSize, options: [])
		
		let indexBufferSize = indices.count * MemoryLayout<UInt32>.size
		let indexBuffer = device.makeBuffer(bytes: indices, length: indexBufferSize, options: [])
		
		let boundingSphere = computeBoundingSphere(vertices: vertices)
		
		let mesh = Mesh(
			vertexCount: vertices.count,
			indexCount: indices.count,
			materialIndex: materialIndex,
			boundingSphere: boundingSphere
		)
		
		model.meshes.append(mesh)
		model.vertexBuffers.append(vertexBuffer!)
		model.indexBuffers.append(indexBuffer!)
	}
	
	func loadModel(objURL: URL, mtlBaseURL: URL? = nil) -> Model? {
		let model = Model()
		
		let fileSize = (try? FileManager.default.attributesOfItem(atPath: objURL.path)[.size] as? NSNumber)?.int64Value ?? 0
		var bytesProcessed: Int64 = 0
		
		guard let fileHandle = try? FileHandle(forReadingFrom: objURL) else {
			print("Failed to open OBJ file at \(objURL)")
			return nil
		}
		
		progressHandler?(0.0)
		
		var positions: [SIMD3<Float>] = []
		var normals: [SIMD3<Float>] = []
		var texCoords: [SIMD2<Float>] = []
		
		var currentMaterialIndex = -1
		var currentMeshVertices: [Vertex] = []
		var currentMeshIndices: [UInt32] = []
		var vertexIndexMap: [String: UInt32] = [:]
		var mtlLib: String?
		
		autoreleasepool {
			let chunkSize = 1024 * 1024
			var buffer = Data(capacity: chunkSize)
			var remainingLine = ""
			
			while true {
				guard let data = try? fileHandle.read(upToCount: chunkSize) else { break }
				if data.isEmpty { break }
				
				bytesProcessed += Int64(data.count)
				if fileSize > 0 {
					let progress = min(Float(bytesProcessed) / Float(fileSize), 1.0)
					progressHandler?(progress)
				}
				
				buffer = data
				
				if let chunk = String(data: buffer, encoding: .utf8) {
					let lines = (remainingLine + chunk).components(separatedBy: .newlines)
					remainingLine = lines.last ?? ""
					
					// Process all lines except possibly incomplete last one
					for i in 0..<(lines.count - 1) {
						let line = lines[i].trimmingCharacters(in: .whitespaces)
						
						if line.isEmpty || line.hasPrefix("#") {
							continue
						}
						
						let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
						guard let type = components.first else { continue }
						
						switch type {
						case "mtllib":
							if components.count > 1 {
								mtlLib = components[1]
								if let mtlLib = mtlLib {
									let baseURL = mtlBaseURL ?? objURL.deletingLastPathComponent()
									let mtlURL = baseURL.appendingPathComponent(mtlLib)
									loadMaterials(from: mtlURL, into: model, baseURL: baseURL)
								}
							}
							
						case "usemtl":
							if components.count > 1 {
								let materialName = components[1]
								if let index = model.materials.firstIndex(where: { $0.name == materialName }) {
									// Finish current mesh if we were building one
									if !currentMeshVertices.isEmpty && !currentMeshIndices.isEmpty {
										// Create buffers for current mesh and add to model
										createBuffersForMesh(currentMeshVertices, currentMeshIndices, materialIndex: currentMaterialIndex, model: model)
										
										currentMeshVertices = []
										currentMeshIndices = []
										vertexIndexMap = [:]
									}
									
									currentMaterialIndex = index
								}
							}
							
						case "v":
							if components.count >= 4 {
								let x = Float(components[1]) ?? 0.0
								let y = Float(components[2]) ?? 0.0
								let z = Float(components[3]) ?? 0.0
								positions.append(SIMD3<Float>(x, y, z))
							}
							
						case "vn":
							if components.count >= 4 {
								let x = Float(components[1]) ?? 0.0
								let y = Float(components[2]) ?? 0.0
								let z = Float(components[3]) ?? 0.0
								normals.append(SIMD3<Float>(x, y, z))
							}
							
						case "vt":
							if components.count >= 3 {
								let u = Float(components[1]) ?? 0.0
								let v = Float(components[2]) ?? 0.0
								texCoords.append(SIMD2<Float>(u, 1.0 - v)) // Flip V coordinate for Metal
							}
							
						case "f":
							if components.count >= 4 {
								// Triangulate faces with more than 3 vertices
								for i in 1..<(components.count - 2) {
									let vertexIndices = [components[1], components[i + 1], components[i + 2]]
									
									for vertexIndexStr in vertexIndices {
										let indexComponents = vertexIndexStr.components(separatedBy: "/")
										
										guard let posIndex = Int(indexComponents[0]), posIndex > 0, posIndex <= positions.count else { continue }
										
										let texIndex: Int
										if indexComponents.count > 1 && !indexComponents[1].isEmpty {
											texIndex = Int(indexComponents[1]) ?? 0
										} else {
											texIndex = 0
										}
										
										let normIndex: Int
										if indexComponents.count > 2 && !indexComponents[2].isEmpty {
											normIndex = Int(indexComponents[2]) ?? 0
										} else {
											normIndex = 0
										}
										
										let key = "\(posIndex)/\(texIndex)/\(normIndex)"
										
										if let index = vertexIndexMap[key] {
											currentMeshIndices.append(index)
										} else {
											let position = positions[posIndex - 1]
											let texCoord = texIndex > 0 && texIndex <= texCoords.count ? texCoords[texIndex - 1] : SIMD2<Float>(0, 0)
											let normal = normIndex > 0 && normIndex <= normals.count ? normals[normIndex - 1] : SIMD3<Float>(0, 1, 0)
											
											let vertex = Vertex(position: position, normal: normal, texCoord: texCoord)
											currentMeshVertices.append(vertex)
											
											let index = UInt32(currentMeshVertices.count - 1)
											vertexIndexMap[key] = index
											currentMeshIndices.append(index)
										}
									}
								}
							}
							
						default:
							break
						}
						
						// Periodically flush vertex data to reduce memory pressure
						if currentMeshVertices.count > 25000 {
							createBuffersForMesh(currentMeshVertices, currentMeshIndices, materialIndex: currentMaterialIndex, model: model)
							
							currentMeshVertices = []
							currentMeshIndices = []
							vertexIndexMap = [:]
						}
					}
				}
			}
		}
		
		if !currentMeshVertices.isEmpty && !currentMeshIndices.isEmpty {
			createBuffersForMesh(currentMeshVertices, currentMeshIndices, materialIndex: currentMaterialIndex, model: model)
		}
		
		progressHandler?(1.0)
		
		try? fileHandle.close()
		return model
	}
	
	private func loadMaterials(from mtlURL: URL, into model: Model, baseURL: URL) {
		guard let mtlContents = try? String(contentsOf: mtlURL, encoding: .utf8) else {
			print("Failed to load MTL file '\(mtlURL)'")
			return
		}
		
		var currentMaterial: Material?
		var pendingTextureMaterials: [(Int, String)] = [] // Store material index and texture path
		
		let lines = mtlContents.components(separatedBy: .newlines)
		for line in lines {
			let trimmedLine = line.trimmingCharacters(in: .whitespaces)
			
			if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") {
				continue
			}
			
			let components = trimmedLine.components(separatedBy: .whitespaces)
			guard let type = components.first else { continue }
			
			switch type {
			case "newmtl":
				if components.count > 1 {
					if let material = currentMaterial {
						model.materials.append(material)
					}
					
					currentMaterial = Material(name: components[1])
				}
				
			case "Ka":
				if components.count >= 4, var material = currentMaterial {
					let r = Float(components[1]) ?? 0.0
					let g = Float(components[2]) ?? 0.0
					let b = Float(components[3]) ?? 0.0
					material.ambientColor = SIMD3<Float>(r, g, b)
					currentMaterial = material
				}
				
			case "Kd":
				if components.count >= 4, var material = currentMaterial {
					let r = Float(components[1]) ?? 0.0
					let g = Float(components[2]) ?? 0.0
					let b = Float(components[3]) ?? 0.0
					material.diffuseColor = SIMD3<Float>(r, g, b)
					currentMaterial = material
				}
				
			case "Ks":
				if components.count >= 4, var material = currentMaterial {
					let r = Float(components[1]) ?? 0.0
					let g = Float(components[2]) ?? 0.0
					let b = Float(components[3]) ?? 0.0
					material.specularColor = SIMD3<Float>(r, g, b)
					currentMaterial = material
				}
				
			case "Ns":
				if components.count >= 2, var material = currentMaterial {
					material.specularExponent = Float(components[1]) ?? 0.0
					currentMaterial = material
				}
				
			case "d", "Tr":
				if components.count >= 2, var material = currentMaterial {
					material.opacity = Float(components[1]) ?? 1.0
					currentMaterial = material
				}
				
			case "map_Kd":
				if components.count >= 2, var material = currentMaterial {
					let texturePath = components[1..<components.count].joined(separator: " ")
					
					material.hasTexture = true
					currentMaterial = material
					
					let materialIndex = model.materials.count
					pendingTextureMaterials.append((materialIndex, texturePath))
				}
				
			default:
				break
			}
		}
		
		if let material = currentMaterial {
			model.materials.append(material)
		}
		
		// Load textures separately to avoid memory spikes
		for (index, (materialIndex, texturePath)) in pendingTextureMaterials.enumerated() {
			autoreleasepool {
				if materialIndex < model.materials.count {
					let textureURL = baseURL.appendingPathComponent(texturePath)
					do {
						let texture = try textureLoader.newTexture(URL: textureURL, options: [
							.generateMipmaps: true,
							.SRGB: false
						])
						
						model.materials[materialIndex].texture = texture
						
						if let progressHandler = progressHandler, !pendingTextureMaterials.isEmpty {
							let textureProgress = Float(index + 1) / Float(pendingTextureMaterials.count)
							progressHandler(0.95 + textureProgress * 0.05)
						}
					} catch {
						print("Failed to load texture '\(texturePath)': \(error)")
					}
				}
			}
		}
	}
}
