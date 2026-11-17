//
// Vespertine: the building blocks of pairing with HomePod, Apple TV and other AirPlay 2 receivers, each against values
// worked out independently: the big-number arithmetic against Python's own integers, SRP-6a (3072-bit group, SHA-512)
// against the srptools library set up the way HomeKit-style pairing uses it, the key derivation against HMAC-SHA-512
// by hand (RFC 5869), and the sealed messages against the `cryptography` library's ChaCha20-Poly1305.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import CryptoKit
import Foundation
import Testing
@testable import VespertineAirPlay

private let smallModulus = "f123456789abcdef0fedcba987654321deadbeefcafef00d"
private let numberA = "1f40fc92da241694750979ee6cf582f2d5d7d28e18335de05abc54d0560e0f5302860c652bf08d560252aa5e74210546f369fbbbce8c12cfc7957b2652fe9a75"
private let numberB = "5267768822ee624d48fce15ec5ca79cbd602cb7f4c2157a516556991f22ef8c7b5ef7b18d1ff41c59370efb0858651d44a936c11b7b144c48fe04df3c6a3e8da"
private let exponent = "3f79bb7b435b05321651daefd374cdc681dc06faa65e374e38337b88ca046dea"

// One SRP exchange (PIN 3939), also played back by the pairing message tests.
let srpSecret = "f28e6bb66132a566dabfbcdf5d6dce5ce512d4584caf9dbf78c858e299111ae6"
let srpSalt = "ceb20772e0c9d240c75eb26b0e37abee"
let srpServerKey =
    "d55070d10efb2fdc71c25d8f304c0ce504597cee3d3d8b5d45ac3ce8a242930a0f45a584d8412417dbfd5c0dd90c975ce343dbea" +
    "4e966926952019a1cd06ca357e7dd8106e903492c9beda8bc8e62dd891f99595c90bba3d00d9559aeb146da7e8829661dcf76ce0" +
    "19b21add02cccd4b080d5bd12a727891f8531c4d0ce9e3ac4fd9bc1ae4e3c5f049d932f7058c8fc17d23faf77d3c160fef0fefe0" +
    "142c07a1339096facbfb2c17e8be5fa8781c24e046f69b748ff435a06a9bc29b251ddaa5933163abe7601c8c6bc580ff526b8165" +
    "3d7b8d5d6f96705047fec898a872e37880014cccc9aee07cbb065e8627ec5ad9b3af4af2e5260b28d8a31d1f163dfd48ab719f68" +
    "d0e2608853dcef4d0903d6fa4953620cf34f6da527e389f9f7640d0adfa3d0db1ad3e9001810ec630d52f1057104a5232afb67b1" +
    "1477c02deb58071bd25b5196808b5a2a47d48e7be39c84617fc5b07028f399d4719ecb7290a714997c10c0e44da296caa2c21c6a" +
    "4d7ab0d5f59890e8c6267bbef7dc7f363ed6b27f"
let srpClientKey =
    "4b52121b838eb7323a73ef51b611b9476e273e4fcb7ca8270284c7a0af6579149f2c544de10ed20a7dbec91564d24c9d03b39b7c" +
    "42e2b6257540b128d89a6c0fd53bbeada8818c47e26758b7d2d512c4482dfdccd93cd044b8cadeaa5d3e14450a7f313bc086c633" +
    "91e8b78c8c7766377c7cf646cb9c44e57d93f1250bff331da24580afb32810b3c4490c30c5a945614637644fc6b8696804d8646d" +
    "bba5ba31dac5d463cb3e12c65c84048167b83828251f59d83f7606417da408953b9fbc162cc3c3623a025b7fa775cfdff1a1a01d" +
    "bc05bfd4ad7e7227e34a3bd624fe1878b63cdd40e6b6c8fc376014413f18e7a8f2f96f5f9d627cf42f883df7ed5a94c351815c6b" +
    "8772b90e49c390c38072353d39d329d1a80daa00543098c90848482b6d33602c4b68af01220e080751a23192609f43787724599d" +
    "a12ab2eefa78e57322b38a0a79a4bfd032089d1ec8def8e220fe0a5149760fc79fe8d01bd670cb2003e98dd7d5a8ff731dc2b171" +
    "05dabf4c7c2565d0898d20b2ffc1cddba5d88fda"
