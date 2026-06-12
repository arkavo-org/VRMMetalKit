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

// MARK: - #301: avatars rejected at distance

extension FrustumCullingTests {

    /// The unit repro #301 asks for: camera looking on-axis at an avatar-sized
    /// AABB ~25 m ahead, well inside the FOV and far plane. The pure plane
    /// math must accept it — if this fails, `Frustum`/`cullsAABB` itself is
    /// broken for distant boxes.
    func testOnAxisDistantAvatarIsNotCulled() {
        let projection = metalPerspective(fovy: .pi / 3, aspect: 16.0 / 9.0, near: 0.1, far: 100)
        // Over-the-shoulder-ish camera at the #301 geometry: avatar ~25 m away.
        let view = lookAt(
            eye: SIMD3<Float>(7.2, 1.7, -4.0),
            center: SIMD3<Float>(7.4, 0.9, 20.8),
            up: SIMD3<Float>(0, 1, 0))
        let frustum = Frustum(viewProjection: simd_mul(projection, view))
        // Avatar-sized box (1 × 2 × 1 m) centered at the logged reject position.
        let lo = SIMD3<Float>(6.9, -0.1, 20.3)
        let hi = SIMD3<Float>(7.9,  1.9, 21.3)
        XCTAssertFalse(frustum.cullsAABB(min: lo, max: hi),
                       "on-screen avatar 25 m ahead must not be culled")
    }

    /// The live #301 mechanism in the renderer: skinned primitives were culled
    /// against the inflated rest-pose bounds with an IDENTITY model matrix, so
    /// the cull volume stayed at the model's load position forever. A
    /// character that walks 20 m away — camera following — left the stale box
    /// behind and vanished. `SkinnedCullBounds.cullModelMatrix` translates the
    /// box by the hips' displacement so it follows the skeleton.
    func testSkinnedCullVolumeFollowsSkeleton() {
        let projection = metalPerspective(fovy: .pi / 3, aspect: 16.0 / 9.0, near: 0.1, far: 100)
        // Camera 6 m behind the walked-to position, looking at the character.
        let view = lookAt(
            eye: SIMD3<Float>(20, 1.6, 6),
            center: SIMD3<Float>(20, 1.0, 0),
            up: SIMD3<Float>(0, 1, 0))
        let frustum = Frustum(viewProjection: simd_mul(projection, view))

        // Inflated rest-pose bounds of a ~1.7 m humanoid loaded at the origin.
        let inflatedMin = SIMD3<Float>(-0.6, -0.2, -0.5)
        let inflatedMax = SIMD3<Float>( 0.6,  2.0,  0.5)
        let restHips = SIMD3<Float>(0, 0.8, 0)
        let walkedHips = SIMD3<Float>(20, 0.8, 0)  // walked 20 m down +X

        // Old behavior (identity): the stale box at the origin is out of view
        // even though the character is dead-center on screen.
        let staleAABB = AABBTransform.worldAABB(
            localMin: inflatedMin, localMax: inflatedMax,
            modelMatrix: matrix_identity_float4x4)
        XCTAssertTrue(frustum.cullsAABB(min: staleAABB.min, max: staleAABB.max),
                      "precondition: the stale rest box at origin is off-screen for this camera")

        // Fixed behavior: the box follows the hips and is accepted.
        let followMatrix = SkinnedCullBounds.cullModelMatrix(
            hipsWorldPosition: walkedHips,
            restHipsWorldPosition: restHips)
        let followedAABB = AABBTransform.worldAABB(
            localMin: inflatedMin, localMax: inflatedMax,
            modelMatrix: followMatrix)
        XCTAssertFalse(frustum.cullsAABB(min: followedAABB.min, max: followedAABB.max),
                       "cull volume must follow the walked character")
    }

    /// Camera still at the spawn point looking where the character USED to
    /// be: once the character walks away, the followed volume should cull
    /// (the character is genuinely off-screen) — guards against the fix
    /// accidentally making skinned primitives never-culled.
    func testWalkedAwayCharacterStillCullsWhenOffScreen() {
        let projection = metalPerspective(fovy: .pi / 3, aspect: 16.0 / 9.0, near: 0.1, far: 100)
        // Camera looking down -Z at the spawn point; character walked +X out of frame.
        let view = lookAt(
            eye: SIMD3<Float>(0, 1.6, 6),
            center: SIMD3<Float>(0, 1.0, 0),
            up: SIMD3<Float>(0, 1, 0))
        let frustum = Frustum(viewProjection: simd_mul(projection, view))

        let inflatedMin = SIMD3<Float>(-0.6, -0.2, -0.5)
        let inflatedMax = SIMD3<Float>( 0.6,  2.0,  0.5)
        let followMatrix = SkinnedCullBounds.cullModelMatrix(
            hipsWorldPosition: SIMD3<Float>(40, 0.8, 0),
            restHipsWorldPosition: SIMD3<Float>(0, 0.8, 0))
        let followedAABB = AABBTransform.worldAABB(
            localMin: inflatedMin, localMax: inflatedMax,
            modelMatrix: followMatrix)
        XCTAssertTrue(frustum.cullsAABB(min: followedAABB.min, max: followedAABB.max))
    }

    /// Non-humanoid models have no hips anchor — the matrix degrades to
    /// identity (rest box at load position), the pre-fix behavior.
    func testCullMatrixIdentityWithoutHips() {
        let m = SkinnedCullBounds.cullModelMatrix(hipsWorldPosition: nil, restHipsWorldPosition: nil)
        XCTAssertEqual(m, matrix_identity_float4x4)
        let m2 = SkinnedCullBounds.cullModelMatrix(
            hipsWorldPosition: SIMD3<Float>(1, 2, 3), restHipsWorldPosition: nil)
        XCTAssertEqual(m2, matrix_identity_float4x4)
    }
}
