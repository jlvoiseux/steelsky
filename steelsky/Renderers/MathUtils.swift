import simd

func radians_from_degrees(_ degrees: Float) -> Float {
	return (degrees / 180) * .pi
}

func matrix4x4_identity() -> matrix_float4x4 {
	return matrix_float4x4(
		SIMD4<Float>(1, 0, 0, 0),
		SIMD4<Float>(0, 1, 0, 0),
		SIMD4<Float>(0, 0, 1, 0),
		SIMD4<Float>(0, 0, 0, 1)
	)
}

func matrix_perspective_right_hand(fovyRadians: Float, aspectRatio: Float, nearZ: Float, farZ: Float) -> matrix_float4x4 {
	let ys = 1 / tanf(fovyRadians * 0.5)
	let xs = ys / aspectRatio
	let zs = farZ / (nearZ - farZ)
	
	return matrix_float4x4(
		SIMD4<Float>(xs, 0, 0, 0),
		SIMD4<Float>(0, ys, 0, 0),
		SIMD4<Float>(0, 0, zs, -1),
		SIMD4<Float>(0, 0, zs * nearZ, 0)
	)
}

func matrix_scale(_ sx: Float, _ sy: Float, _ sz: Float) -> matrix_float4x4 {
	return matrix_float4x4(
		SIMD4<Float>(sx, 0, 0, 0),
		SIMD4<Float>(0, sy, 0, 0),
		SIMD4<Float>(0, 0, sz, 0),
		SIMD4<Float>(0, 0, 0, 1)
	)
}

extension matrix_float4x4 {
	mutating func translate(_ x: Float, _ y: Float, _ z: Float) {
		var result = matrix4x4_identity()
		result.columns.3.x = x
		result.columns.3.y = y
		result.columns.3.z = z
		self = matrix_multiply(self, result)
	}
	
	mutating func rotateAroundX(_ angleX: Float, y angleY: Float) {
		var resultX = matrix4x4_identity()
		resultX.columns.1.y = cos(angleX)
		resultX.columns.1.z = sin(angleX)
		resultX.columns.2.y = -sin(angleX)
		resultX.columns.2.z = cos(angleX)
		
		var resultY = matrix4x4_identity()
		resultY.columns.0.x = cos(angleY)
		resultY.columns.0.z = -sin(angleY)
		resultY.columns.2.x = sin(angleY)
		resultY.columns.2.z = cos(angleY)
		
		self = matrix_multiply(matrix_multiply(self, resultX), resultY)
	}
	
	var inverse: matrix_float4x4 {
		return simd_inverse(self)
	}
}

