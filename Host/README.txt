The app target's Info.plist is generated into this folder by XcodeGen.

Assets.xcassets holds the app icon. Its three images (standard, dark and
tinted) are drawn by scripts/render-icon.swift; to change the icon, change
that script and run it on a Mac: swift scripts/render-icon.swift
