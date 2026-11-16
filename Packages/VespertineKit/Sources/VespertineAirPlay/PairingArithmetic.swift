//
// Vespertine: whole-number arithmetic modulo one large odd number, for the SRP exchange that pairing with HomePod,
// Apple TV and other AirPlay 2 receivers starts with (PairingSRP.swift). Apple's frameworks give no public big-number
// type, so this is the small part of one that SRP needs: multiply, subtract and raise to a power, all modulo N, by
// Montgomery multiplication. Values go in and come out as big-endian bytes.
//
// It is not constant-time. What it works on is a key made fresh for one pairing and a PIN shown on the receiver's own
// screen, on the listener's own Mac; nothing here is a long-lived secret.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

struct ModularArithmetic: Sendable {
    /// 64-bit digits, least significant first.
    typealias Limbs = [UInt64]

    /// The modulus's length in bytes; every result is this long (zero-padded at the front).
    let byteCount: Int
    private let modulus: Limbs
    /// −N⁻¹ mod 2⁶⁴.
    private let inverse: UInt64
    /// R mod N and R² mod N, where R is 2 to the power of 64 × the number of digits.
    private let montgomeryOne: Limbs
    private let montgomerySquare: Limbs

    /// nil unless `modulus` is odd and more than one byte long.
    init?(modulus bytes: Data) {
        let trimmed = [UInt8](bytes.drop(while: { $0 == 0 }))
        guard trimmed.count > 1, let last = trimmed.last, last & 1 == 1 else { return nil }
        byteCount = trimmed.count
        let count = (trimmed.count + 7) / 8
        let n = Self.limbs(trimmed, count: count)
        modulus = n
        // Newton's steps double the number of right bits each time: 1, 2, 4 … 64.
        var x = n[0]
        for _ in 0..<6 { x = x &* (2 &- n[0] &* x) }
        inverse = 0 &- x
        var r = Limbs(repeating: 0, count: count)
        r[0] = 1
        for _ in 0..<(64 * count) { Self.double(&r, modulus: n) }
        montgomeryOne = r
        for _ in 0..<(64 * count) { Self.double(&r, modulus: n) }
        montgomerySquare = r
    }

    /// base to the power of exponent, modulo N.
    func power(_ base: Data, _ exponent: Data) -> Data {
        let b = multiply(reduce(base), montgomerySquare)
        var result = montgomeryOne
        for byte in exponent {
            for bit in stride(from: 7, through: 0, by: -1) {
                result = multiply(result, result)
                if (byte >> UInt8(bit)) & 1 == 1 { result = multiply(result, b) }
            }
        }
        return bytes(multiply(result, plainOne))
    }

    /// a × b modulo N.
    func product(_ a: Data, _ b: Data) -> Data {
        let x = multiply(reduce(a), montgomerySquare)
        return bytes(multiply(x, reduce(b)))
    }

    /// a − b modulo N.
    func difference(_ a: Data, _ b: Data) -> Data {
        var x = reduce(a)
        let y = reduce(b)
        var borrow: UInt64 = 0
        for i in 0..<x.count {
            let (first, b1) = x[i].subtractingReportingOverflow(y[i])
            let (second, b2) = first.subtractingReportingOverflow(borrow)
            x[i] = second
            borrow = (b1 || b2) ? 1 : 0
        }
        if borrow == 1 {
            var carry: UInt64 = 0
            for i in 0..<x.count {
                let (first, c1) = x[i].addingReportingOverflow(modulus[i])
                let (second, c2) = first.addingReportingOverflow(carry)
                x[i] = second
                carry = (c1 || c2) ? 1 : 0
            }
        }
        return bytes(x)
    }

    /// Whether `a` is a multiple of N (zero included).
    func isZero(_ a: Data) -> Bool {
        reduce(a).allSatisfy { $0 == 0 }
    }

    // MARK: - Digits

    private var plainOne: Limbs {
        var one = Limbs(repeating: 0, count: modulus.count)
        one[0] = 1
        return one
    }

