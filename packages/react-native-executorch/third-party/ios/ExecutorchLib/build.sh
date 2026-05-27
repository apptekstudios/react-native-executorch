#!/bin/bash

# Builds ExecutorchLib.xcframework for iOS, iOS Simulator, and Mac Catalyst
#
# This script:
# 1. Cleans previous builds
# 2. Archives the framework for iOS device (arm64)
# 3. Archives the framework for iOS Simulator (arm64)
# 4. Archives the framework for Mac Catalyst (arm64)
# 5. Combines all archives into a single .xcframework
#
# Output: ./output/ExecutorchLib.xcframework
#
# Usage: ./build.sh

# --- Configuration ---
PROJECT_NAME="ExecutorchLib" # Replace with your Xcode project name
SCHEME_NAME="ExecutorchLib"  # Replace with your scheme name
OUTPUT_FOLDER="output"       # Choose your desired output folder

# --- Derived Variables ---
BUILD_FOLDER="build"
ARCHIVE_PATH_IOS="$BUILD_FOLDER/$SCHEME_NAME-iOS"
ARCHIVE_PATH_SIMULATOR="$BUILD_FOLDER/$SCHEME_NAME-iOS_Simulator"
ARCHIVE_PATH_MACCATALYST="$BUILD_FOLDER/$SCHEME_NAME-MacCatalyst"
FRAMEWORK_NAME="$SCHEME_NAME.framework"
XCFRAMEWORK_NAME="$SCHEME_NAME.xcframework"
XCFRAMEWORK_PATH="$OUTPUT_FOLDER/$XCFRAMEWORK_NAME"

# --- Script ---
rm -rf "$BUILD_FOLDER" "$OUTPUT_FOLDER"

xcodebuild clean -project "$PROJECT_NAME.xcodeproj" -scheme "$SCHEME_NAME"

xcodebuild archive \
  -project "$PROJECT_NAME.xcodeproj" \
  -scheme "$SCHEME_NAME" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -archivePath "$ARCHIVE_PATH_IOS" \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
  CODE_SIGNING_ALLOWED=NO

xcodebuild archive \
  -project "$PROJECT_NAME.xcodeproj" \
  -scheme "$SCHEME_NAME" \
  -configuration Release \
  -destination "generic/platform=iOS Simulator" \
  -archivePath "$ARCHIVE_PATH_SIMULATOR" \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
  CODE_SIGNING_ALLOWED=NO

xcodebuild archive \
  -project "$PROJECT_NAME.xcodeproj" \
  -scheme "$SCHEME_NAME" \
  -configuration Release \
  -destination "generic/platform=macOS,variant=Mac Catalyst" \
  -archivePath "$ARCHIVE_PATH_MACCATALYST" \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
  CODE_SIGNING_ALLOWED=NO \
  SUPPORTS_MACCATALYST=YES

xcodebuild -create-xcframework \
  -framework "$ARCHIVE_PATH_IOS.xcarchive/Products/Library/Frameworks/$FRAMEWORK_NAME" \
  -framework "$ARCHIVE_PATH_SIMULATOR.xcarchive/Products/Library/Frameworks/$FRAMEWORK_NAME" \
  -framework "$ARCHIVE_PATH_MACCATALYST.xcarchive/Products/Library/Frameworks/$FRAMEWORK_NAME" \
  -output "$XCFRAMEWORK_PATH"
