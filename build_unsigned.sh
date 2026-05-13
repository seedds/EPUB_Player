rm -rf build/DerivedData export && \
mkdir -p .build/source-packages build export/Payload && \
xcodebuild \
  -project "EPUB Player.xcodeproj" \
  -scheme "EPUB Player" \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath .build/source-packages \
  MARKETING_VERSION="${APP_VERSION:-1.0}" \
  CURRENT_PROJECT_VERSION="${APP_VERSION:-1.0}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  build && \
  cp -R "build/DerivedData/Build/Products/Release-iphoneos/EPUBPlayer.app" "export/Payload/" && \
  cd export && \
  zip -r "EPUBPlayer-${APP_VERSION:-1.0}-unsigned.ipa" Payload
