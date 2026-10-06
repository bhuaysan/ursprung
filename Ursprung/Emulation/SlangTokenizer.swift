// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Splits slang (GLSL 4.50 with RetroArch pragmas) into the ranges the
/// source editor colours. Ranges are UTF-16 based, like `NSString`.
nonisolated enum SlangTokenizer {
    enum Kind: Hashable, Sendable {
        case comment
        case keyword
        case type
        /// Built-in functions and variables (`texture`, `gl_Position`, …).
        case builtin
        case number
        /// `#version`, `#define`, `#if`, …
        case directive
        /// `#pragma parameter|stage|name|format` and `#include`: RetroArch's own lines.
        case pragma
        /// The quoted part of `#include "…"` and parameter labels.
        case string
    }

    struct Token: Hashable, Sendable {
        let kind: Kind
        let range: NSRange
    }

    static func tokens(in text: String) -> [Token] {
        let units = Array(text.utf16)
        var tokens: [Token] = []
        var index = 0
        var atLineStart = true

        func add(_ kind: Kind, _ start: Int, _ end: Int) {
            if end > start { tokens.append(Token(kind: kind, range: NSRange(location: start, length: end - start))) }
        }

        while index < units.count {
            let unit = units[index]
            if unit == newline {
                atLineStart = true
                index += 1
                continue
            }
            if unit == space || unit == tab || unit == carriageReturn {
                index += 1
                continue
            }
            let lineStart = atLineStart
            atLineStart = false

            // Comments
            if unit == slash, index + 1 < units.count {
                if units[index + 1] == slash {
                    let start = index
                    while index < units.count, units[index] != newline { index += 1 }
                    add(.comment, start, index)
                    continue
                }
                if units[index + 1] == star {
                    let start = index
                    index += 2
                    while index < units.count, !(units[index] == star && index + 1 < units.count && units[index + 1] == slash) {
                        index += 1
                    }
                    index = min(index + 2, units.count)
                    add(.comment, start, index)
                    continue
                }
            }

            // Preprocessor lines
            if unit == hash, lineStart {
                let start = index
                index += 1
                while index < units.count, units[index] == space || units[index] == tab { index += 1 }
                let wordStart = index
                while index < units.count, isIdentifier(units[index]) { index += 1 }
                let directive = String(decoding: units[wordStart..<index], as: UTF16.self)
                if directive == "include" {
                    add(.pragma, start, index)
                    index = scanString(units, from: index, into: &tokens)
                } else if directive == "pragma" {
                    let save = index
                    while index < units.count, units[index] == space || units[index] == tab { index += 1 }
                    let nameStart = index
                    while index < units.count, isIdentifier(units[index]) { index += 1 }
                    let name = String(decoding: units[nameStart..<index], as: UTF16.self)
                    if retroArchPragmas.contains(name) {
                        add(.pragma, start, index)
                        if name == "parameter" {
                            // The label after the parameter's name.
                            while index < units.count, units[index] == space || units[index] == tab { index += 1 }
                            while index < units.count, isIdentifier(units[index]) { index += 1 }
                            index = scanString(units, from: index, into: &tokens)
                        }
                    } else {
                        add(.directive, start, save)
                        index = save
                    }
                } else {
                    add(.directive, start, index)
                }
                continue
            }

            // Numbers: 1, 1.0, .5, 1e-3, 0x1F, 1u, 1.0f
            if isDigit(unit) || (unit == dot && index + 1 < units.count && isDigit(units[index + 1])) {
                let start = index
                if unit == zero, index + 1 < units.count, units[index + 1] | 0x20 == x {
                    index += 2
                    while index < units.count, isHexDigit(units[index]) { index += 1 }
                } else {
                    while index < units.count, isDigit(units[index]) || units[index] == dot { index += 1 }
                    if index < units.count, units[index] | 0x20 == e {
                        index += 1
                        if index < units.count, units[index] == plus || units[index] == minus { index += 1 }
                        while index < units.count, isDigit(units[index]) { index += 1 }
                    }
                }
                while index < units.count, isLetter(units[index]) { index += 1 }
                add(.number, start, index)
                continue
            }

            // Words
            if isIdentifierStart(unit) {
                let start = index
                while index < units.count, isIdentifier(units[index]) { index += 1 }
                let word = String(decoding: units[start..<index], as: UTF16.self)
                if keywords.contains(word) {
                    add(.keyword, start, index)
                } else if types.contains(word) {
                    add(.type, start, index)
                } else if builtins.contains(word) || word.hasPrefix("gl_") {
                    add(.builtin, start, index)
                }
                continue
            }

            index += 1
        }
        return tokens
    }

    /// The quoted string after `index` on the same line, if any.
    private static func scanString(_ units: [UInt16], from start: Int, into tokens: inout [Token]) -> Int {
        var index = start
        while index < units.count, units[index] == space || units[index] == tab { index += 1 }
        guard index < units.count, units[index] == quote else { return start }
        let stringStart = index
        index += 1
        while index < units.count, units[index] != quote, units[index] != newline { index += 1 }
        if index < units.count, units[index] == quote { index += 1 }
        tokens.append(Token(kind: .string, range: NSRange(location: stringStart, length: index - stringStart)))
        return index
    }

    // MARK: Characters

    private static let newline = ascii("\n"), carriageReturn = ascii("\r")
    private static let space = ascii(" "), tab = ascii("\t")
    private static let slash = ascii("/"), star = ascii("*"), hash = ascii("#")
    private static let dot = ascii("."), quote = ascii("\"")
    private static let plus = ascii("+"), minus = ascii("-")
    private static let zero = ascii("0"), x = ascii("x"), e = ascii("e")

    private static func ascii(_ scalar: Unicode.Scalar) -> UInt16 { UInt16(scalar.value) }

    private static func isDigit(_ unit: UInt16) -> Bool { unit >= 48 && unit <= 57 }
    private static func isLetter(_ unit: UInt16) -> Bool { (unit | 0x20) >= 97 && (unit | 0x20) <= 122 }
    private static func isHexDigit(_ unit: UInt16) -> Bool { isDigit(unit) || ((unit | 0x20) >= 97 && (unit | 0x20) <= 102) }
    private static func isIdentifierStart(_ unit: UInt16) -> Bool { isLetter(unit) || unit == 95 }
    private static func isIdentifier(_ unit: UInt16) -> Bool { isIdentifierStart(unit) || isDigit(unit) }

    // MARK: Words

    private static let retroArchPragmas: Set<String> = ["parameter", "stage", "name", "format"]

    private static let keywords: Set<String> = [
        "attribute", "break", "buffer", "case", "centroid", "coherent", "const", "continue", "default", "discard", "do",
        "else", "false", "flat", "for", "highp", "if", "in", "inout", "invariant", "layout", "lowp", "mediump",
        "noperspective", "out", "patch", "precise", "precision", "readonly", "restrict", "return", "sample",
        "shared", "smooth", "struct", "subroutine", "switch", "true", "uniform", "varying", "volatile", "while",
        "writeonly",
        // layout qualifiers
        "binding", "location", "push_constant", "set", "std140", "std430",
    ]

    private static let types: Set<String> = {
        var types: Set<String> = ["void", "bool", "int", "uint", "float", "double", "atomic_uint"]
        for prefix in ["", "b", "i", "u", "d"] {
            for size in 2...4 { types.insert("\(prefix)vec\(size)") }
        }
        for prefix in ["", "d"] {
            for columns in 2...4 {
                types.insert("\(prefix)mat\(columns)")
                for rows in 2...4 { types.insert("\(prefix)mat\(columns)x\(rows)") }
            }
        }
        for prefix in ["", "i", "u"] {
            for kind in ["sampler", "texture", "image"] {
                for shape in ["1D", "2D", "3D", "Cube", "2DRect", "1DArray", "2DArray", "CubeArray", "Buffer", "2DMS",
                              "2DMSArray"] {
                    types.insert("\(prefix)\(kind)\(shape)")
                }
            }
        }
        types.formUnion(["sampler", "sampler2DShadow", "samplerCubeShadow", "sampler2DArrayShadow"])
        return types
    }()

    private static let builtins: Set<String> = [
        "abs", "acos", "acosh", "all", "any", "asin", "asinh", "atan", "atanh", "ceil", "clamp", "cos", "cosh", "cross",
        "dFdx", "dFdy", "degrees", "determinant", "distance", "dot", "equal", "exp", "exp2", "faceforward", "floor",
        "fma", "fract", "fwidth", "greaterThan", "greaterThanEqual", "inverse", "inversesqrt", "isinf", "isnan",
        "length", "lessThan", "lessThanEqual", "log", "log2", "matrixCompMult", "max", "min", "mix", "mod", "modf",
        "normalize", "not", "notEqual", "outerProduct", "pow", "radians", "reflect", "refract", "round",
        "roundEven", "sign", "sin", "sinh", "smoothstep", "sqrt", "step", "tan", "tanh", "texelFetch",
        "texelFetchOffset", "texture", "textureGrad", "textureLod", "textureLodOffset", "textureOffset",
        "textureProj", "textureSize", "textureGather", "transpose", "trunc", "floatBitsToInt", "floatBitsToUint",
        "intBitsToFloat", "uintBitsToFloat", "packUnorm4x8", "unpackUnorm4x8", "bitfieldExtract",
    ]
}