let srpKey = "7f37ffae4933eac983cbe5285f19ab488b2997d48afddcd0ba9714c4cf0fe546fe062318ab756699e6fcb711cd15d34e5e6d9a93f7c3fc784e5bce62ca3ebfcb"
let srpProof = "717aacafdb8822badcf8abcafc3ee546bd1cb8961b144e16415573f43f10ffe85635b124c1ab99b4c3159e81de5d84f3777280ef08f1682897c8a62ff66b668e"
let srpServerProof = "c6736ea5bf5e6bf825de59b042a848db6bc0917086b46f868ab17b2cff8272b14dcf05e1a66828edbb73a3af4597f46401b4db9230c742b8809f69e8f6525825"
private let powerInGroup =
    "4b10da748e1a97eefbd44697beff970ecc6f0c9a73c559205016d46d4dac42e55e028adff8e7e83bf940e77b55d81dcb974921d7" +
    "11f47bafd157880329cc757cb6dbdee6bea2af72bc352a7e9c56d294b8e6552e3d852c6d04093f732511a354e9a4560ce01263d5" +
    "e4af38cd206aa9729019e9e0d20070522eadaf28e53e72ad11fe89d7f1587c97d9e18268481bb3d8b20314c8f665c9b0efd51983" +
    "bca3653c54c26bbb36c69371495379907a84b7900255feb98370a8e168235fd29d28b53b263bc55da444d5f3ef362ceb8ace57ff" +
    "06daec2cf5bf0fdd6ed1990628c0fb327e6504943268b6c332c204e90e17d7f23c99404992f43127d0892c43c9eb8198981716dc" +
    "b1665f3c8bed9b98780772222bdde99a7ceff6a5777b796c1302dd76b31e46e9a939331b098c4482a33ebe00e784ea60d013abb5" +
    "a3613cbd07c97c30afa35eb8d9a41b5a69309f21404d1b69808d903b43ed4fcc9f24464850068553b1f9f2f27ab0d13f11204bcf" +
    "ef2eff674fca1c6ab613597cb79eeead857433bd"

@Suite("AirPlay pairing building blocks")
struct PairingPrimitivesTests {
    @Test("Multiply, subtract and raise to a power modulo a 192-bit number")
    func smallArithmetic() throws {
        let m = try #require(ModularArithmetic(modulus: hex(smallModulus)))
        #expect(m.byteCount == 24)
        #expect(m.power(hex(numberA), hex(exponent)) == hex("3501f8f66ef9d37c4b8dc8b109b7c38ef86a79cbe78d166f"))
        #expect(m.product(hex(numberA), hex(numberB)) == hex("1ba7f8248a13cdba106d956f1198086a91d863329ca6e94f"))
        #expect(m.difference(hex(numberA), hex(numberB)) == hex("738d0c1868e23feceb2176eab86bb6e51d18d5235ae4264b"))
        #expect(m.difference(hex(numberB), hex(numberA)) == hex("7d96394f20c98e0224cc54becef98c3cc194e9cc701ac9c2"))
        // Anything to the power of nothing is one; the modulus itself counts as zero.
        #expect(m.power(hex(numberA), Data()) == hex("000000000000000000000000000000000000000000000001"))
        #expect(m.isZero(hex(smallModulus)) && m.isZero(Data([0])) && !m.isZero(Data([1])))
        #expect(m.difference(hex(numberA), hex(numberA)) == Data(repeating: 0, count: 24))
    }

    @Test("A modulus has to be odd and longer than a byte; one that fits a single 64-bit digit works too")
    func moduli() throws {
        #expect(ModularArithmetic(modulus: hex("f123456789abcdef0fedcba987654321deadbeefcafef00c")) == nil)
        #expect(ModularArithmetic(modulus: Data([7])) == nil)
        #expect(ModularArithmetic(modulus: Data()) == nil)
        // 65537: 3¹⁶ is 43046721, which leaves 54449.
        let small = try #require(ModularArithmetic(modulus: hex("00010001")))
        #expect(small.byteCount == 3)
        #expect(small.power(Data([3]), Data([16])) == hex("00d4b1"))
        #expect(small.product(hex("ffff"), hex("ffff")) == hex("000004"))
    }

