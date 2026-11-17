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

    /// MLX memory kept for reuse (freed arrays it hasn't handed back yet) in bytes.
    public static var cacheMemory: Int {
        Memory.cacheMemory
    }

    /// Hands the memory MLX kept for reuse back to the system. MLX keeps freed arrays to reuse them, up to its cache
    /// limit, and the limit goes back to MLX's own (most of the Mac's memory) once no model holds it lower, so a
    /// freed model's weights otherwise stay in the app until it quits.
    public static func returnSpareMemory() {
        Memory.clearCache()
    }

    /// Check if a model of the given size (bytes) can fit in available GPU memory.
    public static func canFit(modelBytes: Int) -> Bool {
        guard let available = availableBytes else { return true }
        return modelBytes <= available
    }
}
