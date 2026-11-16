import Foundation

/// The arithmetic the DP-32SD applies over the first and last 10 ms of every clip.
///
/// Samples are 24-bit values. `incoming` is the clip that starts here (0 for
/// silence) and `outgoing` is the audio stored after the end of the clip that
/// just stopped (0 when nothing stopped). See docs/FORMAT.md, "Clip edges".
public struct EdgeFade {
    public let length: Int
    let gainIn: [Int64]    // Q23, quadratic
    let gainOut: [Int64]   // Q31, linear

    public init(length: Int) {
        precondition(length > 0)
        self.length = length
        let n = Int64(length)
        var gin = [Int64]()
        var gout = [Int64]()
        gin.reserveCapacity(length)
        gout.reserveCapacity(length)
        for step in 0..<length {
            let i = Int64(step)
            gin.append((0x7FFFFF * i * i) / (n * n))
            gout.append(min(((Int64(1) << 31) * (n - i)) / n, (Int64(1) << 31) - 1))
        }
        gainIn = gin
        gainOut = gout
    }

    @inline(__always)
    public func mix(outgoing a: Int32, incoming b: Int32, at i: Int) -> Int32 {
        var acc: Int64 = 0
        if a > 0 {
            acc = (Int64(a) * gainOut[i]) >> 16
        } else if a < 0 {
            acc = -(((-Int64(a)) * gainOut[i]) >> 16) - 1
        }
        acc += Int64(b >> 8) * gainIn[i]
        if acc >= 0 { return Int32(truncatingIfNeeded: acc >> 15) }
        return Int32(truncatingIfNeeded: -((-acc) >> 15) - 1)
    }
}