    @Test("Arithmetic in the 3072-bit group that pairing uses")
    func groupArithmetic() throws {
        let m = try #require(ModularArithmetic(modulus: PairingSRP.modulus))
        #expect(m.byteCount == 384)
        #expect(m.power(hex(numberA), hex(exponent)) == hex(powerInGroup))
        // (N − 1)(N − 2) is 2 modulo N.
        var one = [UInt8](PairingSRP.modulus), two = [UInt8](PairingSRP.modulus)
        one[383] -= 1
        two[383] -= 2
        #expect(m.product(Data(one), Data(two)) == Data(repeating: 0, count: 383) + Data([2]))
        #expect(m.difference(Data([1]), Data([2])) == Data(one))
    }

    @Test("SRP: the public key, shared key and both proofs match an independent implementation")
    func srp() throws {
        let client = PairingSRP(password: "3939", secret: hex(srpSecret))
        #expect(client.publicKey == hex(srpClientKey))
        let session = try #require(client.session(salt: hex(srpSalt), serverPublicKey: hex(srpServerKey)))
        #expect(session.key == hex(srpKey))
        #expect(session.proof == hex(srpProof))
        #expect(session.serverProof == hex(srpServerProof))
        #expect(session.accepts(hex(srpServerProof)))
        var wrong = hex(srpServerProof)
        wrong[63] ^= 1
        #expect(!session.accepts(wrong))
        #expect(!session.accepts(Data()))
    }

    @Test("SRP: another PIN gives another key and proof, and a fresh pairing makes its own secret")
    func srpOtherPIN() throws {
        let client = PairingSRP(password: "1234", secret: hex(srpSecret))
        // The public key doesn't depend on the PIN.
        #expect(client.publicKey == hex(srpClientKey))
        let session = try #require(client.session(salt: hex(srpSalt), serverPublicKey: hex(srpServerKey)))
        #expect(session.key != hex(srpKey))
        #expect(session.proof != hex(srpProof))
        #expect(!session.accepts(hex(srpServerProof)))
        let first = PairingSRP(password: "3939"), second = PairingSRP(password: "3939")
        #expect(first.publicKey != second.publicKey)
        #expect(first.publicKey.count > 300)
    }

    @Test("SRP: a receiver's key that is zero or a multiple of the modulus is refused")
    func srpBadServerKey() {
        let client = PairingSRP(password: "3939", secret: hex(srpSecret))
        #expect(client.session(salt: hex(srpSalt), serverPublicKey: Data()) == nil)
        #expect(client.session(salt: hex(srpSalt), serverPublicKey: Data(repeating: 0, count: 384)) == nil)
        #expect(client.session(salt: hex(srpSalt), serverPublicKey: PairingSRP.modulus) == nil)
        #expect(client.session(salt: hex(srpSalt), serverPublicKey: Data(repeating: 1, count: 385)) == nil)
    }

