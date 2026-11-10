#!/bin/sh
cd "$SRCROOT"
env -u SDKROOT xcrun --sdk macosx swift Tools/asset_validator.swift "Aivatar Watch App/AvatarAssets"