    private static func limbs(_ bytes: [UInt8], count: Int) -> Limbs {
        var out = Limbs(repeating: 0, count: count)
        var index = 0
        for byte in bytes.reversed() {
            out[index / 8] |= UInt64(byte) << UInt64((index % 8) * 8)
            index += 1
        }
        return out
    }

    private func bytes(_ limbs: Limbs) -> Data {
        var out = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<byteCount {
            out[byteCount - 1 - i] = UInt8(truncatingIfNeeded: limbs[i / 8] >> UInt64((i % 8) * 8))
        }
        return Data(out)
    }

    private static func atLeast(_ a: Limbs, _ modulus: Limbs) -> Bool {
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != modulus[i] { return a[i] > modulus[i] }
        return true
    }

    private static func subtract(_ a: inout Limbs, _ modulus: Limbs) {
        var borrow: UInt64 = 0
        for i in 0..<a.count {
            let (first, b1) = a[i].subtractingReportingOverflow(modulus[i])
            let (second, b2) = first.subtractingReportingOverflow(borrow)
            a[i] = second
            borrow = (b1 || b2) ? 1 : 0
        }
    }

    /// `a` (below N) becomes 2a modulo N.
    private static func double(_ a: inout Limbs, modulus: Limbs) {
        var carry: UInt64 = 0
        for i in 0..<a.count {
            let next = a[i] >> 63
            a[i] = (a[i] << 1) | carry
            carry = next
        }
        if carry == 1 || atLeast(a, modulus) { subtract(&a, modulus) }
    }

    /// Any number of bytes, brought below N a bit at a time.
    private func reduce(_ bytes: Data) -> Limbs {
        var r = Limbs(repeating: 0, count: modulus.count)
        for byte in bytes {
            for bit in stride(from: 7, through: 0, by: -1) {
                Self.double(&r, modulus: modulus)
                guard (byte >> UInt8(bit)) & 1 == 1 else { continue }
                // r is below N, so adding one can't run past the top digit.
                for i in 0..<r.count {
                    r[i] = r[i] &+ 1
                    if r[i] != 0 { break }
                }
                if Self.atLeast(r, modulus) { Self.subtract(&r, modulus) }
            }
        }
        return r
    }

    /// Montgomery's product: a × b ÷ R modulo N, for a and b below N.
    private func multiply(_ a: Limbs, _ b: Limbs) -> Limbs {
        let n = modulus.count
        var t = Limbs(repeating: 0, count: n + 2)
        for i in 0..<n {
            var carry: UInt64 = 0
            for j in 0..<n {
                let (high, low) = a[j].multipliedFullWidth(by: b[i])
                let (first, c1) = t[j].addingReportingOverflow(low)
                let (second, c2) = first.addingReportingOverflow(carry)
                t[j] = second
                carry = high &+ (c1 ? 1 : 0) &+ (c2 ? 1 : 0)
            }
            let (top, overflow) = t[n].addingReportingOverflow(carry)
            t[n] = top
            t[n + 1] = overflow ? 1 : 0

            let m = t[0] &* inverse
            let (high0, low0) = m.multipliedFullWidth(by: modulus[0])
            let (_, c0) = t[0].addingReportingOverflow(low0)
            carry = high0 &+ (c0 ? 1 : 0)
            for j in 1..<n {
                let (high, low) = m.multipliedFullWidth(by: modulus[j])
                let (first, c1) = t[j].addingReportingOverflow(low)
                let (second, c2) = first.addingReportingOverflow(carry)
                t[j - 1] = second
                carry = high &+ (c1 ? 1 : 0) &+ (c2 ? 1 : 0)
            }
            let (last, c3) = t[n].addingReportingOverflow(carry)
            t[n - 1] = last
            t[n] = t[n + 1] &+ (c3 ? 1 : 0)
        }
        var result = Limbs(t[0..<n])
        if t[n] != 0 || Self.atLeast(result, modulus) { Self.subtract(&result, modulus) }
        return result
    }
}
