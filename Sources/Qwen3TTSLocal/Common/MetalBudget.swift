import Foundation
import MLX

/// Metal GPU memory budget utilities.
public enum MetalBudget {

    /// Query real Metal headroom: recommended working set minus active allocations.
    /// Returns nil if Metal device info is unavailable.
    public static var availableBytes: Int? {
        let info = GPU.deviceInfo()
        let maxWorking = Int(info.maxRecommendedWorkingSetSize)
        guard maxWorking > 0 else { return nil }
        let active = Memory.activeMemory
        let overhead = 256 * 1024 * 1024  // 256 MB safety margin
        return max(0, maxWorking - active - overhead)
    }

    /// Total device memory in bytes.
    public static var totalMemory: Int {
        GPU.deviceInfo().memorySize
    }

    /// Maximum recommended working set size in bytes.
    public static var maxRecommendedWorkingSet: Int {
        Int(GPU.deviceInfo().maxRecommendedWorkingSetSize)
    }

    /// Currently active (non-cache) MLX memory in bytes.
    public static var activeMemory: Int {
        Memory.activeMemory
    }

    /// Check if a model of the given size (bytes) can fit in available GPU memory.
    public static func canFit(modelBytes: Int) -> Bool {
        guard let available = availableBytes else { return true }
        return modelBytes <= available
    }
}
