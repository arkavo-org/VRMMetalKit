# VRM Creator Test Suite

Comprehensive test suite for the VRM Creator system covering all phases of the LLM-powered character creation pipeline.

## Test Structure

### Unit Tests (`VRMCreatorTests.swift`)
- **CharacterRecipe validation**: JSON parsing, skeleton validation, morph range checking, material validation, expression validation
- **VRMBuilder testing**: Skeleton presets, morph application, material configuration, expression presets, GLB serialization
- **Integration testing**: Complete pipeline from CharacterRecipe to VRM file

### CLI Integration Tests (`RecipeValidateTests.swift`)
- **File input validation**: Testing recipe_validate CLI with various file inputs
- **Stdin validation**: Testing pipe and redirect input methods
- **Error handling**: Invalid recipes, malformed JSON, usage errors
- **Performance testing**: Large recipes, rapid validation
- **Terminal output**: Color codes, error messages, hints

### End-to-End Tests (`EndToEndTests.swift`)
- **Character archetypes**: Blacksmith, elf mage, warrior, rogue
- **Training data validation**: Using real training samples
- **CLI integration**: End-to-end pipeline with CLI validation
- **File format validation**: GLB structure verification
- **Batch processing**: Multiple character creation
- **Error handling**: Pipeline failure scenarios

### Performance Tests (`PerformanceTests.swift`)
- **Validation speed**: Recipe parsing and validation benchmarks
- **VRM creation speed**: Builder performance with various configurations
- **Memory usage**: Memory consumption analysis
- **Concurrent operations**: Multi-threaded validation and building
- **Throughput testing**: High-volume processing
- **Stress testing**: Large batch processing and memory leak detection

### Model Inference Tests (`test_model_inference.py`)
- **LoRA model testing**: Fine-tuned model validation
- **Natural language processing**: Description to recipe generation
- **JSON validation**: Generated recipe format checking
- **Accuracy testing**: Validation against test dataset
- **Performance benchmarks**: Inference speed and throughput

## Running Tests

### Quick Start
```bash
# Run all tests
./run_tests.sh

# Run specific test categories
./run_tests.sh swift      # Swift unit tests
./run_tests.sh cli        # CLI integration tests
./run_tests.sh model      # Model inference tests
./run_tests.sh performance # Performance benchmarks
```

### Individual Test Suites
```bash
# Swift tests
swift test

# Specific test suites
swift test --filter VRMCreatorTests
swift test --filter RecipeValidateTests
swift test --filter EndToEndTests
swift test --filter PerformanceTests

# Model inference tests
cd ../MLXTraining
python3 test_model_inference.py

# CLI validation
echo '{"skeleton":"default","morphs":{},"materials":{"hairColor":[0.5,0.5,0.5],"eyeColor":[0.5,0.5,0.5],"skinTone":0.5},"expressions":[]}' | swift run recipe_validate
```

## Test Data

### Character Recipes (`TestData/CharacterRecipes/`)
- **Valid recipes**: `valid_blacksmith.json`, `valid_elf_mage.json`, `valid_warrior.json`, `valid_rogue.json`
- **Invalid recipes**: `invalid_skeleton.json`, `invalid_morphs.json`, `invalid_materials.json`, `invalid_expressions.json`
- **Malformed data**: `malformed_json.json`

### Natural Language (`TestData/NaturalLanguage/`)
- **Character descriptions**: 20 sample character descriptions for model testing
- **Format**: Plain text file with one description per line

### Expected Outputs (`TestData/ExpectedOutputs/`)
- **VRM files**: Reference files for validation (generated during tests)
- **Documentation**: File format and validation specifications

## Success Criteria

### Functional Requirements
- ✅ CharacterRecipe validation accuracy > 95%
- ✅ VRMBuilder creates valid .vrm files
- ✅ CLI tool handles all input methods correctly
- ✅ End-to-end pipeline produces valid VRM files
- ✅ LoRA model generates syntactically correct JSON (if available)

### Performance Requirements
- ✅ Recipe validation: <10ms
- ✅ VRM building: <100ms
- ✅ GLB serialization: <500ms
- ✅ Model inference: <500ms (if available)
- ✅ Total pipeline: <1s

### Coverage Requirements
- ✅ Unit test coverage >90%
- ✅ Integration tests for all major components
- ✅ CLI edge cases covered
- ✅ Error paths tested

## Test Reports

Test execution generates detailed reports in `test_results/`:
- **Timestamped reports**: `test_report_YYYYMMDD_HHMMSS.txt`
- **Comprehensive logging**: All test output captured
- **Performance metrics**: Timing and memory usage
- **Error details**: Full stack traces for failures

## Continuous Integration

The test suite is designed for CI/CD integration:
- **Fast execution**: Under 5 minutes total
- **Clear exit codes**: 0 for success, 1 for failure
- **Detailed logs**: For debugging failures
- **Parallel execution**: Tests can run concurrently

## Troubleshooting

### Common Issues

1. **Build failures**: Ensure Swift 6.2+ is installed
2. **CLI tests failing**: Build recipe_validate target first
3. **Model tests failing**: Install MLX and ensure LoRA adapter exists
4. **Performance test failures**: May need more memory or CPU

### Debug Mode

For debugging test failures:
```bash
# Run tests with verbose output
swift test --verbose

# Run specific failing test
swift test --filter TestName

# Check test logs
cat test_results/test_report_*.txt
```

## Contributing

When adding new tests:
1. Follow existing naming conventions
2. Include both positive and negative test cases
3. Add performance expectations
4. Update this README
5. Test on multiple platforms if possible

## Architecture

The test suite follows the VRM Creator system architecture:

```
Natural Language
    ↓
VRMCopilot (LLM + LoRA) ← Model Tests
    ↓
CharacterRecipe JSON ← Unit Tests
    ↓
VRMBuilder ← Unit Tests
    ↓
VRMModel ← Integration Tests
    ↓
.vrm GLB File ← End-to-End Tests
```

Each component is tested independently and as part of the complete pipeline.