    @Test("TLV8: items in order, a long value cut into pieces of 255 and put back together")
    func tlv() throws {
        let start = PairingTLV([.method: Data([0]), .state: Data([1]), .flags: Data([0x10])])
        #expect(start.encoded == hex("000100060101130110"))
        #expect(PairingTLV(decoding: start.encoded) == start)
        #expect(start.byte(.state) == 1 && start[.salt] == nil)

        let key = Data((0..<600).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        var message = PairingTLV()
        message.append(.state, 3)
        message.append(.publicKey, key)
        message.append(.proof, Data())
        let bytes = message.encoded
        // 600 bytes are 255 + 255 + 90, each piece with its two-byte header.
        #expect(bytes.count == 3 + 600 + 6 + 2)
        #expect([bytes[3], bytes[4], bytes[260], bytes[261], bytes[517], bytes[518]] == [3, 255, 3, 255, 3, 90])
        let back = try #require(PairingTLV(decoding: bytes))
        #expect(back == message)
        #expect(back[.publicKey] == key)
        #expect(back[.proof] == Data())
    }

    @Test("TLV8: two short items of one type stay two; bytes that end inside an item are refused")
    func tlvEdges() throws {
        let two = try #require(PairingTLV(decoding: hex("0101aa0101bb")))
        #expect(two.items.count == 2)
        #expect(two[.identifier] == Data([0xAA]))
        #expect(try #require(PairingTLV(decoding: Data())).items.isEmpty)
        #expect(PairingTLV(decoding: hex("06")) == nil)
        #expect(PairingTLV(decoding: hex("060201")) == nil)
        #expect(two.byte(.state) == nil)
        // A type this app has no name for is kept as it came.
        let unknown = try #require(PairingTLV(decoding: hex("7f0101")))
        #expect(unknown.items == [PairingTLV.Item(type: 0x7F, value: Data([1]))])
        #expect(unknown.encoded == hex("7f0101"))
    }

    @Test("Keys are derived with HKDF-SHA-512 and messages sealed with ChaCha20-Poly1305 under pairing's nonces")
    func sealing() throws {
        let key = PairingCrypto.key(secret: hex(srpKey), salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        #expect(key.withUnsafeBytes { Data($0) } == hex("1a7f79ea3432fc7ccb26b2ef777745c43fde89d2aa16142f7fa53769be9474c7"))
        #expect(PairingCrypto.nonce("PS-Msg05") == hex("0000000050532d4d73673035"))
        #expect(PairingCrypto.nonce(counter: 7) == hex("000000000700000000000000"))
        #expect(PairingCrypto.nonce(counter: 0x0102_0304_0506_0708) == hex("000000000807060504030201"))

        let plain = Data("Vespertine pairs with the receiver".utf8)
        let sealed = try PairingCrypto.seal(plain, key: key, nonce: PairingCrypto.nonce("PS-Msg05"))
        #expect(sealed == hex("d83dad663034a4069c693651e06a4062398b449106aa9897e6f9a35f41c3194fb2cbefa1d67ffe6026a3618a018acf13f6f1"))
        #expect(try PairingCrypto.open(sealed, key: key, nonce: PairingCrypto.nonce("PS-Msg05")) == plain)
        // The eight-byte form of a nonce is padded the same way.
        #expect(try PairingCrypto.open(sealed, key: key, nonce: Data("PS-Msg05".utf8)) == plain)

        let counted = try PairingCrypto.seal(plain, key: key, nonce: PairingCrypto.nonce(counter: 7), authenticating: hex("2200"))
        #expect(counted == hex("e3bb0b02851e05894144d94dc04835cb730a6577ed2020c0346b2a3d0920e30f09614a0ca20b5ef812908fe4434faa6a285d"))
        #expect(try PairingCrypto.open(counted, key: key, nonce: PairingCrypto.nonce(counter: 7), authenticating: hex("2200")) == plain)
    }

    @Test("A sealed message that was changed, or opened with the wrong nonce, key or extra bytes, is refused")
    func tampering() throws {
        let key = PairingCrypto.key(secret: hex(srpKey), salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let other = PairingCrypto.key(secret: hex(srpKey), salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
        let nonce = PairingCrypto.nonce("PS-Msg05")
        let sealed = try PairingCrypto.seal(Data("hello".utf8), key: key, nonce: nonce)
        // What is sealed counts from zero, whatever CryptoKit's own pieces do.
        #expect(sealed.startIndex == 0 && sealed.count == 5 + PairingCrypto.tagLength)
        var changed = sealed
        changed[0] ^= 1
        #expect(throws: PairingCrypto.Failure.notAuthentic) { try PairingCrypto.open(changed, key: key, nonce: nonce) }
        #expect(throws: PairingCrypto.Failure.notAuthentic) { try PairingCrypto.open(sealed, key: other, nonce: nonce) }
        #expect(throws: PairingCrypto.Failure.notAuthentic) { try PairingCrypto.open(sealed, key: key, nonce: PairingCrypto.nonce("PS-Msg06")) }
        #expect(throws: PairingCrypto.Failure.notAuthentic) { try PairingCrypto.open(sealed, key: key, nonce: nonce, authenticating: Data([1])) }
        #expect(throws: PairingCrypto.Failure.malformed) { try PairingCrypto.open(Data([1, 2, 3]), key: key, nonce: nonce) }
        #expect(throws: PairingCrypto.Failure.malformed) { try PairingCrypto.seal(Data(), key: key, nonce: Data(repeating: 0, count: 13)) }
    }
}
