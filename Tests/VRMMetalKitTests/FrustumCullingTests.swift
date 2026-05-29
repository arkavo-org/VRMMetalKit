import XCTest
import simd
@testable import VRMMetalKit

final class FrustumCullingTests: XCTestCase {

    // Standard perspective view-projection: camera at origin looking down -Z,
    // 60° vertical FOV, 16:9 aspect, near 0.1, far 100.
    private func defaultViewProjection() -> matrix_float4x4 {
        let fovy: Float = .pi / 3
        let aspect: Float = 16.0 / 9.0
        let near: Float = 0.1
        let far: Float = 100.0
        let f: Float = 1.0 / tanf(fovy * 0.5)
        let projection = matrix_float4x4(columns: (
            SIMD4<Float>(f / aspect, 0, 0, 0),
            SIMD4<Float>(0, f, 0, 0),
            SIMD4<Float>(0, 0, far / (near - far), -1),
            SIMD4<Float>(0, 0, (far * near) / (near - far), 0)
        ))
        let view = matrix_float4x4(1)  // camera at origin, no rotation
        return simd_mul(projection, view)
    }

    func testFrustumAcceptsPointInFrontOfCamera() {
        let frustum = Frustum(viewProjection: defaultViewProjection())
        // 1m unit cube centered 5m down -Z (well in front of camera).
        let lo = SIMD3<Float>(-0.5, -0.5, -5.5)
        let hi = SIMD3<Float>( 0.5,  0.5, -4.5)
        XCTAssertFalse(frustum.cullsAABB(min: lo, max: hi))
    }

    func testFrustumCullsBehindCamera() {
        let frustum = Frustum(viewProjection: defaultViewProjection())
        // Box behind the camera (positive Z).
        let lo = SIMD3<Float>(-0.5, -0.5, 4.5)
        let hi = SIMD3<Float>( 0.5,  0.5, 5.5)
        XCTAssertTrue(frustum.cullsAABB(min: lo, max: hi))
    }

    func testFrustumCullsBeyondFar() {
        let frustum = Frustum(viewProjection: defaultViewProjection())
        // Box past the far plane (z = -100 is far; z = -200 is beyond).
        let lo = SIMD3<Float>(-0.5, -0.5, -201)
        let hi = SIMD3<Float>( 0.5,  0.5, -199)
        XCTAssertTrue(frustum.cullsAABB(min: lo, max: hi))
    }

    func testFrustumCullsOffToSide() {
        let frustum = Frustum(viewProjection: defaultViewProjection())
        // Box far off to the right at the same depth as the visible test case.
        let lo = SIMD3<Float>(50.0, -0.5, -5.5)
        let hi = SIMD3<Float>(51.0,  0.5, -4.5)
        XCTAssertTrue(frustum.cullsAABB(min: lo, max: hi))
    }

    // Right-handed look-at view matrix (matches Sources/VRMVideoRenderer lookAt).
    private func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> matrix_float4x4 {
        let f = simd_normalize(center - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        var r = matrix_float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))
        r.columns.0 = SIMD4<Float>(s.x, u.x, -f.x, 0)
        r.columns.1 = SIMD4<Float>(s.y, u.y, -f.y, 0)
        r.columns.2 = SIMD4<Float>(s.z, u.z, -f.z, 0)
        r.columns.3 = SIMD4<Float>(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)
        return r
    }

    // Metal RH perspective, NDC z in [0, 1] (matches VRMRenderer.makeProjectionMatrix).
    private func metalPerspective(fovy: Float, aspect: Float, near: Float, far: Float) -> matrix_float4x4 {
        let ys = 1.0 / tanf(fovy * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return matrix_float4x4(columns: (
            SIMD4<Float>(xs, 0, 0, 0),
            SIMD4<Float>(0, ys, 0, 0),
            SIMD4<Float>(0, 0, zs, -1),
            SIMD4<Float>(0, 0, zs * near, 0)
        ))
    }

    // Regression for #301: a distant-but-visible avatar must NOT be culled.
    // Over-the-shoulder camera looking toward +Z at an avatar centered ~27 m
    // on-axis, well inside the horizontal FOV and far short of the 100 m far
    // plane. The reported symptom was a wrong REJECT at this range.
    func testFrustumAcceptsDistantOnScreenAvatar() {
        let proj = metalPerspective(fovy: .pi / 3, aspect: 16.0 / 9.0, near: 0.1, far: 100)
        let view = lookAt(
            eye: SIMD3<Float>(7.18, 1.5, -6.9),
            center: SIMD3<Float>(7.2, 0.8, -3.9),
            up: SIMD3<Float>(0, 1, 0))
        let frustum = Frustum(viewProjection: simd_mul(proj, view))

        // Avatar ~1 m wide, ~1.8 m tall, centered 24–27 m down-range on-axis.
        let center = SIMD3<Float>(7.4, 0.8, 20.8)
        let lo = center - SIMD3<Float>(0.5, 0.9, 0.5)
        let hi = center + SIMD3<Float>(0.5, 0.9, 0.5)
        XCTAssertFalse(frustum.cullsAABB(min: lo, max: hi),
                       "Distant on-screen avatar at ~27 m was wrongly culled (see #301)")
    }

    func testWorldAABBTranslatesAndRotates() {
        // Local cube [-1, +1]³, translate +10 along X, no rotation.
        let translation = matrix_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(10, 0, 0, 1)
        ))
        let world = AABBTransform.worldAABB(
            localMin: SIMD3<Float>(-1, -1, -1),
            localMax: SIMD3<Float>( 1,  1,  1),
            modelMatrix: translation)
        XCTAssertEqual(world.min.x, 9, accuracy: 1e-5)
        XCTAssertEqual(world.max.x, 11, accuracy: 1e-5)
        XCTAssertEqual(world.min.y, -1, accuracy: 1e-5)
        XCTAssertEqual(world.max.y, 1, accuracy: 1e-5)
    }

    func testWorldAABBExpandsUnderRotation() {
        // 45° Y rotation of a unit cube widens the X/Z extents to ±√2.
        let q = simd_quatf(angle: .pi / 4, axis: SIMD3<Float>(0, 1, 0))
        let r = matrix_float4x4(q)
        let world = AABBTransform.worldAABB(
            localMin: SIMD3<Float>(-1, -1, -1),
            localMax: SIMD3<Float>( 1,  1,  1),
            modelMatrix: r)
        // Expected new extents along X/Z: |cos45| + |sin45| = √2 ≈ 1.4142
        XCTAssertEqual(world.max.x, sqrtf(2), accuracy: 1e-4)
        XCTAssertEqual(world.min.x, -sqrtf(2), accuracy: 1e-4)
        XCTAssertEqual(world.max.z, sqrtf(2), accuracy: 1e-4)
    }
}
