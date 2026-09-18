#!/bin/bash
# Shared source list. Legacy fixtures compile the production kit values/decoder
# and the separate dashboard capability policy, never copied protocol methods.
kit_flags=(-package-name Switch2Kit -D S2K_RADIO_FIXTURE)
kit_sources=(
  Sources/Switch2Kit/Platform/ControllerClock.swift
  Sources/Switch2Kit/Public/ControllerTypes.swift
  Sources/Switch2Kit/Public/Lifecycle.swift
  Sources/Switch2Kit/Protocol/Switch2Protocol.swift
  Sources/Switch2Kit/Protocol/AdvertisementRecognition.swift
  Sources/Switch2Kit/Protocol/DecodedState.swift
)
prepare_session_sources() {
  local destination="$1"
  python3 tests/support/prepare-sources.py session "$destination"
  kit_session_sources=(
    "${kit_sources[@]}"
    Sources/Switch2Kit/Public/Observation.swift
    Sources/Switch2Kit/Diagnostics/Diagnostics.swift
    "$destination/ControllerSession.swift"
    tests/session/FrameworkFakes.swift
  )
}
