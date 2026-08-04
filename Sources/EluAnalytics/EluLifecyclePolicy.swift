import Foundation

enum EluLifecycleState: Equatable {
    case idle
    /// Setup called, no usable config yet — facade ops buffer in memory.
    case pending
    /// Runtime initialized and delegating.
    case running
    case disabled
}

enum EluDisabledReason: Equatable {
    /// Config said `enabled:false`. A later `enabled:true` may re-initialize.
    case remoteDisabled
    /// EU-blocked from cached config. Loosening applies next launch only.
    case euBlocked
    /// Mid-session kill switch — runtime was live and has been opted out.
    case killSwitch
}

struct EluStateDecision: Equatable {
    let state: EluLifecycleState
    let disabledReason: EluDisabledReason?
}

/// Pure activation policy for the wrapper baseline. Keeping config decisions
/// separate from side effects makes fail-closed state transitions testable
/// while the future transport and persistence contracts remain provisional.
enum EluLifecyclePolicy {
    static func initial(cached: EluRemoteConfig?, deviceInEu: Bool) -> EluStateDecision {
        guard let cached else {
            return EluStateDecision(state: .pending, disabledReason: nil)
        }
        return activation(for: cached, deviceInEu: deviceInEu)
    }

    static func activation(for config: EluRemoteConfig, deviceInEu: Bool) -> EluStateDecision {
        if !config.enabled {
            return EluStateDecision(state: .disabled, disabledReason: .remoteDisabled)
        }
        if deviceInEu, config.privacy.blockEu {
            return EluStateDecision(state: .disabled, disabledReason: .euBlocked)
        }
        return EluStateDecision(state: .running, disabledReason: nil)
    }

    static func shouldReactivate(
        disabledReason: EluDisabledReason?,
        runtimeWasInitialized: Bool,
        config: EluRemoteConfig,
        deviceInEu: Bool
    ) -> Bool {
        guard disabledReason == .remoteDisabled, !runtimeWasInitialized else { return false }
        return activation(for: config, deviceInEu: deviceInEu).state == .running
    }
}