func matrix_look_at(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> matrix_float4x4 {
	let z = normalize(eye - center)
	let x = normalize(cross(up, z))
	let y = cross(z, x)
	
	let translateMatrix = matrix_float4x4(
		SIMD4<Float>(1, 0, 0, 0),
		SIMD4<Float>(0, 1, 0, 0),
		SIMD4<Float>(0, 0, 1, 0),
		SIMD4<Float>(-eye.x, -eye.y, -eye.z, 1)
	)
	
	let rotateMatrix = matrix_float4x4(
		SIMD4<Float>(x.x, y.x, z.x, 0),
		SIMD4<Float>(x.y, y.y, z.y, 0),
		SIMD4<Float>(x.z, y.z, z.z, 0),
		SIMD4<Float>(0, 0, 0, 1)
	)
	
	return matrix_multiply(rotateMatrix, translateMatrix)
}

func rotateVector(_ vector: SIMD3<Float>, around axis: SIMD3<Float>, by angle: Float) -> SIMD3<Float> {
	let c = cos(angle)
	let s = sin(angle)
	let oneMinusC = 1.0 - c
	
	let x = axis.x
	let y = axis.y
	let z = axis.z
	
	let rotationMatrix = matrix_float3x3(
		SIMD3<Float>(c + x * x * oneMinusC, x * y * oneMinusC - z * s, x * z * oneMinusC + y * s),
		SIMD3<Float>(y * x * oneMinusC + z * s, c + y * y * oneMinusC, y * z * oneMinusC - x * s),
		SIMD3<Float>(z * x * oneMinusC - y * s, z * y * oneMinusC + x * s, c + z * z * oneMinusC)
	)
	
	return rotationMatrix * vector
}


func normalizePlane(_ plane: SIMD4<Float>) -> SIMD4<Float> {
	let normal = SIMD3<Float>(plane.x, plane.y, plane.z)
	let len = length(normal)
	if len > 0 {
		return plane / len
	}
	return plane
}

func getSignedDistanceFromPlane(_ plane: SIMD4<Float>, _ point: SIMD3<Float>) -> Float {
	let normal = SIMD3<Float>(plane.x, plane.y, plane.z)
	return dot(normal, point) + plane.w
}

func matrix_orthographic_projection(left: Float, right: Float, bottom: Float, top: Float, nearZ: Float, farZ: Float) -> matrix_float4x4 {
	let rsl = right - left
	let tsb = top - bottom
	let fsn = farZ - nearZ
	
	return matrix_float4x4(
		SIMD4<Float>(2.0 / rsl, 0, 0, 0),
		SIMD4<Float>(0, 2.0 / tsb, 0, 0),
		SIMD4<Float>(0, 0, -1.0 / fsn, 0),
		SIMD4<Float>(-(right + left) / rsl, -(top + bottom) / tsb, -nearZ / fsn, 1)
	)
}

func generatePerlinGradients(size: Int) -> [SIMD3<Float>] {
	var gradients = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: size * size * size)
	
	for z in 0..<size {
		for y in 0..<size {
			for x in 0..<size {
				// Generate random unit vector for gradient
				let theta = Float.random(in: 0..<Float.pi * 2)
				let phi = Float.random(in: 0..<Float.pi)
				
				let sinPhi = sin(phi)
				
				gradients[z * size * size + y * size + x] = SIMD3<Float>(
					cos(theta) * sinPhi,
					sin(theta) * sinPhi,
					cos(phi)
				)
			}
		}
	}
	
	return gradients
}

func smoothstep(_ x: Float) -> Float {
	return x * x * x * (x * (x * 6 - 15) + 10) // Quintic interpolation curve
}

func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
	return a + t * (b - a)
}

func perlinNoise3D(x: Float, y: Float, z: Float, gradients: [SIMD3<Float>]) -> Float {
	let size = Int(sqrt(Float(gradients.count) / Float(16)))
	
	let xi = Int(floor(x)) & (size-2)
	let yi = Int(floor(y)) & (size-2)
	let zi = Int(floor(z)) & (size-2)
	
	let xf = x - floor(x)
	let yf = y - floor(y)
	let zf = z - floor(z)
	
	let u = smoothstep(xf)
	let v = smoothstep(yf)
	let w = smoothstep(zf)
	
	let c000 = dotGridGradient(xi, yi, zi, xf, yf, zf, gradients, size)
	let c100 = dotGridGradient(xi+1, yi, zi, xf-1, yf, zf, gradients, size)
	let c010 = dotGridGradient(xi, yi+1, zi, xf, yf-1, zf, gradients, size)
	let c110 = dotGridGradient(xi+1, yi+1, zi, xf-1, yf-1, zf, gradients, size)
	let c001 = dotGridGradient(xi, yi, zi+1, xf, yf, zf-1, gradients, size)
	let c101 = dotGridGradient(xi+1, yi, zi+1, xf-1, yf, zf-1, gradients, size)
	let c011 = dotGridGradient(xi, yi+1, zi+1, xf, yf-1, zf-1, gradients, size)
	let c111 = dotGridGradient(xi+1, yi+1, zi+1, xf-1, yf-1, zf-1, gradients, size)
	
	let x00 = lerp(c000, c100, u)
	let x10 = lerp(c010, c110, u)
	let x01 = lerp(c001, c101, u)
	let x11 = lerp(c011, c111, u)
	
	let y0 = lerp(x00, x10, v)
	let y1 = lerp(x01, x11, v)
	
	return lerp(y0, y1, w)
}

func dotGridGradient(_ ix: Int, _ iy: Int, _ iz: Int, _ dx: Float, _ dy: Float, _ dz: Float, _ gradients: [SIMD3<Float>], _ size: Int) -> Float {
	let gradient = gradients[iz * size * size + iy * size + ix]
	return dot(gradient, SIMD3<Float>(dx, dy, dz))
}
