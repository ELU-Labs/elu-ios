# Simulator evidence fixture

This directory is reserved for sanitized `0.1.0` simulator captures referenced
by the conformance case IDs. Captures must include lifecycle transitions,
wrapper-owned persistence, callback queue evidence, and outbound request
destinations. Do not commit credentials, identifiers, raw replay content, or
provider-owned payloads.

The current environment has Command Line Tools but no Xcode/iOS Simulator, so
the runnable capture target remains a CI/device follow-up. The consumer package
already provides the UIKit and SwiftUI compile inputs.
