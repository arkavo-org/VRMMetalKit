# Task 3: RootDisplacement Accumulator — Report

## Summary
Task 3 implemented the `RootDisplacement` struct, which accumulates scene-root displacement requests (absolute + deltas) per avatar per frame, enforcing the one-absolute-per-frame conflict rule. All 7 tests pass, including the required 7th test for bit-identity verification.

## Steps Executed

### Step 1: Write test file
Created `/Users/arkavo/Projects/VRMMetalKit/Tests/VRMMetalKitTests/Pipeline/RootDisplacementTests.swift` with:
- Apache 2.0 header (copied from CaptureStepController.swift lines 1-15)
- 6 test cases from brief
- 7th test: `testBitIdentityWithExpressionForm` — validates that RootDisplacement produces bit-identical results to the literal expression form

**Bit-identity test design:**
- Literal form: `var t = base + placement; t.x += shove.x; t.z += shove.y`
- Type form: `setAbsolute(base + placement); addDelta(SIMD3(shove.x, 0, shove.y))`
- Values chosen with non-trivial mantissas:
  - base: (0.37, 1.11, -0.29)
  - placement: (0.813, 0, -0.447)
  - shove: (0.0231, -0.0177)
- Assertion: all x, y, z components match bitPattern-for-bitPattern
- Y-component test: confirms that adding explicit 0 to y (in delta) preserves the original y value bit-for-bit

### Step 2: Write implementation
Created `/Users/arkavo/Projects/VRMMetalKit/Sources/VRMMetalKit/Animation/Pipeline/RootDisplacement.swift` with:
- Apache 2.0 header
- `public struct RootDisplacement: Sendable`
- `public init()`
- `public var hasAbsolute: Bool`
- `public mutating func setAbsolute(_ t: SIMD3<Float>)`
- `public mutating func addDelta(_ d: SIMD3<Float>)`
- `public func resolve(base: SIMD3<Float>) -> SIMD3<Float>`
- precondition on second `setAbsolute` call (traps the process, not testable)

### Step 3: Run tests
Command: `swift test --filter RootDisplacementTests --disable-sandbox`

**Results:**
```
Test Suite 'RootDisplacementTests' passed at 2026-08-04 23:52:42.433.
	Executed 7 tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds
```

All tests passed:
1. testNoRequestsLeavesBaseUntouched
2. testAbsoluteReplacesBase
3. testDeltasAccumulateOnTopOfAbsolute
4. testDeltasApplyToBaseWhenNoAbsoluteRequested
5. testDeltaOrderIsInsertionOrder
6. testHasAbsoluteReportsRequestState
7. testBitIdentityWithExpressionForm (required addition)

### Step 4: Commit
```
[fix/stagger-collision c8348c6] feat(pipeline): RootDisplacement accumulator with the one-absolute conflict rule
 2 files changed, 142 insertions(+)
 create mode 100644 Sources/VRMMetalKit/Animation/Pipeline/RootDisplacement.swift
 create mode 100644 Tests/VRMMetalKitTests/Pipeline/RootDisplacementTests.swift
```

**Commit SHA:** `c8348c6`

## Concerns
None. The implementation is pure, testable, and correctly enforces the conflict rule through a precondition. The 7th test confirms bit-identical output compared to the literal form it replaces, proving there is no floating-point reassociation or approximation in the API.

The precondition on a second `setAbsolute` call cannot be tested via XCTest (it traps the process), but is documented in the code as specified.

---

## Fix Round 1 — Multi-Delta & Bit-Identity Coverage

**Coordinator feedback:** Two findings:
1. `testBitIdentityWithExpressionForm` (single delta) does not prove multi-delta ordering
2. `testDeltaOrderIsInsertionOrder` is vacuous — IEEE 754 addition is commutative for two terms

**Changes made:**
- Replaced `testDeltaOrderIsInsertionOrder` with `testSequentialAccumulationVsReassociation`:
  - Uses three deltas (1e7, 1.0, -1e7) to distinguish sequential from reassociated accumulation
  - Compares RootDisplacement result against sequential SIMD3 accumulation with same deltas
  - Verifies bit patterns for all three components (x, y, z)
  - Genuinely sensitive to reassociation: failing implementation would give incorrect result
- Added `testBitIdentityWithTwoDeltaForm`:
  - Extends bit-identity testing to two-delta case (shove + goal-approach displacements)
  - Compares against literal two-addition form: `t += shove; t += goalApproach`
  - Uses non-trivial mantissa values with all three coordinate components active

**Test run command:**
```bash
swift test --filter RootDisplacementTests --disable-sandbox
```

**Output:**
```
Test Suite 'RootDisplacementTests' passed at 2026-08-04 23:57:31.227.
	Executed 8 tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds
```

**Tests (8 total, all passing):**
1. testNoRequestsLeavesBaseUntouched
2. testAbsoluteReplacesBase
3. testDeltasAccumulateOnTopOfAbsolute
4. testDeltasApplyToBaseWhenNoAbsoluteRequested
5. testSequentialAccumulationVsReassociation (replaced two-delta vacuous test)
6. testHasAbsoluteReportsRequestState
7. testBitIdentityWithExpressionForm (one delta)
8. testBitIdentityWithTwoDeltaForm (two deltas)

**Commit SHA:** `355a995`

**Concerns:** None. Tests now properly exercise:
- Single-delta bit-identity (against literal one-addition form)
- Two-delta bit-identity (against literal two-addition form, multi-frame scenario)
- Three-delta sequential vs. reassociation sensitivity (proving left-to-right insertion order)

---

## Fix Round 2 — Corrected Floating Point Construction

**Coordinator feedback:** Round 1 construction (1e7, 1.0, -1e7) was arithmetically wrong. Floats represent integers up to 2^24 exactly, so 1e7 + 1.0 = 10000001.0 (nothing swallowed). Correct construction uses ULP sensitivity:

**Corrected construction — deltas in insertion order: +1.0, -1.0, +1e-8**
- Sequential: ((0 + 1.0) + (-1.0)) + 1e-8 = 1e-8 (1e-8 survives, added to running 0.0)
- Key: ULP(1.0) ≈ 1.19e-7, and 1e-8 < ULP/2, so it reaches the final accumulation

**Changes made:**
- Renamed test to `testAccumulationIsSequentialNotReassociated` (clearer intent)
- Changed deltas to: +1.0, -1.0, +1e-8 on .x axis (y, z remain zero)
- Assert expected value as independent hardcoded literal: `XCTAssertEqual(result.x.bitPattern, Float(1e-8).bitPattern)`
- Removed self-referential recomputation of expected value

**Test run command:**
```bash
swift test --filter RootDisplacementTests --disable-sandbox
```

**Output:**
```
Test Suite 'RootDisplacementTests' passed at 2026-08-05 00:02:49.215.
	Executed 8 tests, with 0 failures (0 unexpected) in 0.001 (0.001) seconds
```

**Tests (8 total, all passing):**
1. testNoRequestsLeavesBaseUntouched
2. testAbsoluteReplacesBase
3. testDeltasAccumulateOnTopOfAbsolute
4. testDeltasApplyToBaseWhenNoAbsoluteRequested
5. testAccumulationIsSequentialNotReassociated (corrected construction)
6. testHasAbsoluteReportsRequestState
7. testBitIdentityWithExpressionForm (one delta)
8. testBitIdentityWithTwoDeltaForm (two deltas)

**Commit SHA:** `803f78b`

**Concerns:** None. Test now verifies sequential left-to-right accumulation via a floating point construction that is sensitive to reassociation: the 1e-8 delta only survives if added last to a zero running total.
