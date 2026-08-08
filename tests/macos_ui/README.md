# Nimculus XCUITest

Build and package Nimculus first, install or launch the resulting
`Nimculus.app`, then run this test target with `xcodebuild test` in a GUI
session. The test deliberately resolves `toolbar.save` by identifier; it does
not use recorder-generated `element(boundBy:)` queries.
