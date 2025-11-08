#!/bin/bash
# Copyright 2025 Arkavo
# Licensed under the Apache License, Version 2.0

set -e  # Exit on error

# Metal Shader Compilation Script for VRMMetalKit
# ================================================
# This script compiles all .metal shader files into a single .metallib bundle
# for distribution with the Swift package.

echo "🔨 Compiling VRMMetalKit Metal Shaders..."
echo ""

# Configuration
SHADERS_DIR="Sources/VRMMetalKit/Shaders"
RESOURCES_DIR="Sources/VRMMetalKit/Resources"
OUTPUT_LIB="VRMMetalKitShaders.metallib"
BUILD_DIR=".build/shaders"

# Detect platform and SDK
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS - compile for both macOS and iOS
    MACOS_SDK=$(xcrun --sdk macosx --show-sdk-path)
    IOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)

    # Prefer macOS SDK for development
    SDK="$MACOS_SDK"
    SDK_NAME="macosx"

    # Allow override via environment variable
    if [[ -n "$COMPILE_FOR_IOS" ]]; then
        SDK="$IOS_SDK"
        SDK_NAME="iphoneos"
    fi
else
    echo "❌ Error: Metal shaders can only be compiled on macOS"
    exit 1
fi

echo "📍 Using SDK: $SDK_NAME"
echo "📂 Shader directory: $SHADERS_DIR"
echo "📦 Output library: $RESOURCES_DIR/$OUTPUT_LIB"
echo ""

# Create build and resources directories
mkdir -p "$BUILD_DIR"
mkdir -p "$RESOURCES_DIR"

# Find all .metal files
METAL_FILES=("$SHADERS_DIR"/*.metal)

if [ ${#METAL_FILES[@]} -eq 0 ]; then
    echo "❌ Error: No .metal files found in $SHADERS_DIR"
    exit 1
fi

echo "📋 Found ${#METAL_FILES[@]} shader files:"
for file in "${METAL_FILES[@]}"; do
    echo "   - $(basename "$file")"
done
echo ""

# Step 1: Compile each .metal file to .air (intermediate representation)
echo "⚙️  Step 1: Compiling .metal → .air..."
AIR_FILES=()
FAILED=0

for metal_file in "${METAL_FILES[@]}"; do
    filename=$(basename "$metal_file" .metal)
    air_file="$BUILD_DIR/$filename.air"

    echo "   Compiling $filename.metal..."

    if xcrun -sdk "$SDK_NAME" metal \
        -c "$metal_file" \
        -o "$air_file" \
        -std=metal3.0 \
        -Wall \
        -Wextra \
        2>&1 | grep -v "warning: Metal language version 3.0 is not supported"; then
        AIR_FILES+=("$air_file")
    else
        echo "   ❌ Failed to compile $filename.metal"
        FAILED=1
    fi
done

if [ $FAILED -eq 1 ]; then
    echo ""
    echo "❌ Compilation failed for one or more shaders"
    exit 1
fi

echo "   ✅ All shaders compiled to .air successfully"
echo ""

# Step 2: Link all .air files into a single .metallib
echo "🔗 Step 2: Linking .air → .metallib..."

if xcrun -sdk "$SDK_NAME" metallib \
    "${AIR_FILES[@]}" \
    -o "$RESOURCES_DIR/$OUTPUT_LIB"; then
    echo "   ✅ Successfully created $OUTPUT_LIB"
else
    echo "   ❌ Failed to create metallib"
    exit 1
fi

echo ""

# Step 3: Verify the metallib
echo "🔍 Step 3: Verifying shader library..."

if xcrun -sdk "$SDK_NAME" metal-objdump \
    -macho -private-headers \
    "$RESOURCES_DIR/$OUTPUT_LIB" > /dev/null 2>&1; then
    echo "   ✅ Shader library is valid"
else
    echo "   ⚠️  Could not verify shader library (metal-objdump not available)"
fi

# List functions in the library
echo ""
echo "📚 Shader functions in library:"
xcrun -sdk "$SDK_NAME" metal-nm "$RESOURCES_DIR/$OUTPUT_LIB" 2>/dev/null | grep -E "(__kernel|__vertex|__fragment)" | awk '{print "   - " $3}' || echo "   (Could not list functions)"

# Cleanup intermediate files
echo ""
echo "🧹 Cleaning up intermediate files..."
rm -rf "$BUILD_DIR"
echo "   ✅ Removed $BUILD_DIR"

echo ""
echo "✅ Shader compilation complete!"
echo ""
echo "📦 Output: $RESOURCES_DIR/$OUTPUT_LIB"
echo ""
echo "ℹ️  Next steps:"
echo "   1. Ensure Package.swift includes Resources directory"
echo "   2. Add the .metallib file to git if not already tracked"
echo "   3. Rebuild your project to use the updated shaders"
echo ""

# Optional: Display file size
FILE_SIZE=$(du -h "$RESOURCES_DIR/$OUTPUT_LIB" | awk '{print $1}')
echo "📏 Library size: $FILE_SIZE"
