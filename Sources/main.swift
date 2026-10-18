import AppKit
import ApplicationServices
import Foundation

// This engine uses native accessibility only. It never launches an app, prompts
// for privileges, records screenshots, or falls back to coordinate interaction.
// Snapshot identifiers are local to one observation, never persistent handles.

enum EngineError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let value) = self { return value }; return "Engine error" }
}

let schemaVersion = "native-ax-engine/1"
let messagingTimeout: Float = 2.0
let retryLimit = 2
let hierarchyNames: Set<String> = [
    "AXChildren", "AXChildrenInNavigationOrder", "AXVisibleChildren", "AXWindows",
    "AXMenuBar", "AXExtrasMenuBar", "AXSheets", "AXContents", "AXRows", "AXColumns",
    "AXTabs", "AXDisclosedRows", "AXRowHeaderUIElements", "AXColumnHeaderUIElements", "AXSplitters"
]
let arrayHierarchyNames = hierarchyNames.subtracting(["AXMenuBar", "AXExtrasMenuBar"])
let identityAttributes = ["AXRole", "AXSubrole", "AXIdentifier", "AXTitle", "AXDescription", "AXHelp"]
let excludedLifecycleIdentifiers: Set<String> = [
    // Actual native Apple-menu selectors, including confirmation-free variants.
    "_restartRequested:", "_restartNowRequested:",
    "_shutDownRequested:", "_shutDownNowRequested:", "_shutdownRequested:", "_shutdownNowRequested:",
    "_logOutRequested:", "_logOutNowRequested:", "_logoutRequested:", "_logoutNowRequested:",
    "_sleepRequested:", "_lockScreenRequested:", "_lockScreenMenuRequested:",
    "_forceQuitPanelRequested:", "_forceQuitRequested:"
]

func validateTransitionExpectation(_ signature: [String: Any], expectedTitle: String?, expectedIdentifier: String?) throws {
    guard expectedTitle != nil || expectedIdentifier != nil else {
        throw EngineError.message("A transition requires --expect-title or --expect-identifier; a numeric node ID does not establish the intended control.")
    }
    if let expectedTitle {
        guard !expectedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              signature["AXTitle"] as? String == expectedTitle else {
            throw EngineError.message("Transition refused: the native title does not exactly match --expect-title.")
        }
    }
    if let expectedIdentifier {
        guard !expectedIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              signature["AXIdentifier"] as? String == expectedIdentifier else {
            throw EngineError.message("Transition refused: the native identifier does not exactly match --expect-identifier.")
        }
    }
    if let identifier = signature["AXIdentifier"] as? String, excludedLifecycleIdentifiers.contains(identifier) {
        throw EngineError.message("Transition refused: native system lifecycle controls are outside this application's tree-extraction scope.")
    }
}

func now() -> String { ISO8601DateFormatter().string(from: Date()) }

// AXTextMarker's payload is defined by the application that produced it. The
// public AXUIElement.h APIs expose the bytes and range endpoints; they do not
// give a universal character offset or permit interpreting the payload as one.
// Preserve every byte instead of treating these successful reads as failures.
enum NativeTextCodec {
    typealias TypeIDFunction = @convention(c) () -> CFTypeID
    typealias LengthFunction = @convention(c) (CFTypeRef) -> CFIndex
    typealias BytesFunction = @convention(c) (CFTypeRef) -> UnsafePointer<UInt8>?
    typealias CopyFunction = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    typealias CreateMarkerFunction = @convention(c) (CFAllocator?, UnsafePointer<UInt8>, CFIndex) -> Unmanaged<CFTypeRef>?
    typealias CreateRangeFunction = @convention(c) (CFAllocator?, CFTypeRef, CFTypeRef) -> Unmanaged<CFTypeRef>?

    struct APIs {
        var markerTypeID: TypeIDFunction?
        var markerLength: LengthFunction?
        var markerBytes: BytesFunction?
        var rangeTypeID: TypeIDFunction?
        var copyStart: CopyFunction?
        var copyEnd: CopyFunction?
    }

    static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        // Darwin's RTLD_DEFAULT macro is ((void *) -2); Swift cannot import
        // that pointer-valued macro. Resolve only documented public symbols.
        guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(address, to: type)
    }

    static let native = APIs(
        markerTypeID: symbol("AXTextMarkerGetTypeID", as: TypeIDFunction.self),
        markerLength: symbol("AXTextMarkerGetLength", as: LengthFunction.self),
        markerBytes: symbol("AXTextMarkerGetBytePtr", as: BytesFunction.self),
        rangeTypeID: symbol("AXTextMarkerRangeGetTypeID", as: TypeIDFunction.self),
        copyStart: symbol("AXTextMarkerRangeCopyStartMarker", as: CopyFunction.self),
        copyEnd: symbol("AXTextMarkerRangeCopyEndMarker", as: CopyFunction.self)
    )

    static func marker(_ value: CFTypeRef, type: CFTypeID, apis: APIs, warning: (String) -> Void) -> [String: Any] {
        var result: [String: Any] = ["type": "AXTextMarker", "cf_type_id": Int(type)]
        guard let getLength = apis.markerLength, let getBytes = apis.markerBytes else {
            result["serialization_status"] = "api_unavailable"
            warning("Public text-marker byte accessors are unavailable at runtime; the native marker type is retained.")
            return result
        }
        let length = getLength(value)
        result["byte_length"] = length
        guard length >= 0 else {
            result["serialization_status"] = "invalid_byte_length"
            warning("AXTextMarkerGetLength returned a negative byte length.")
            return result
        }
        // An empty payload needs no pointer dereference. A nonempty payload
        // must have a valid byte pointer while its retained CF object is alive.
        if length == 0 {
            result["bytes_base64"] = ""
        } else if let bytes = getBytes(value) {
            result["bytes_base64"] = Data(bytes: bytes, count: length).base64EncodedString()
        } else {
            result["serialization_status"] = "missing_byte_pointer"
            warning("AXTextMarkerGetBytePtr returned no pointer for a nonempty marker.")
            return result
        }
        result["serialization_status"] = "captured"
        return result
    }

    static func encode(_ value: CFTypeRef, type: CFTypeID, apis: APIs = native, warning: (String) -> Void) -> [String: Any]? {
        if let getMarkerID = apis.markerTypeID, type == getMarkerID() {
            return marker(value, type: type, apis: apis, warning: warning)
        }
        guard let getRangeID = apis.rangeTypeID, type == getRangeID() else { return nil }
        var result: [String: Any] = ["type": "AXTextMarkerRange", "cf_type_id": Int(type)]
        var complete = true
        for (name, copy) in [("start", apis.copyStart), ("end", apis.copyEnd)] {
            guard let copy else {
                result[name] = ["serialization_status": "api_unavailable"]
                warning("Public text-marker range \(name) accessor is unavailable at runtime.")
                complete = false
                continue
            }
            guard let retained = copy(value) else {
                result[name] = ["serialization_status": "missing_endpoint"]
                warning("Public text-marker range \(name) accessor returned no endpoint.")
                complete = false
                continue
            }
            // Copy functions return owned CF objects. Keep each endpoint alive
            // until its bytes are copied, then allow ARC to release it once.
            let endpoint = retained.takeRetainedValue()
            let endpointType = CFGetTypeID(endpoint)
            guard let getMarkerID = apis.markerTypeID, endpointType == getMarkerID() else {
                result[name] = ["serialization_status": "unexpected_endpoint_type", "cf_type_id": Int(endpointType)]
                warning("Public text-marker range \(name) accessor returned an unrecognized endpoint type.")
                complete = false
                continue
            }
            let encoded = marker(endpoint, type: endpointType, apis: apis, warning: warning)
            result[name] = encoded
            if encoded["serialization_status"] as? String != "captured" { complete = false }
        }
        result["serialization_status"] = complete ? "captured" : "partial"
        return result
    }

    // Entirely offline: construct CF marker objects using public APIs. No app
    // process, Accessibility permission, or native UI element is accessed.
    static func selfTest() throws -> Int {
        guard let createMarker = symbol("AXTextMarkerCreate", as: CreateMarkerFunction.self),
              let createRange = symbol("AXTextMarkerRangeCreate", as: CreateRangeFunction.self) else {
            throw EngineError.message("Offline text-marker fixtures require public marker constructor APIs.")
        }
        func makeMarker(_ bytes: [UInt8]) throws -> CFTypeRef {
            // Supply a valid pointer even for a zero-length payload.
            let storage = bytes.isEmpty ? [UInt8(0)] : bytes
            guard let marker = storage.withUnsafeBufferPointer({ createMarker(nil, $0.baseAddress!, bytes.count) }) else {
                throw EngineError.message("Cannot construct offline text-marker fixture.")
            }
            return marker.takeRetainedValue()
        }
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw EngineError.message("Offline text-marker fixture failed: \(message)") }
        }
        var passed = 0
        for bytes in [[UInt8(0)], Array(UInt8.min...UInt8.max)] {
            let object = try makeMarker(bytes)
            var warnings: [String] = []
            let value = encode(object, type: CFGetTypeID(object)) { warnings.append($0) }
            try check(value?["type"] as? String == "AXTextMarker" &&
                      value?["byte_length"] as? Int == bytes.count &&
                      value?["bytes_base64"] as? String == Data(bytes).base64EncodedString() &&
                      value?["serialization_status"] as? String == "captured" && warnings.isEmpty,
                      "marker bytes must round-trip exactly, including NUL and non-UTF8 data")
            passed += 1
        }
        let startBytes: [UInt8] = [0, 128, 255]
        let endBytes: [UInt8] = [254, 1, 0, 34]
        let start = try makeMarker(startBytes)
        let end = try makeMarker(endBytes)
        // The public constructor on this OS rejects empty payloads. Exercise
        // the valid zero-length accessor branch without inventing an app read.
        var emptyPayload = native
        emptyPayload.markerLength = { _ in 0 }
        emptyPayload.markerBytes = { _ in nil }
        var emptyWarnings: [String] = []
        let empty = encode(start, type: CFGetTypeID(start), apis: emptyPayload) { emptyWarnings.append($0) }
        try check(empty?["byte_length"] as? Int == 0 && empty?["bytes_base64"] as? String == "" &&
                  empty?["serialization_status"] as? String == "captured" && emptyWarnings.isEmpty,
                  "empty payload never dereferences a missing pointer")
        passed += 1
        guard let rangeOwned = createRange(nil, start, end) else {
            throw EngineError.message("Cannot construct offline text-marker range fixture.")
        }
        let range = rangeOwned.takeRetainedValue()
        var warnings: [String] = []
        let value = encode(range, type: CFGetTypeID(range)) { warnings.append($0) }
        let encodedStart = value?["start"] as? [String: Any]
        let encodedEnd = value?["end"] as? [String: Any]
        try check(JSONSerialization.isValidJSONObject(value ?? [:]) &&
                  value?["serialization_status"] as? String == "captured" && warnings.isEmpty &&
                  encodedStart?["bytes_base64"] as? String == Data(startBytes).base64EncodedString() &&
                  encodedEnd?["bytes_base64"] as? String == Data(endBytes).base64EncodedString(),
                  "range preserves both ordered endpoint payloads")
        passed += 1
        let string = "not a marker" as CFString
        try check(encode(string, type: CFGetTypeID(string)) { warnings.append($0) } == nil && warnings.isEmpty,
                  "unrelated CF types must not be classified as text markers")
        passed += 1
        var unavailable = native
        unavailable.markerBytes = nil
        warnings = []
        let missingBytes = encode(start, type: CFGetTypeID(start), apis: unavailable) { warnings.append($0) }
        try check(missingBytes?["serialization_status"] as? String == "api_unavailable" && warnings.count == 1,
                  "unavailable byte API stays explicit")
        passed += 1
        unavailable = native
        unavailable.copyEnd = nil
        warnings = []
        let missingEnd = encode(range, type: CFGetTypeID(range), apis: unavailable) { warnings.append($0) }
        let retainedStart = missingEnd?["start"] as? [String: Any]
        try check(missingEnd?["serialization_status"] as? String == "partial" && warnings.count == 1 &&
                  retainedStart?["bytes_base64"] as? String == Data(startBytes).base64EncodedString(),
                  "missing endpoint API preserves the other endpoint and exposes the gap")
        passed += 1
        return passed
    }
}

// Preserve native graphics values without converting colors to RGB or
// flattening paths. These functions operate on local CF values already read
// from the app; none requests an additional AX attribute or changes UI state.
enum NativeGraphicsCodec {
    static func bits(_ value: CGFloat) -> String { String(format: "%016llx", Double(value).bitPattern) }

    static func number(_ value: CGFloat) -> Any {
        let scalar = Double(value)
        if scalar.isFinite { return scalar }
        return ["type": "nonfinite_number",
                "value": scalar.isNaN ? "nan" : (scalar.sign == .minus ? "-infinity" : "infinity"),
                "ieee754_binary64": String(format: "%016llx", scalar.bitPattern)]
    }

    static func modelName(_ model: CGColorSpaceModel) -> String {
        switch model {
        case .unknown: return "unknown"
        case .monochrome: return "monochrome"
        case .rgb: return "rgb"
        case .cmyk: return "cmyk"
        case .lab: return "lab"
        case .deviceN: return "device_n"
        case .indexed: return "indexed"
        case .pattern: return "pattern"
        case .XYZ: return "xyz"
        @unknown default: return "unrecognized"
        }
    }

    static func colorSpace(_ space: CGColorSpace, ancestors: Set<UInt> = [], warning: (String) -> Void) -> ([String: Any], Bool) {
        let address = UInt(bitPattern: Unmanaged.passUnretained(space).toOpaque())
        var record: [String: Any] = ["type": "CGColorSpace", "cf_type_id": Int(CGColorSpace.typeID),
                                     "model": ["name": modelName(space.model), "raw_value": space.model.rawValue],
                                     "component_count": space.numberOfComponents]
        guard !ancestors.contains(address) else {
            record["serialization_status"] = "cyclic_base_color_space"
            warning("Native color space has a cyclic base-color-space reference; no synthetic definition was supplied.")
            return (record, false)
        }
        var complete = true
        var visited = ancestors
        visited.insert(address)
        if let name = space.name {
            record["name"] = name as String
            record["name_status"] = "captured"
        } else {
            record["name"] = NSNull()
            record["name_status"] = "not_named"
        }
        if #available(macOS 10.12, *) {
            if let nativeData = space.copyICCData() {
                let data = nativeData as Data
                record["icc_profile"] = ["status": "captured", "byte_length": data.count,
                                          "bytes_base64": data.base64EncodedString()]
            } else {
                // Apple documents NULL as a color space with no ICC profile.
                record["icc_profile"] = ["status": "not_present"]
            }
        } else {
            record["icc_profile"] = ["status": "api_unavailable"]
            warning("Public ICC-profile accessor is unavailable on this macOS version.")
            complete = false
        }
        if space.model == .indexed || space.model == .pattern {
            if let base = space.baseColorSpace {
                let (encoded, resolved) = colorSpace(base, ancestors: visited, warning: warning)
                record["base_color_space"] = encoded
                if !resolved { complete = false }
                if space.model == .indexed {
                    if let table = space.colorTable {
                        record["color_table"] = ["status": "captured", "byte_length": table.count,
                                                  "bytes_base64": Data(table).base64EncodedString()]
                        if base.numberOfComponents > 0 && table.count % base.numberOfComponents == 0 {
                            record["color_table_entry_count"] = table.count / base.numberOfComponents
                        } else {
                            record["color_table_entry_count"] = NSNull()
                            warning("Native indexed color table length cannot be divided by the base color space's component count.")
                            complete = false
                        }
                    } else {
                        record["color_table"] = ["status": "not_present"]
                        warning("Native indexed color space returned no public color table.")
                        complete = false
                    }
                }
            } else {
                record["base_color_space"] = ["status": "not_present"]
                if space.model == .indexed {
                    warning("Native indexed color space returned no required base color space; its color table is unresolved.")
                    record["color_table"] = ["status": "missing_base_color_space"]
                    complete = false
                }
            }
        } else if space.name == nil && (record["icc_profile"] as? [String: Any])?["status"] as? String != "captured" {
            // Components and model alone cannot describe an arbitrary unnamed
            // calibrated space. Preserve the gap rather than invent a profile.
            warning("Unnamed native color space has no public ICC definition; model and components alone may not reconstruct its color semantics.")
            complete = false
        }
        if space.model == .unknown || modelName(space.model) == "unrecognized" {
            warning("Native color space model is unknown; its raw model value is retained.")
            complete = false
        }
        record["serialization_status"] = complete ? "captured" : "partial"
        return (record, complete)
    }

    static func color(_ color: CGColor, warning: (String) -> Void) -> [String: Any] {
        var result: [String: Any] = ["type": "CGColor", "cf_type_id": Int(CGColor.typeID),
                                    "component_count": color.numberOfComponents, "alpha": number(color.alpha),
                                    "alpha_ieee754_binary64": bits(color.alpha)]
        var complete = true
        if let components = color.components {
            result["components"] = components.map(number)
            result["components_ieee754_binary64"] = components.map(bits)
            if components.count != color.numberOfComponents {
                warning("Native color component array count differs from CGColorGetNumberOfComponents.")
                complete = false
            }
        } else {
            result["components"] = NSNull()
            result["components_status"] = "missing_components"
            warning("CGColorGetComponents returned no native components.")
            complete = false
        }
        if let space = color.colorSpace {
            let (encoded, resolved) = colorSpace(space, warning: warning)
            result["color_space"] = encoded
            if !resolved { complete = false }
        } else {
            result["color_space"] = ["status": "not_present"]
            warning("Native color returned no color space; its component semantics are unresolved.")
            complete = false
        }
        if let pattern = color.pattern {
            result["pattern"] = ["type": "CGPattern", "cf_type_id": Int(CGPattern.typeID),
                                  "serialization_status": "opaque_drawing_callback"]
            // Public CGPattern APIs do not expose the constructor's drawing
            // callback, private info payload, or tile definition for inspection.
            _ = pattern
            warning("Native pattern color contains a drawing callback that public APIs cannot serialize; raw color components and color space are retained.")
            complete = false
        }
        result["serialization_status"] = complete ? "captured" : "partial"
        return result
    }

    static func path(_ path: CGPath, warning: (String) -> Void) -> [String: Any] {
        var commands: [[String: Any]] = []
        var complete = true
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let command: String
            let pointCount: Int
            switch element.type {
            case .moveToPoint: command = "move_to"; pointCount = 1
            case .addLineToPoint: command = "line_to"; pointCount = 1
            case .addQuadCurveToPoint: command = "quad_curve_to"; pointCount = 2
            case .addCurveToPoint: command = "cubic_curve_to"; pointCount = 3
            case .closeSubpath: command = "close_subpath"; pointCount = 0
            @unknown default:
                commands.append(["command": "unrecognized", "native_type": element.type.rawValue,
                                 "points_status": "unknown_command_arity"])
                warning("Native CGPath command has an unknown type; its point count was not guessed.")
                complete = false
                return
            }
            let points: [[String: Any]] = (0..<pointCount).map { index in
                let point = element.points[index]
                return ["x": number(point.x), "y": number(point.y),
                        "x_ieee754_binary64": bits(point.x), "y_ieee754_binary64": bits(point.y)]
            }
            commands.append(["command": command, "native_type": element.type.rawValue, "points": points])
        }
        return ["type": "CGPath", "cf_type_id": Int(CGPath.typeID), "commands": commands,
                "command_count": commands.count, "is_empty": path.isEmpty,
                "serialization_status": complete ? "captured" : "partial"]
    }

    static func encode(_ value: CFTypeRef, type: CFTypeID, warning: (String) -> Void) -> [String: Any]? {
        // Swift's .typeID properties call the public GetTypeID functions. Their
        // runtime values are compared, never numeric IDs from an older export.
        if type == CGColor.typeID { return color(value as! CGColor, warning: warning) }
        if type == CGPath.typeID { return path(value as! CGPath, warning: warning) }
        return nil
    }

    static func selfTest() throws -> Int {
        func check(_ condition: Bool, _ message: String) throws {
            if !condition { throw EngineError.message("Offline graphics fixture failed: \(message)") }
        }
        var passed = 0
        var warnings: [String] = []
        let rgb = CGColor(red: 0.125, green: 0.25, blue: 0.75, alpha: 0.5)
        let rgbRecord = encode(rgb, type: CFGetTypeID(rgb)) { warnings.append($0) }!
        let rgbSpace = rgbRecord["color_space"] as? [String: Any]
        let rgbModel = rgbSpace?["model"] as? [String: Any]
        try check(rgbRecord["components"] as? [Double] == [0.125, 0.25, 0.75, 0.5] &&
                  rgbModel?["name"] as? String == "rgb" && warnings.isEmpty && JSONSerialization.isValidJSONObject(rgbRecord),
                  "RGB color preserves native components, alpha, and model without conversion")
        passed += 1
        let profile = rgbSpace?["icc_profile"] as? [String: Any]
        let originalProfile = rgb.colorSpace!.copyICCData()! as Data
        try check(rgbSpace?["name"] as? String == rgb.colorSpace!.name! as String &&
                  profile?["bytes_base64"] as? String == originalProfile.base64EncodedString() &&
                  profile?["byte_length"] as? Int == originalProfile.count,
                  "named color space and ICC bytes are preserved exactly")
        passed += 1
        let gray = CGColor(gray: 0.375, alpha: 0.625)
        warnings = []
        let grayRecord = encode(gray, type: CFGetTypeID(gray)) { warnings.append($0) }!
        try check(grayRecord["components"] as? [Double] == [0.375, 0.625] && warnings.isEmpty,
                  "monochrome components retain their native arity")
        passed += 1
        let empty = CGMutablePath()
        warnings = []
        let emptyRecord = encode(empty, type: CFGetTypeID(empty)) { warnings.append($0) }!
        try check(emptyRecord["is_empty"] as? Bool == true && emptyRecord["command_count"] as? Int == 0 && warnings.isEmpty,
                  "empty native path has no invented commands")
        passed += 1
        let fixture = CGMutablePath()
        fixture.move(to: CGPoint(x: 0.125, y: -0.25))
        fixture.addLine(to: CGPoint(x: 2.5, y: 3.75))
        fixture.addQuadCurve(to: CGPoint(x: 6, y: 7), control: CGPoint(x: 4, y: 5))
        fixture.addCurve(to: CGPoint(x: 12, y: 13), control1: CGPoint(x: 8, y: 9), control2: CGPoint(x: 10, y: 11))
        fixture.closeSubpath()
        fixture.move(to: CGPoint(x: -4, y: -5))
        warnings = []
        let pathRecord = encode(fixture, type: CFGetTypeID(fixture)) { warnings.append($0) }!
        let commands = pathRecord["commands"] as? [[String: Any]] ?? []
        try check(commands.compactMap { $0["command"] as? String } ==
                  ["move_to", "line_to", "quad_curve_to", "cubic_curve_to", "close_subpath", "move_to"] && warnings.isEmpty,
                  "native path command ordering and subpath boundaries are unchanged")
        passed += 1
        func coordinates(_ command: [String: Any]) -> [[String: Double]] {
            (command["points"] as? [[String: Any]] ?? []).map { ["x": $0["x"] as! Double, "y": $0["y"] as! Double] }
        }
        try check(coordinates(commands[2]) == [["x": 4, "y": 5], ["x": 6, "y": 7]] &&
                  coordinates(commands[3]) == [["x": 8, "y": 9], ["x": 10, "y": 11], ["x": 12, "y": 13]] &&
                  coordinates(commands[4]) == [],
                  "curve control points and endpoint arities are preserved without flattening")
        passed += 1
        try check(JSONSerialization.isValidJSONObject(pathRecord), "native path output is JSON serializable")
        passed += 1
        let unrelated = "not graphics" as CFString
        try check(encode(unrelated, type: CFGetTypeID(unrelated)) { warnings.append($0) } == nil && warnings.isEmpty,
                  "unrelated CF types do not match runtime graphics type IDs")
        passed += 1
        let nonfinite = [CGFloat.nan, CGFloat.infinity, -CGFloat.infinity].map(number)
        try check(nonfinite.compactMap { ($0 as? [String: Any])?["value"] as? String } == ["nan", "infinity", "-infinity"] &&
                  nonfinite.allSatisfy { (($0 as? [String: Any])?["ieee754_binary64"] as? String)?.count == 16 } &&
                  JSONSerialization.isValidJSONObject(nonfinite),
                  "nonfinite numbers retain their kinds and binary64 bits without invalid JSON")
        passed += 1
        let signedZero = CGMutablePath()
        signedZero.move(to: CGPoint(x: -CGFloat.zero, y: CGFloat.zero))
        let zeroRecord = encode(signedZero, type: CFGetTypeID(signedZero)) { warnings.append($0) }!
        let zeroCommands = zeroRecord["commands"] as? [[String: Any]] ?? []
        let zeroPoint = (zeroCommands.first?["points"] as? [[String: Any]])?.first
        var nativeZeroX = ""
        var nativeZeroY = ""
        signedZero.applyWithBlock { pointer in
            nativeZeroX = bits(pointer.pointee.points[0].x)
            nativeZeroY = bits(pointer.pointee.points[0].y)
        }
        // CoreGraphics may normalize input -0 when storing the path. Match the
        // actual native callback values, while testing the codec's -0 handling
        // directly so no value is invented to match a constructor argument.
        try check(bits(-CGFloat.zero) == "8000000000000000" &&
                  zeroPoint?["x_ieee754_binary64"] as? String == nativeZeroX &&
                  zeroPoint?["y_ieee754_binary64"] as? String == nativeZeroY &&
                  rgbRecord["components_ieee754_binary64"] as? [String] == rgb.components!.map(bits),
                  "finite coordinates and color components retain exact bits, including signed zero")
        passed += 1
        let table: [UInt8] = [0, 128, 255, 64, 32, 16]
        guard let indexed = table.withUnsafeBufferPointer({
            CGColorSpace(indexedBaseSpace: CGColorSpaceCreateDeviceRGB(), last: 1, colorTable: $0.baseAddress!)
        }), let indexedColor = CGColor(colorSpace: indexed, components: [1, 0.5]) else {
            throw EngineError.message("Cannot construct offline indexed color fixture.")
        }
        warnings = []
        let indexedRecord = encode(indexedColor, type: CFGetTypeID(indexedColor)) { warnings.append($0) }!
        let indexedSpace = indexedRecord["color_space"] as? [String: Any]
        let indexedTable = indexedSpace?["color_table"] as? [String: Any]
        try check(indexedTable?["bytes_base64"] as? String == Data(table).base64EncodedString() &&
                  indexedSpace?["color_table_entry_count"] as? Int == 2 &&
                  indexedRecord["components"] as? [Double] == [1, 0.5] && warnings.isEmpty,
                  "indexed colors retain their base space, native index, and exact color-table bytes")
        passed += 1
        var callbacks = CGPatternCallbacks(version: 0, drawPattern: { _, _ in }, releaseInfo: nil)
        guard let pattern = CGPattern(info: nil, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                      matrix: .identity, xStep: 1, yStep: 1, tiling: .constantSpacing,
                                      isColored: true, callbacks: &callbacks),
              let patternSpace = CGColorSpace(patternBaseSpace: nil),
              let patternColor = CGColor(patternSpace: patternSpace, pattern: pattern, components: [1]) else {
            throw EngineError.message("Cannot construct offline pattern color fixture.")
        }
        warnings = []
        let patternRecord = encode(patternColor, type: CFGetTypeID(patternColor)) { warnings.append($0) }!
        let patternValue = patternRecord["pattern"] as? [String: Any]
        try check(patternRecord["serialization_status"] as? String == "partial" && warnings.count == 1 &&
                  patternValue?["serialization_status"] as? String == "opaque_drawing_callback" &&
                  patternRecord["components"] as? [Double] == [1],
                  "publicly inaccessible pattern definition stays explicit while accessible values remain captured")
        passed += 1
        let payloadNaN = CGFloat(Double(bitPattern: 0x7ff8000000000042))
        let payloadRecord = number(payloadNaN) as? [String: Any]
        try check(payloadRecord?["ieee754_binary64"] as? String == "7ff8000000000042",
                  "nonfinite payload bits are retained without normalization")
        passed += 1
        return passed
    }
}

func jsonData(_ object: Any, pretty: Bool = false) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys])
}
func canonical(_ object: Any) -> String {
    guard let data = try? jsonData(object), let text = String(data: data, encoding: .utf8) else { return "null" }
    return text
}

func semanticGraph(_ normalized: [String: Any]) -> [String: Any] {
    var result = normalized
    let nodes = normalized["nodes"] as? [[String: Any]] ?? []
    result["nodes"] = nodes.map { node -> [String: Any] in
        var result = node
        var attributes = node["attributes"] as? [String: Any] ?? [:]
        // These two native attributes contain geometry only. Remove their
        // values, not their advertised names, statuses, or reference records.
        // Every other native value (including AXPath) remains significant.
        attributes.removeValue(forKey: "AXPosition")
        attributes.removeValue(forKey: "AXSize")
        result["attributes"] = attributes
        return result
    }
    return result
}

// SHA-256 is implemented here to keep the binary's dependencies limited to the
// three system frameworks above. Digests describe the recorded observation, not
// proof that every possible application state has been discovered.
func sha256(_ data: Data) -> String {
    let constants: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
    ]
    var bytes = Array(data)
    let bitCount = UInt64(bytes.count) &* 8
    bytes.append(0x80)
    while bytes.count % 64 != 56 { bytes.append(0) }
    for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((bitCount >> UInt64(shift)) & 0xff)) }
    var state: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
    func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    for start in stride(from: 0, to: bytes.count, by: 64) {
        var words = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let p = start + i * 4
            words[i] = UInt32(bytes[p]) << 24 | UInt32(bytes[p+1]) << 16 | UInt32(bytes[p+2]) << 8 | UInt32(bytes[p+3])
        }
        for i in 16..<64 {
            let a = words[i-15], b = words[i-2]
            let s0 = rotate(a, 7) ^ rotate(a, 18) ^ (a >> 3)
            let s1 = rotate(b, 17) ^ rotate(b, 19) ^ (b >> 10)
            words[i] = words[i-16] &+ s0 &+ words[i-7] &+ s1
        }
        var a=state[0],b=state[1],c=state[2],d=state[3],e=state[4],f=state[5],g=state[6],h=state[7]
        for i in 0..<64 {
            let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
            let t1 = h &+ s1 &+ ((e & f) ^ ((~e) & g)) &+ constants[i] &+ words[i]
            let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
            let t2 = s0 &+ ((a & b) ^ (a & c) ^ (b & c))
            h=g; g=f; f=e; e=d &+ t1; d=c; c=b; b=a; a=t1 &+ t2
        }
        state[0] = state[0] &+ a; state[1] = state[1] &+ b
        state[2] = state[2] &+ c; state[3] = state[3] &+ d
        state[4] = state[4] &+ e; state[5] = state[5] &+ f
        state[6] = state[6] &+ g; state[7] = state[7] &+ h
    }
    return state.map { String(format: "%08x", $0) }.joined()
}

func errorName(_ error: AXError) -> String {
    switch error {
    case .success: return "success"
    case .failure: return "failure"
    case .illegalArgument: return "illegalArgument"
    case .invalidUIElement: return "invalidUIElement"
    case .invalidUIElementObserver: return "invalidUIElementObserver"
    case .cannotComplete: return "cannotComplete"
    case .attributeUnsupported: return "attributeUnsupported"
    case .actionUnsupported: return "actionUnsupported"
    case .notificationUnsupported: return "notificationUnsupported"
    case .notImplemented: return "notImplemented"
    case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
    case .notificationNotRegistered: return "notificationNotRegistered"
    case .apiDisabled: return "apiDisabled"
    case .noValue: return "noValue"
    case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: return "notEnoughPrecision"
    @unknown default: return "unknown"
    }
}

struct ReadResult<T> {
    let value: T?
    let error: AXError
    let attempts: Int
    var recovery: [String: Any]? = nil
    var status: [String: Any] {
        var result: [String: Any] = ["code": error.rawValue, "name": errorName(error), "attempts": attempts]
        if let recovery { result["native_read_recovery"] = recovery }
        return result
    }
}

func nativeReadStatus<T>(_ result: ReadResult<T>) -> [String: Any] {
    ["code": result.error.rawValue, "name": errorName(result.error), "attempts": result.attempts]
}

func nativeMetadataRecoveryEligible(_ error: AXError) -> Bool {
    error == .failure || error == .cannotComplete || error == .attributeUnsupported
}

func read<T>(_ operation: (inout T?) -> AXError) -> ReadResult<T> {
    var finalError = AXError.failure
    var finalValue: T?
    var attempts = 0
    for _ in 0...retryLimit {
        attempts += 1
        finalValue = nil
        finalError = operation(&finalValue)
        if finalError != .cannotComplete { break }
    }
    return ReadResult(value: finalValue, error: finalError, attempts: attempts)
}

func recoverNativeArray(_ initial: ReadResult<CFTypeRef>,
                        count: () -> ReadResult<NSNumber>,
                        values: (Int, Int) -> ReadResult<CFArray>) -> ReadResult<CFTypeRef> {
    // A failed read is never relabeled as an empty selection. Recovery needs
    // successful native array-count and page reads, with the count checked
    // again afterwards. The original failure remains in the recovery trace.
    guard nativeMetadataRecoveryEligible(initial.error) else { return initial }
    var trace: [String: Any] = ["method": "AXUIElementGetAttributeValueCount/AXUIElementCopyAttributeValues",
                              "initial_status": nativeReadStatus(initial), "resolved": false, "resolution_kind": "unresolved"]
    func failed(_ reason: String) -> ReadResult<CFTypeRef> {
        trace["reason"] = reason
        return ReadResult(value: initial.value, error: initial.error, attempts: initial.attempts, recovery: trace)
    }
    let before = count()
    trace["count_before_status"] = before.status
    guard before.error == .success, let beforeValue = before.value else { return failed("Native array count could not be read.") }
    let expected = beforeValue.intValue
    trace["count_before"] = expected
    guard expected >= 0 else { return failed("Native array count was negative.") }
    var result: [Any] = [], pages: [[String: Any]] = []
    while result.count < expected {
        let start = result.count, requested = min(256, expected - start)
        let page = values(start, requested)
        let items = page.value as? [Any]
        pages.append(["index": start, "requested": requested, "status": page.status,
                      "has_value": page.value != nil, "returned_count": items?.count ?? NSNull()])
        trace["pages"] = pages
        guard page.error == .success, let array = items, array.count == requested else {
            return failed("Native array page failed or its length changed during reading.")
        }
        result.append(contentsOf: array)
    }
    let after = count()
    trace["count_after_status"] = after.status
    trace["count_after"] = after.value ?? NSNull()
    guard after.error == .success, after.value?.intValue == expected else {
        return failed("Native array count changed or could not be confirmed after reading.")
    }
    trace["resolved"] = true
    trace["resolution_kind"] = "value"
    trace["returned_count"] = result.count
    return ReadResult(value: result as CFArray, error: .success, attempts: initial.attempts, recovery: trace)
}

func attribute(_ element: AXUIElement, _ name: String) -> ReadResult<CFTypeRef> {
    read { AXUIElementCopyAttributeValue(element, name as CFString, &$0) }
}

func nativeScalarExpectedValueKind(_ attribute: String) -> String? {
    // AXFrame's CGRect contract is the observed native frame shape; the other
    // four names and their types are defined in the public AX SDK headers.
    ["AXGrowArea": "AXUIElement", "AXTopLevelUIElement": "AXUIElement", "AXFrame": "CGRect",
     "AXPosition": "CGPoint", "AXSize": "CGSize"][attribute]
}

func nativeScalarValueValidation(_ attribute: String, _ value: CFTypeRef?) -> [String: Any] {
    let expected = nativeScalarExpectedValueKind(attribute) ?? "unknown"
    let expectedType = expected == "AXUIElement" ? AXUIElementGetTypeID() : AXValueGetTypeID()
    var result: [String: Any] = ["expected_value_kind": expected, "expected_cf_type_id": Int(expectedType),
                               "has_value": value != nil, "cf_type_id": NSNull(), "ax_value_type": NSNull(),
                               "ax_value_decoded": NSNull(), "valid": false]
    guard let value else { result["reason"] = "Native scalar query returned no value."; return result }
    let type = CFGetTypeID(value)
    result["cf_type_id"] = Int(type)
    if type == AXValueGetTypeID() {
        let native = value as! AXValue
        let subtype = AXValueGetType(native)
        let subtypeName: String
        switch subtype {
        case .cgPoint: subtypeName = "cgPoint"
        case .cgSize: subtypeName = "cgSize"
        case .cgRect: subtypeName = "cgRect"
        case .cfRange: subtypeName = "cfRange"
        case .axError: subtypeName = "axError"
        case .illegal: subtypeName = "illegal"
        @unknown default: subtypeName = "unknown"
        }
        result["ax_value_type"] = subtypeName
        var decoded: Bool?
        if expected == "CGPoint", subtype == .cgPoint {
            var point = CGPoint.zero; decoded = AXValueGetValue(native, .cgPoint, &point)
        } else if expected == "CGSize", subtype == .cgSize {
            var size = CGSize.zero; decoded = AXValueGetValue(native, .cgSize, &size)
        } else if expected == "CGRect", subtype == .cgRect {
            var rect = CGRect.zero; decoded = AXValueGetValue(native, .cgRect, &rect)
        }
        if let decoded { result["ax_value_decoded"] = decoded }
        result["valid"] = type == expectedType && decoded == true
    } else {
        result["valid"] = expected == "AXUIElement" && type == expectedType
    }
    if result["valid"] as? Bool != true { result["reason"] = "Native value does not match the known scalar type contract." }
    return result
}

struct NativeValuePathResult {
    let value: CFTypeRef?
    let steps: [[String: Any]]
    let resolved: Bool
    let reason: String?
}

func nativeValueAtPath(_ initial: CFTypeRef?, components: [Any]) -> NativeValuePathResult {
    guard var selected = initial else { return NativeValuePathResult(value: nil, steps: [], resolved: false, reason: "Attribute read returned no native value.") }
    var steps: [[String: Any]] = []
    for component in components {
        let containerType = CFGetTypeID(selected)
        var step: [String: Any] = ["component_kind": "unsupported", "container_cf_type_id": Int(containerType),
                                  "selected_has_value": false, "resolved": false]
        var next: CFTypeRef?
        if CFGetTypeID(component as CFTypeRef) != CFBooleanGetTypeID(), let index = component as? Int {
            step["component_kind"] = "array_index"; step["index"] = index
            if containerType == CFArrayGetTypeID(), let items = selected as? [Any], index >= 0, index < items.count {
                next = items[index] as CFTypeRef
            }
        } else if let key = component as? String {
            step["component_kind"] = "dictionary_key"; step["key"] = key
            if containerType == CFDictionaryGetTypeID(), let object = selected as? [String: Any], let value = object[key] {
                next = value as CFTypeRef
            }
        }
        step["selected_has_value"] = next != nil
        step["resolved"] = next != nil
        if next == nil { step["reason"] = "Recorded value-path component is unsupported, absent, out of range, or has the wrong native container type." }
        steps.append(step)
        guard let next else { return NativeValuePathResult(value: nil, steps: steps, resolved: false, reason: step["reason"] as? String) }
        selected = next
    }
    return NativeValuePathResult(value: selected, steps: steps, resolved: true, reason: nil)
}

struct NativeScalarRefreshResult {
    let element: AXUIElement?
    let evidence: [String: Any]
}

func refreshNativeScalarTarget(selectorPath: [[String: Any]], rootPID: pid_t, expectedPID: pid_t,
                               recordedAtPath: ([[String: Any]]) -> (element: AXUIElement, pid: pid_t)?,
                               processMatches: (pid_t) -> Bool, createRoot: () -> AXUIElement,
                               setTimeout: (AXUIElement) -> AXError,
                               readAttribute: (AXUIElement, String) -> ReadResult<CFTypeRef>,
                               elementPID: (AXUIElement) -> ReadResult<NSNumber>,
                               sameElement: (AXUIElement, AXUIElement) -> Bool = { CFEqual($0, $1) }) -> NativeScalarRefreshResult {
    var evidence: [String: Any] = ["attempted": true, "selector_path": selectorPath, "root_pid": Int(rootPID),
                                 "expected_pid": Int(expectedPID), "process_identity_matches": false,
                                 "root_same_element": false, "root_timeout_status": NSNull(), "steps": [],
                                 "same_element": false, "pid_status": NSNull(), "pid": NSNull(), "resolved": false]
    func failed(_ reason: String) -> NativeScalarRefreshResult {
        evidence["reason"] = reason
        return NativeScalarRefreshResult(element: nil, evidence: evidence)
    }
    guard processMatches(rootPID), processMatches(expectedPID) else { return failed("Recorded root or owner process/launch identity changed.") }
    evidence["process_identity_matches"] = true
    guard let recordedRoot = recordedAtPath([]), recordedRoot.pid == rootPID else { return failed("Recorded native root identity is unavailable.") }
    var current = createRoot()
    evidence["root_same_element"] = sameElement(current, recordedRoot.element)
    guard evidence["root_same_element"] as? Bool == true else { return failed("Fresh native root is not CFEqual to the recorded root.") }
    let timeout = setTimeout(current)
    evidence["root_timeout_status"] = nativeReadStatus(ReadResult<CFTypeRef>(value: nil, error: timeout, attempts: 1))
    guard timeout == .success else { return failed("Fresh native root request timeout could not be set.") }
    var steps: [[String: Any]] = []
    for (index, selector) in selectorPath.enumerated() {
        var step: [String: Any] = ["step": index, "query_status": NSNull(), "has_value": false,
                                  "path_steps": [], "selected_cf_type_id": NSNull(), "selected_is_element": false,
                                  "same_element": false, "pid_status": NSNull(), "pid": NSNull(),
                                  "process_identity_matches": NSNull(), "resolved": false]
        guard let attribute = selector["attribute"] as? String, let components = selector["value_path"] as? [Any] else {
            steps.append(step); evidence["steps"] = steps
            return failed("Recorded native selector path is malformed.")
        }
        step["attribute"] = attribute; step["value_path"] = components
        let read = readAttribute(current, attribute)
        step["query_status"] = nativeReadStatus(read); step["has_value"] = read.value != nil
        guard read.error == .success else {
            steps.append(step); evidence["steps"] = steps
            return failed("Fresh native selector attribute read failed.")
        }
        let selected = nativeValueAtPath(read.value, components: components)
        step["path_steps"] = selected.steps
        if let value = selected.value { step["selected_cf_type_id"] = Int(CFGetTypeID(value)) }
        guard selected.resolved, let value = selected.value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            steps.append(step); evidence["steps"] = steps
            return failed(selected.reason ?? "Fresh selector did not return an actual native element.")
        }
        step["selected_is_element"] = true
        let element = value as! AXUIElement
        let prefix = Array(selectorPath.prefix(index + 1))
        guard let recorded = recordedAtPath(prefix) else {
            steps.append(step); evidence["steps"] = steps
            return failed("Recorded native element for a selector prefix is unavailable.")
        }
        step["same_element"] = sameElement(element, recorded.element)
        step["expected_pid"] = Int(recorded.pid)
        let pidRead = elementPID(element)
        step["pid_status"] = nativeReadStatus(pidRead); step["pid"] = pidRead.value ?? NSNull()
        if pidRead.error == .success, pidRead.value?.int32Value == recorded.pid {
            step["process_identity_matches"] = processMatches(recorded.pid)
        }
        guard step["same_element"] as? Bool == true, pidRead.error == .success,
              pidRead.value?.int32Value == recorded.pid, step["process_identity_matches"] as? Bool == true else {
            if step["process_identity_matches"] as? Bool == false { evidence["process_identity_matches"] = false }
            steps.append(step); evidence["steps"] = steps
            return failed("Fresh selector reference, PID, or process launch identity differs from the recorded prefix.")
        }
        step["resolved"] = true
        steps.append(step); evidence["steps"] = steps; current = element
    }
    guard let recorded = recordedAtPath(selectorPath) else { return failed("Recorded scalar owner is unavailable.") }
    evidence["same_element"] = sameElement(current, recorded.element)
    let pidRead = elementPID(current)
    evidence["pid_status"] = nativeReadStatus(pidRead); evidence["pid"] = pidRead.value ?? NSNull()
    guard evidence["same_element"] as? Bool == true, recorded.pid == expectedPID,
          pidRead.error == .success, pidRead.value?.int32Value == expectedPID,
          processMatches(rootPID), processMatches(expectedPID) else {
        evidence["process_identity_matches"] = processMatches(rootPID) && processMatches(expectedPID)
        return failed("Fresh scalar owner no longer has the exact recorded element, PID, or process launch identity.")
    }
    evidence["resolved"] = true
    return NativeScalarRefreshResult(element: current, evidence: evidence)
}

// A menu wrapper can be recreated while the capture still retains the original
// native owner. This predicate permits querying that original owner only when
// CFEqual is the sole failure of the fresh prefix; it never follows a changed
// prefix or treats a read/PID/process/type failure as an identity mismatch.
func nativeScalarRetainedReferenceEligible(_ refresh: [String: Any]) -> Bool {
    guard refresh["attempted"] as? Bool == true, refresh["resolved"] as? Bool == false,
          refresh["root_same_element"] as? Bool == true,
          refresh["process_identity_matches"] as? Bool == true,
          let timeout = refresh["root_timeout_status"] as? [String: Any],
          (timeout["code"] as? NSNumber)?.int32Value == AXError.success.rawValue,
          let selectors = refresh["selector_path"] as? [[String: Any]],
          let steps = refresh["steps"] as? [[String: Any]],
          !steps.isEmpty, steps.count <= selectors.count else { return false }
    for (index, step) in steps.enumerated() {
        let selector = selectors[index]
        guard step["step"] as? Int == index,
              let attribute = selector["attribute"] as? String, !attribute.isEmpty,
              step["attribute"] as? String == attribute,
              let components = selector["value_path"] as? [Any],
              let stepComponents = step["value_path"] as? [Any],
              canonical(components) == canonical(stepComponents),
              let paths = step["path_steps"] as? [[String: Any]], paths.count == components.count,
              paths.allSatisfy({ $0["resolved"] as? Bool == true && $0["selected_has_value"] as? Bool == true }),
              let read = step["query_status"] as? [String: Any], (read["code"] as? NSNumber)?.int32Value == AXError.success.rawValue,
              step["has_value"] as? Bool == true, step["selected_is_element"] as? Bool == true,
              step["selected_cf_type_id"] as? Int == Int(AXUIElementGetTypeID()),
              let pid = step["pid_status"] as? [String: Any], (pid["code"] as? NSNumber)?.int32Value == AXError.success.rawValue,
              let expected = step["expected_pid"] as? Int, step["pid"] as? Int == expected,
              step["process_identity_matches"] as? Bool == true else { return false }
        if index == steps.count - 1 {
            guard step["same_element"] as? Bool == false, step["resolved"] as? Bool == false else { return false }
        } else {
            guard step["same_element"] as? Bool == true, step["resolved"] as? Bool == true else { return false }
        }
    }
    return true
}

func validateRetainedNativeScalarTarget(nodeID: Int, rootID: Int, rootPID: pid_t, expectedPID: pid_t,
                                       ownerRole: String?, ownerRoleStatus: [String: Any],
                                       retainedOwner: AXUIElement,
                                       recordedAtID: (Int) -> (element: AXUIElement, pid: pid_t)?,
                                       processMatches: (pid_t) -> Bool,
                                       elementPID: (AXUIElement) -> ReadResult<NSNumber>,
                                       sameElement: (AXUIElement, AXUIElement) -> Bool = { CFEqual($0, $1) }) -> NativeScalarRefreshResult {
    var evidence: [String: Any] = ["attempted": true, "source": "capture_registry", "node_id": nodeID, "root_id": rootID,
                                  "root_pid": Int(rootPID), "expected_pid": Int(expectedPID),
                                  "owner_role": ownerRole ?? NSNull(), "owner_role_status": ownerRoleStatus,
                                  "expected_cf_type_id": Int(AXUIElementGetTypeID()), "owner_cf_type_id": Int(CFGetTypeID(retainedOwner)),
                                  "registry_binding_matches": false, "root_pid_status": NSNull(), "root_native_pid": NSNull(),
                                  "owner_pid_status": NSNull(), "owner_native_pid": NSNull(),
                                  "root_process_identity_matches": NSNull(), "owner_process_identity_matches": NSNull(), "resolved": false]
    func failed(_ reason: String) -> NativeScalarRefreshResult {
        evidence["reason"] = reason
        return NativeScalarRefreshResult(element: nil, evidence: evidence)
    }
    guard (ownerRoleStatus["code"] as? NSNumber)?.int32Value == AXError.success.rawValue,
          ownerRole == "AXMenu" || ownerRole == "AXMenuItem" else {
        return failed("Retained original-reference queries require a successful captured native menu role.")
    }
    guard let original = recordedAtID(nodeID), let root = recordedAtID(rootID),
          original.pid == expectedPID, root.pid == rootPID,
          CFGetTypeID(retainedOwner) == AXUIElementGetTypeID(), sameElement(retainedOwner, original.element) else {
        return failed("Retained query target is not the exact original capture-registry owner.")
    }
    evidence["registry_binding_matches"] = true
    evidence["root_process_identity_matches"] = processMatches(rootPID)
    evidence["owner_process_identity_matches"] = processMatches(expectedPID)
    guard evidence["root_process_identity_matches"] as? Bool == true,
          evidence["owner_process_identity_matches"] as? Bool == true else {
        return failed("Captured root or retained owner process/launch identity changed.")
    }
    let rootRead = elementPID(root.element)
    evidence["root_pid_status"] = nativeReadStatus(rootRead); evidence["root_native_pid"] = rootRead.value ?? NSNull()
    guard rootRead.error == .success, rootRead.value?.int32Value == rootPID else {
        return failed("Retained native root PID could not be confirmed.")
    }
    let ownerRead = elementPID(retainedOwner)
    evidence["owner_pid_status"] = nativeReadStatus(ownerRead); evidence["owner_native_pid"] = ownerRead.value ?? NSNull()
    guard ownerRead.error == .success, ownerRead.value?.int32Value == expectedPID else {
        return failed("Retained original native owner PID could not be confirmed.")
    }
    evidence["root_process_identity_matches"] = processMatches(rootPID)
    evidence["owner_process_identity_matches"] = processMatches(expectedPID)
    guard evidence["root_process_identity_matches"] as? Bool == true,
          evidence["owner_process_identity_matches"] as? Bool == true else {
        return failed("Captured root or retained owner process/launch identity changed during native PID validation.")
    }
    evidence["resolved"] = true
    return NativeScalarRefreshResult(element: retainedOwner, evidence: evidence)
}

func recoverNativeScalar(_ attribute: String, _ initial: ReadResult<CFTypeRef>,
                         refresh: () -> NativeScalarRefreshResult,
                         query: (AXUIElement) -> ReadResult<CFTypeRef>,
                         queryIdentityMatches: () -> Bool = { true },
                         retainedTarget: (() -> NativeScalarRefreshResult)? = nil,
                         retainedQueryValidation: ((AXUIElement) -> NativeScalarRefreshResult)? = nil) -> ReadResult<CFTypeRef> {
    guard let expected = nativeScalarExpectedValueKind(attribute), nativeMetadataRecoveryEligible(initial.error) else { return initial }
    let fresh = refresh()
    var trace: [String: Any] = ["method": "native_scalar_recovery", "initial_status": nativeReadStatus(initial),
                              "attribute": attribute, "expected_value_kind": expected,
                              "query_method": "AXUIElementCopyAttributeValue", "refresh": fresh.evidence,
                              "query_status": NSNull(), "query_process_identity_matches": NSNull(), "value_validation": NSNull(),
                              "query_target": NSNull(), "retained_reference": NSNull(), "query_retained_reference_validation": NSNull(),
                              "resolved": false, "resolution_kind": "unresolved"]
    func failed(_ reason: String) -> ReadResult<CFTypeRef> {
        trace["reason"] = reason
        return ReadResult(value: initial.value, error: initial.error, attempts: initial.attempts, recovery: trace)
    }
    let element: AXUIElement
    if fresh.evidence["resolved"] as? Bool == true, let exact = fresh.element {
        element = exact
        trace["query_target"] = "fresh_exact_reference"
    } else if attribute == "AXTopLevelUIElement", nativeScalarRetainedReferenceEligible(fresh.evidence),
              let retainedTarget, retainedQueryValidation != nil {
        let retained = retainedTarget()
        trace["retained_reference"] = retained.evidence
        guard retained.evidence["resolved"] as? Bool == true, let original = retained.element else {
            return failed("Original retained native menu owner could not be validated; no scalar query was issued.")
        }
        element = original
        trace["query_target"] = "retained_original_reference"
    } else {
        return failed("Exact native scalar owner could not be refreshed; no scalar query was issued.")
    }
    let result = query(element)
    trace["query_status"] = nativeReadStatus(result)
    let validation = nativeScalarValueValidation(attribute, result.value)
    trace["value_validation"] = validation
    trace["query_process_identity_matches"] = queryIdentityMatches()
    if trace["query_target"] as? String == "retained_original_reference", let retainedQueryValidation {
        let after = retainedQueryValidation(element)
        trace["query_retained_reference_validation"] = after.evidence
        guard after.evidence["resolved"] as? Bool == true else {
            return failed("Retained root or original menu owner failed native PID/process validation after the scalar query.")
        }
    }
    guard trace["query_process_identity_matches"] as? Bool == true else {
        return failed("Recorded root or scalar owner process/launch identity changed during the native query.")
    }
    if result.error == .noValue {
        trace["resolved"] = true; trace["resolution_kind"] = "absence"
        return ReadResult(value: nil, error: .noValue, attempts: initial.attempts, recovery: trace)
    }
    guard result.error == .success, validation["valid"] as? Bool == true, let value = result.value else {
        return failed("Native scalar query failed or did not return the actual expected native value type.")
    }
    trace["resolved"] = true; trace["resolution_kind"] = "value"
    return ReadResult(value: value, error: .success, attempts: initial.attempts, recovery: trace)
}

func recoverNativeMetadataBatch(_ names: [String], initial: [String: ReadResult<CFTypeRef>],
                                query: () -> ReadResult<CFArray>,
                                decodeError: (AXValue) -> AXError? = { value in
                                    var error = AXError.success
                                    return AXValueGetValue(value, .axError, &error) ? error : nil
                                }) -> [String: ReadResult<CFTypeRef>] {
    guard !names.isEmpty else { return [:] }
    let batch = query()
    let items = batch.value as? [Any]
    let validSelection = Set(names).count == names.count && names.allSatisfy { initial[$0] != nil }
    var results: [String: ReadResult<CFTypeRef>] = [:]
    for (index, name) in names.enumerated() {
        guard let original = initial[name] else { continue }
        var trace: [String: Any] = ["method": "AXUIElementCopyMultipleAttributeValues", "query_attributes": names,
                                   "options": 0, "query_status": nativeReadStatus(batch), "has_array": batch.value != nil,
                                   "returned_slot_count": items?.count ?? NSNull(), "slot_index": index,
                                   "slot_attribute": name, "item_kind": "malformed", "item_status": NSNull(),
                                   "item_error_decoded": false, "cf_type_id": NSNull(), "resolved": false,
                                   "resolution_kind": "unresolved"]
        func unresolved(_ reason: String) -> ReadResult<CFTypeRef> {
            trace["reason"] = reason
            return ReadResult(value: original.value, error: original.error, attempts: original.attempts, recovery: trace)
        }
        guard validSelection else { results[name] = unresolved("Batch attribute selection was not unique or lacked matching original reads."); continue }
        guard batch.error == .success else { results[name] = unresolved("Native bulk attribute query failed; the original attribute error is retained."); continue }
        guard let items else { results[name] = unresolved("Native bulk query returned no usable array."); continue }
        guard items.count == names.count else { results[name] = unresolved("Native bulk result cardinality does not match the exact ordered query attributes."); continue }
        let item = items[index] as CFTypeRef
        let type = CFGetTypeID(item)
        trace["cf_type_id"] = Int(type)
        if type == CFNullGetTypeID() {
            trace["item_kind"] = "null"
            results[name] = unresolved("Native bulk slot was CFNull, not an attribute value.")
            continue
        }
        if type == AXValueGetTypeID(), AXValueGetType(item as! AXValue) == .axError {
            trace["item_kind"] = "ax_error"
            if let error = decodeError(item as! AXValue) {
                trace["item_error_decoded"] = true
                trace["item_status"] = ["code": error.rawValue, "name": errorName(error)]
                if error == .noValue {
                    // An exact successful options=0 bulk slot explicitly reports
                    // native absence. It is not an empty value or a failed read.
                    trace["resolved"] = true
                    trace["resolution_kind"] = "absence"
                    results[name] = ReadResult(value: nil, error: .noValue, attempts: original.attempts, recovery: trace)
                } else {
                    results[name] = unresolved("Native bulk slot contained an AX error envelope; the per-slot error and original query error are retained.")
                }
            } else {
                results[name] = unresolved("Native bulk AX error envelope could not be decoded.")
            }
            continue
        }
        trace["item_kind"] = "value"
        if nativeScalarExpectedValueKind(name) != nil {
            let validation = nativeScalarValueValidation(name, item)
            trace["value_validation"] = validation
            guard validation["valid"] as? Bool == true else {
                results[name] = unresolved("Native bulk value slot does not match the known scalar type contract.")
                continue
            }
        }
        trace["resolved"] = true
        trace["resolution_kind"] = "value"
        results[name] = ReadResult(value: item, error: .success, attempts: original.attempts, recovery: trace)
    }
    return results
}

func recoverNativeMetadataReads(_ names: [String], initial: [String: ReadResult<CFTypeRef>],
                                batchQuery: () -> ReadResult<CFArray>,
                                arrayQuery: (String, ReadResult<CFTypeRef>) -> ReadResult<CFTypeRef>,
                                scalarQuery: (String, ReadResult<CFTypeRef>) -> ReadResult<CFTypeRef>) -> [String: ReadResult<CFTypeRef>] {
    let bulkResults = recoverNativeMetadataBatch(names, initial: initial, query: batchQuery)
    var results: [String: ReadResult<CFTypeRef>] = [:]
    for name in names {
        guard let original = initial[name], let bulk = bulkResults[name] else { continue }
        var queries: [[String: Any]] = []
        if let trace = bulk.recovery { queries.append(trace) }
        var selected = bulk
        var selectedMethod: Any = NSNull()
        let bulkAbsence = bulk.error == .noValue && bulk.value == nil &&
            bulk.recovery?["resolved"] as? Bool == true && bulk.recovery?["resolution_kind"] as? String == "absence"
        if (bulk.error == .success && bulk.value != nil) || bulkAbsence {
            selectedMethod = "AXUIElementCopyMultipleAttributeValues"
        } else if nativeScalarExpectedValueKind(name) != nil {
            if nativeMetadataRecoveryEligible(original.error) {
                let scalar = scalarQuery(name, original)
                if let trace = scalar.recovery { queries.append(trace) }
                if (scalar.error == .success && scalar.value != nil) ||
                    (scalar.error == .noValue && scalar.value == nil && scalar.recovery?["resolution_kind"] as? String == "absence") {
                    selected = scalar
                    selectedMethod = "native_scalar_recovery"
                }
            }
        } else {
            let array = arrayQuery(name, original)
            if let trace = array.recovery { queries.append(trace) }
            if array.error == .success, array.value != nil {
                selected = array
                selectedMethod = "AXUIElementGetAttributeValueCount/AXUIElementCopyAttributeValues"
            }
        }
        let absence = selected.error == .noValue && selected.value == nil &&
            selected.recovery?["resolved"] as? Bool == true && selected.recovery?["resolution_kind"] as? String == "absence"
        let value = selected.error == .success && selected.value != nil
        let resolved = value || absence
        var composite: [String: Any] = ["method": "native_metadata_recovery", "initial_status": nativeReadStatus(original),
                                       "queries": queries, "resolved": resolved, "selected_method": selectedMethod,
                                       "resolution_kind": absence ? "absence" : value ? "value" : "unresolved"]
        if let expected = nativeScalarExpectedValueKind(name) {
            composite["documented_scalar"] = ["attribute": name, "expected_value_kind": expected,
                                              "array_query_skipped": true,
                                              "scalar_retry_eligible": nativeMetadataRecoveryEligible(original.error)]
        }
        results[name] = ReadResult(value: absence ? nil : value ? selected.value : original.value,
                                  error: absence ? .noValue : value ? .success : original.error,
                                  attempts: original.attempts, recovery: composite)
    }
    return results
}

func recoverNativeActionNames(_ initial: ReadResult<CFArray>, query: () -> ReadResult<CFArray>) -> ReadResult<CFArray> {
    guard initial.error == .failure else { return initial }
    let next = query()
    let items = next.value as? [Any]
    let names = next.value as? [String]
    let resolved = next.error == .success && names != nil
    var trace: [String: Any] = ["method": "native_action_names_recovery", "initial_status": nativeReadStatus(initial),
                              "initial_has_array": initial.value != nil,
                              "initial_returned_count": (initial.value as? [Any])?.count ?? NSNull(),
                              "query_status": nativeReadStatus(next), "has_array": next.value != nil,
                              "returned_count": items?.count ?? NSNull(), "names_valid": names != nil,
                              "strings_count": items?.filter { $0 is String }.count ?? NSNull(), "resolved": resolved,
                              "resolution_kind": resolved ? "value" : "unresolved"]
    if !resolved { trace["reason"] = "The bounded fresh action-name query did not return a successful native string array." }
    return ReadResult(value: resolved ? next.value : initial.value, error: resolved ? .success : initial.error,
                      attempts: initial.attempts, recovery: trace)
}

func nativeActionNamesForExport(_ result: ReadResult<CFArray>) -> [String]? {
    guard result.error == .success else { return nil }
    return result.value as? [String]
}

func nativeMetadataFailureSummary(_ records: [[String: Any]]) -> [String: Int] {
    let reads = records.filter { $0["stage"] as? String != "serialization" }
    let unsupported = reads.filter { (($0["status"] as? [String: Any])?["code"] as? NSNumber)?.int32Value == AXError.attributeUnsupported.rawValue }.count
    return ["attribute_unsupported": unsupported, "other_read_failures": reads.count - unsupported]
}

func nativeScalarRecoverySelfTest() throws -> Int {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw EngineError.message("Native scalar recovery fixture failed: \(message)") }
    }
    // Constructors allocate opaque references only. Every read/PID/process
    // result below is synthetic; these fixtures do not query any application.
    let rootPID: pid_t = 42001, ownerPID: pid_t = 42002
    let root = AXUIElementCreateApplication(rootPID), owner = AXUIElementCreateApplication(ownerPID)
    let swapped = AXUIElementCreateApplication(42003)
    let original = ReadResult<CFTypeRef>(value: nil, error: .failure, attempts: 1)
    let path: [[String: Any]] = [["attribute": "AXChildren", "value_path": [0]]]
    func refresh(selector: [[String: Any]] = path, value: CFTypeRef? = [owner] as CFArray,
                 readError: AXError = .success, process: @escaping (pid_t) -> Bool = { _ in true },
                 timeout: AXError = .success, missingPrefix: Bool = false, rootOverride: AXUIElement? = nil,
                 pidError: AXError = .success, pidOverride: pid_t? = nil) -> NativeScalarRefreshResult {
        refreshNativeScalarTarget(selectorPath: selector, rootPID: rootPID,
                                  expectedPID: selector.isEmpty ? rootPID : ownerPID, recordedAtPath: { prefix in
            if prefix.isEmpty { return (root, rootPID) }
            return missingPrefix ? nil : (owner, ownerPID)
        }, processMatches: process, createRoot: { rootOverride ?? root }, setTimeout: { _ in timeout },
        readAttribute: { _, _ in ReadResult(value: value, error: readError, attempts: 1) }, elementPID: { element in
            ReadResult(value: pidError == .success ? NSNumber(value: pidOverride ?? (CFEqual(element, root) ? rootPID : ownerPID)) : nil,
                       error: pidError, attempts: 1)
        })
    }
    var point = CGPoint(x: 1, y: 2), size = CGSize(width: 3, height: 4), rect = CGRect(x: 5, y: 6, width: 7, height: 8)
    let pointValue = AXValueCreate(.cgPoint, &point)!, sizeValue = AXValueCreate(.cgSize, &size)!, rectValue = AXValueCreate(.cgRect, &rect)!
    let typed: [(String, CFTypeRef)] = [("AXGrowArea", owner), ("AXTopLevelUIElement", owner),
                                      ("AXPosition", pointValue), ("AXSize", sizeValue), ("AXFrame", rectValue)]
    var fixtures = 0
    for (name, value) in typed {
        var arrays = 0, scalars = 0
        let bulk = recoverNativeMetadataReads([name], initial: [name: original], batchQuery: {
            ReadResult(value: [value] as CFArray, error: .success, attempts: 1)
        }, arrayQuery: { _, result in arrays += 1; return result }, scalarQuery: { _, result in scalars += 1; return result })[name]!
        try check(bulk.error == .success && bulk.recovery?["resolution_kind"] as? String == "value" && arrays == 0 && scalars == 0 &&
                  (bulk.recovery?["queries"] as? [[String: Any]])?.first?["value_validation"] as? [String: Any] != nil,
                  "each known scalar accepts only its actual native typed bulk value without array or fresh queries")
        fixtures += 1
        let fresh = recoverNativeMetadataReads([name], initial: [name: original], batchQuery: {
            ReadResult(value: [kCFNull!] as CFArray, error: .success, attempts: 1)
        }, arrayQuery: { _, result in arrays += 1; return result }, scalarQuery: { name, result in
            recoverNativeScalar(name, result, refresh: { refresh() }, query: { _ in scalars += 1; return ReadResult(value: value, error: .success, attempts: 1) })
        })[name]!
        try check(fresh.error == .success && fresh.recovery?["selected_method"] as? String == "native_scalar_recovery" &&
                  (fresh.recovery?["queries"] as? [[String: Any]])?.count == 2 && scalars == 1 && arrays == 0,
                  "each known scalar can recover one typed native value through an exact refreshed owner")
        fixtures += 1
    }
    var unsupportedError = AXError.attributeUnsupported
    let unsupportedEnvelope = AXValueCreate(.axError, &unsupportedError)!
    for (name, _) in typed {
        var arrays = 0, scalars = 0
        let unsupported = ReadResult<CFTypeRef>(value: nil, error: .attributeUnsupported, attempts: 1)
        let result = recoverNativeMetadataReads([name], initial: [name: unsupported], batchQuery: {
            ReadResult(value: [unsupportedEnvelope] as CFArray, error: .success, attempts: 1)
        }, arrayQuery: { _, result in arrays += 1; return result }, scalarQuery: { attribute, result in
            recoverNativeScalar(attribute, result, refresh: { refresh() }, query: { _ in
                scalars += 1; return ReadResult(value: nil, error: .attributeUnsupported, attempts: 1)
            })
        })[name]!
        try check(result.error == .attributeUnsupported && result.value == nil && arrays == 0 && scalars == 1 &&
                  (result.recovery?["queries"] as? [[String: Any]])?.count == 2 &&
                  (result.recovery?["documented_scalar"] as? [String: Any])?["scalar_retry_eligible"] as? Bool == true,
                  "known unsupported scalars get one exact fresh scalar read and preserve unsupported errors without array queries")
        fixtures += 1
    }
    for (name, _) in typed {
        let wrong = recoverNativeMetadataBatch([name], initial: [name: original], query: {
            ReadResult(value: [[] as CFArray] as CFArray, error: .success, attempts: 1)
        })[name]!
        try check(wrong.error == .failure && wrong.value == nil && wrong.recovery?["item_kind"] as? String == "value" &&
                  wrong.recovery?["resolution_kind"] as? String == "unresolved" &&
                  (wrong.recovery?["value_validation"] as? [String: Any])?["valid"] as? Bool == false,
                  "an actual but wrong native bulk type cannot resolve a known scalar")
        fixtures += 1
    }
    let cannotComplete = ReadResult<CFTypeRef>(value: kCFBooleanTrue!, error: .cannotComplete, attempts: 3)
    let absent = recoverNativeScalar("AXGrowArea", cannotComplete, refresh: { refresh() }, query: { _ in ReadResult(value: owner, error: .noValue, attempts: 1) })
    try check(absent.error == .noValue && absent.value == nil && absent.attempts == 3 &&
              absent.recovery?["resolution_kind"] as? String == "absence",
              "explicit fresh native noValue confirms absence and discards any untrusted returned value")
    fixtures += 1
    var envelopeError = AXError.success
    let errorEnvelope = AXValueCreate(.axError, &envelopeError)!
    let rejected: [ReadResult<CFTypeRef>] = [ReadResult(value: nil, error: .success, attempts: 1),
        ReadResult(value: kCFNull!, error: .success, attempts: 1), ReadResult(value: [] as CFArray, error: .success, attempts: 1),
        ReadResult(value: kCFBooleanFalse!, error: .success, attempts: 1), ReadResult(value: errorEnvelope, error: .success, attempts: 1),
        ReadResult(value: owner, error: .attributeUnsupported, attempts: 1), ReadResult(value: owner, error: .failure, attempts: 1),
        ReadResult(value: owner, error: .cannotComplete, attempts: 1)]
    for next in rejected {
        var calls = 0
        let result = recoverNativeScalar("AXGrowArea", original, refresh: { refresh() }, query: { _ in calls += 1; return next })
        try check(calls == 1 && result.error == .failure && result.value == nil &&
                  result.recovery?["resolution_kind"] as? String == "unresolved" &&
                  (result.recovery?["query_status"] as? [String: Any])?["code"] as? Int32 == next.error.rawValue,
                  "one fresh read preserves nil-success, null, error-envelope, wrong-type and native error evidence without masking failure")
        fixtures += 1
    }
    let wrongGeometry = recoverNativeScalar("AXPosition", original, refresh: { refresh() }, query: { _ in ReadResult(value: sizeValue, error: .success, attempts: 1) })
    try check(wrongGeometry.error == .failure && (wrongGeometry.recovery?["value_validation"] as? [String: Any])?["ax_value_type"] as? String == "cgSize",
              "geometry recovery requires the exact native AXValue subtype")
    fixtures += 1
    let identityChangedResults: [ReadResult<CFTypeRef>] = [ReadResult(value: owner, error: .success, attempts: 1), ReadResult(value: nil, error: .noValue, attempts: 1)]
    for next in identityChangedResults {
        let result = recoverNativeScalar("AXGrowArea", original, refresh: { refresh() }, query: { _ in next }, queryIdentityMatches: { false })
        try check(result.error == .failure && result.value == nil && result.recovery?["query_process_identity_matches"] as? Bool == false &&
                  result.recovery?["resolution_kind"] as? String == "unresolved",
                  "post-query process/launch identity changes cannot resolve either content or absence")
        fixtures += 1
    }
    var intermediateCalls = 0
    let failedRefreshes: [() -> NativeScalarRefreshResult] = [
        { refresh(process: { _ in false }) }, { refresh(rootOverride: swapped) }, { refresh(timeout: .failure) },
        { refresh(readError: .cannotComplete) }, { refresh(value: nil) }, { refresh(value: [swapped] as CFArray) },
        { refresh(value: [] as CFArray) }, { refresh(value: ["wrong-reference"] as CFArray) },
        { refresh(selector: [["attribute": "AXChildren", "value_path": [true]]]) },
        { refresh(selector: [["attribute": "AXChildren", "value_path": ["not-an-array-index"]]]) },
        { refresh(missingPrefix: true) }, { refresh(pidError: .invalidUIElement) }, { refresh(pidOverride: ownerPID + 1) },
        { refresh(process: { _ in intermediateCalls += 1; return intermediateCalls != 3 }) }]
    for makeRefresh in failedRefreshes {
        var calls = 0
        let result = recoverNativeScalar("AXGrowArea", original, refresh: makeRefresh, query: { _ in calls += 1; return ReadResult(value: owner, error: .success, attempts: 1) })
        try check(calls == 0 && result.error == .failure && result.recovery?["query_status"] is NSNull &&
                  result.recovery?["query_process_identity_matches"] is NSNull &&
                  (result.recovery?["refresh"] as? [String: Any])?["resolved"] as? Bool == false,
                  "failed exact path/reference/PID/launch validation prevents every scalar query")
        fixtures += 1
    }
    let nestedPath: [[String: Any]] = [["attribute": "AXSections", "value_path": ["content", 0]]]
    let nested = refresh(selector: nestedPath, value: ["content": [owner]] as CFDictionary)
    try check(nested.evidence["resolved"] as? Bool == true &&
              ((nested.evidence["steps"] as? [[String: Any]])?.first?["path_steps"] as? [[String: Any]])?.count == 2,
              "fresh native paths can traverse exact string dictionary keys and array indexes")
    fixtures += 1
    let rootOwner = refresh(selector: [])
    try check(rootOwner.evidence["resolved"] as? Bool == true && rootOwner.evidence["pid"] as? NSNumber == NSNumber(value: rootPID),
              "an empty selector path refreshes only the exact original application root")
    fixtures += 1
    var arrayCalls = 0, scalarCalls = 0
    let custom = "AXCustomSelectionRanges"
    let generic = recoverNativeMetadataReads([custom], initial: [custom: original], batchQuery: { ReadResult(value: [kCFNull!] as CFArray, error: .success, attempts: 1) },
        arrayQuery: { _, result in arrayCalls += 1; return recoverNativeArray(result, count: { ReadResult(value: NSNumber(value: 0), error: .success, attempts: 1) }, values: { _, _ in throwawayArrayPage() }) },
        scalarQuery: { _, result in scalarCalls += 1; return result })[custom]!
    try check(generic.error == .success && (generic.value as? [Any])?.isEmpty == true && arrayCalls == 1 && scalarCalls == 0 &&
              generic.recovery?["documented_scalar"] == nil,
              "unknown custom array attributes retain native count/page recovery")
    fixtures += 1
    let summary = nativeMetadataFailureSummary([["stage": "attribute_read", "status": nativeReadStatus(ReadResult<CFTypeRef>(value: nil, error: .attributeUnsupported, attempts: 1))],
        ["stage": "attribute_read", "status": nativeReadStatus(original)], ["stage": "serialization", "status": ["code": 0]]])
    try check(summary == ["attribute_unsupported": 1, "other_read_failures": 1], "failure summary partitions only native read failures and preserves unsupported counts")
    fixtures += 1
    return fixtures
}

func nativeScalarUnsupportedRetrySelfTest() throws -> Int {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw EngineError.message("Native unsupported scalar retry fixture failed: \(message)") }
    }
    // Opaque reference constructors and native AXValue conversions only;
    // every attribute/PID/launch response is a synthetic callback.
    let rootPID: pid_t = 44001, ownerPID: pid_t = 44002
    let root = AXUIElementCreateApplication(rootPID), owner = AXUIElementCreateApplication(ownerPID)
    let other = AXUIElementCreateApplication(44003)
    let path: [[String: Any]] = [["attribute": "AXChildren", "value_path": [0]]]
    var unsupportedError = AXError.attributeUnsupported, absenceError = AXError.noValue
    let unsupportedEnvelope = AXValueCreate(.axError, &unsupportedError)!, absenceEnvelope = AXValueCreate(.axError, &absenceError)!
    let original = ReadResult<CFTypeRef>(value: nil, error: .attributeUnsupported, attempts: 1)
    func result(_ name: String, next: ReadResult<CFTypeRef>, initial: ReadResult<CFTypeRef> = original,
                bulk: CFTypeRef = unsupportedEnvelope, wrongOwner: Bool = false,
                preIdentity: Bool = true, postIdentity: Bool = true) -> (read: ReadResult<CFTypeRef>, scalarCalls: Int, arrayCalls: Int) {
        var scalarCalls = 0, arrayCalls = 0
        let read = recoverNativeMetadataReads([name], initial: [name: initial], batchQuery: {
            ReadResult(value: [bulk] as CFArray, error: .success, attempts: 1)
        }, arrayQuery: { _, value in arrayCalls += 1; return value }, scalarQuery: { attribute, initial in
            recoverNativeScalar(attribute, initial, refresh: {
                refreshNativeScalarTarget(selectorPath: path, rootPID: rootPID, expectedPID: ownerPID,
                    recordedAtPath: { $0.isEmpty ? (root, rootPID) : (owner, ownerPID) },
                    processMatches: { _ in preIdentity }, createRoot: { root }, setTimeout: { _ in .success },
                    readAttribute: { _, _ in ReadResult(value: [wrongOwner ? other : owner] as CFArray, error: .success, attempts: 1) },
                    elementPID: { _ in ReadResult(value: NSNumber(value: ownerPID), error: .success, attempts: 1) })
            }, query: { _ in scalarCalls += 1; return next }, queryIdentityMatches: { postIdentity })
        })[name]!
        return (read, scalarCalls, arrayCalls)
    }
    var point = CGPoint(x: 9, y: 10), size = CGSize(width: 11, height: 12), rect = CGRect(x: 13, y: 14, width: 15, height: 16)
    let pointValue = AXValueCreate(.cgPoint, &point)!, sizeValue = AXValueCreate(.cgSize, &size)!, rectValue = AXValueCreate(.cgRect, &rect)!
    let typed: [(String, CFTypeRef)] = [("AXGrowArea", owner), ("AXTopLevelUIElement", owner),
                                      ("AXPosition", pointValue), ("AXSize", sizeValue), ("AXFrame", rectValue)]
    var fixtures = 0
    for (name, value) in typed {
        let recovered = result(name, next: ReadResult(value: value, error: .success, attempts: 1))
        let queries = recovered.read.recovery?["queries"] as? [[String: Any]]
        try check(recovered.read.error == .success && recovered.scalarCalls == 1 && recovered.arrayCalls == 0 &&
                  recovered.read.attempts == 1 && queries?.count == 2 &&
                  (queries?.last?["initial_status"] as? [String: Any])?["code"] as? Int32 == AXError.attributeUnsupported.rawValue &&
                  (recovered.read.recovery?["initial_status"] as? [String: Any])?["code"] as? Int32 == AXError.attributeUnsupported.rawValue &&
                  (recovered.read.recovery?["documented_scalar"] as? [String: Any])?["scalar_retry_eligible"] as? Bool == true,
                  "each initially unsupported scalar may recover its real typed native value in one exact fresh query")
        fixtures += 1
    }
    let absence = result("AXTopLevelUIElement", next: ReadResult(value: owner, error: .noValue, attempts: 1),
                         initial: ReadResult(value: kCFBooleanTrue!, error: .attributeUnsupported, attempts: 1))
    try check(absence.read.error == .noValue && absence.read.value == nil && absence.scalarCalls == 1 && absence.arrayCalls == 0 &&
              absence.read.recovery?["resolution_kind"] as? String == "absence",
              "explicit fresh native noValue resolves unsupported as absence and drops untrusted values")
    fixtures += 1
    let stillUnsupported = result("AXGrowArea", next: ReadResult(value: owner, error: .attributeUnsupported, attempts: 1))
    try check(stillUnsupported.read.error == .attributeUnsupported && stillUnsupported.read.value == nil &&
              stillUnsupported.scalarCalls == 1 && stillUnsupported.arrayCalls == 0 &&
              stillUnsupported.read.recovery?["resolution_kind"] as? String == "unresolved",
              "a fresh unsupported result preserves the original unsupported error even with a returned native reference")
    fixtures += 1
    let wrongValues: [(String, CFTypeRef)] = [("AXPosition", sizeValue), ("AXGrowArea", [] as CFArray)]
    for (name, wrong) in wrongValues {
        let rejected = result(name, next: ReadResult(value: wrong, error: .success, attempts: 1))
        try check(rejected.read.error == .attributeUnsupported && rejected.read.value == nil && rejected.scalarCalls == 1 &&
                  rejected.arrayCalls == 0 && rejected.read.recovery?["resolution_kind"] as? String == "unresolved",
                  "wrong geometry subtypes or arrays cannot replace an unsupported scalar error")
        fixtures += 1
    }
    let swapped = result("AXGrowArea", next: ReadResult(value: owner, error: .success, attempts: 1), wrongOwner: true)
    try check(swapped.read.error == .attributeUnsupported && swapped.scalarCalls == 0 && swapped.arrayCalls == 0 &&
              (swapped.read.recovery?["queries"] as? [[String: Any]])?.last?["query_status"] is NSNull,
              "a swapped native owner refuses unsupported retry before any scalar query")
    fixtures += 1
    let changedBefore = result("AXSize", next: ReadResult(value: sizeValue, error: .success, attempts: 1), preIdentity: false)
    try check(changedBefore.read.error == .attributeUnsupported && changedBefore.scalarCalls == 0 && changedBefore.arrayCalls == 0,
              "changed process launch identity prevents unsupported retry before any query")
    fixtures += 1
    let changedAfter = result("AXFrame", next: ReadResult(value: rectValue, error: .success, attempts: 1), postIdentity: false)
    try check(changedAfter.read.error == .attributeUnsupported && changedAfter.scalarCalls == 1 && changedAfter.arrayCalls == 0 &&
              (changedAfter.read.recovery?["queries"] as? [[String: Any]])?.last?["query_process_identity_matches"] as? Bool == false,
              "a post-query identity change preserves unsupported despite a typed native reply")
    fixtures += 1
    var queries = 0
    let invalid = ReadResult<CFTypeRef>(value: nil, error: .invalidUIElement, attempts: 1)
    let untouched = recoverNativeScalar("AXGrowArea", invalid, refresh: { queries += 1; return NativeScalarRefreshResult(element: nil, evidence: [:]) },
                                       query: { _ in queries += 1; return ReadResult(value: owner, error: .success, attempts: 1) })
    try check(untouched.error == .invalidUIElement && untouched.recovery == nil && queries == 0,
              "unsupported retry does not broaden recovery to invalid references")
    fixtures += 1
    let bulkTyped = result("AXSize", next: ReadResult(value: nil, error: .failure, attempts: 1), bulk: sizeValue)
    try check(bulkTyped.read.error == .success && bulkTyped.scalarCalls == 0 && bulkTyped.arrayCalls == 0 &&
              (bulkTyped.read.recovery?["queries"] as? [[String: Any]])?.count == 1,
              "a typed bulk value terminates unsupported recovery before a fresh query")
    fixtures += 1
    let bulkAbsence = result("AXGrowArea", next: ReadResult(value: nil, error: .failure, attempts: 1), bulk: absenceEnvelope)
    try check(bulkAbsence.read.error == .noValue && bulkAbsence.read.value == nil && bulkAbsence.scalarCalls == 0 &&
              bulkAbsence.arrayCalls == 0 && (bulkAbsence.read.recovery?["queries"] as? [[String: Any]])?.count == 1,
              "an exact decoded bulk noValue terminates unsupported recovery as absence")
    fixtures += 1
    return fixtures
}

func nativeMenuReferenceRetrySelfTest() throws -> Int {
    var fixtures = 0
    func require(_ condition: Bool, _ message: String) throws {
        fixtures += 1
        if !condition { throw EngineError.message("Native menu-reference retry self-test failed: \(message)") }
    }
    let rootPID: pid_t = 46001, prefixPID: pid_t = 46002, ownerPID: pid_t = 46003
    let root = AXUIElementCreateApplication(rootPID), prefix = AXUIElementCreateApplication(prefixPID)
    let owner = AXUIElementCreateApplication(ownerPID), changed = AXUIElementCreateApplication(46004)
    let selector: [[String: Any]] = [["attribute": "AXChildren", "value_path": [0]], ["attribute": "AXChildren", "value_path": [0]]]
    let roleStatus = ReadResult<CFTypeRef>(value: "AXMenuItem" as CFString, error: .success, attempts: 1).status
    let original = ReadResult<CFTypeRef>(value: nil, error: .attributeUnsupported, attempts: 1)
    func fresh(selected: CFTypeRef = [changed] as CFArray, pidError: AXError = .success,
               pid: pid_t = prefixPID, process: Bool = true, timeout: AXError = .success) -> NativeScalarRefreshResult {
        refreshNativeScalarTarget(selectorPath: selector, rootPID: rootPID, expectedPID: ownerPID,
            recordedAtPath: { path in path.isEmpty ? (root, rootPID) : path.count == 1 ? (prefix, prefixPID) : (owner, ownerPID) },
            processMatches: { _ in process }, createRoot: { root }, setTimeout: { _ in timeout },
            readAttribute: { _, _ in ReadResult(value: selected, error: .success, attempts: 1) },
            elementPID: { _ in ReadResult(value: pidError == .success ? NSNumber(value: pid) : nil, error: pidError, attempts: 1) })
    }
    func retained(target: AXUIElement = owner, role: String = "AXMenuItem", roleRead: [String: Any] = roleStatus,
                  rootError: AXError = .success, ownerError: AXError = .success,
                  rootNativePID: pid_t = rootPID, ownerNativePID: pid_t = ownerPID,
                  process: (pid_t) -> Bool = { _ in true }) -> NativeScalarRefreshResult {
        validateRetainedNativeScalarTarget(nodeID: 2, rootID: 0, rootPID: rootPID, expectedPID: ownerPID,
            ownerRole: role, ownerRoleStatus: roleRead, retainedOwner: target,
            recordedAtID: { id in id == 0 ? (root, rootPID) : id == 2 ? (owner, ownerPID) : nil },
            processMatches: process, elementPID: { element in
                let isRoot = CFEqual(element, root), error = isRoot ? rootError : ownerError
                return ReadResult(value: error == .success ? NSNumber(value: isRoot ? rootNativePID : ownerNativePID) : nil, error: error, attempts: 1)
            })
    }
    var queries = 0, retainedChecks = 0
    func run(_ next: ReadResult<CFTypeRef>, attribute: String = "AXTopLevelUIElement",
             refresh: () -> NativeScalarRefreshResult = { fresh() },
             before: @escaping () -> NativeScalarRefreshResult = { retained() },
             after: @escaping () -> NativeScalarRefreshResult = { retained() }, identity: Bool = true) -> ReadResult<CFTypeRef> {
        queries = 0; retainedChecks = 0
        return recoverNativeScalar(attribute, original, refresh: refresh, query: { element in
            queries += 1
            precondition(CFEqual(element, owner), "A replacement menu prefix must never be the query target")
            return next
        }, queryIdentityMatches: { identity }, retainedTarget: { retainedChecks += 1; return before() },
        retainedQueryValidation: { element in
            precondition(CFEqual(element, owner), "Post-query continuity must check the original owner")
            return after()
        })
    }
    let mismatch = fresh()
    try require(nativeScalarRetainedReferenceEligible(mismatch.evidence), "An isolated intermediate-prefix CFEqual mismatch is eligible")
    var rootMismatch = mismatch.evidence
    rootMismatch["root_same_element"] = false
    try require(!nativeScalarRetainedReferenceEligible(rootMismatch), "A changed native root can never enter retained mode")
    let exactRefresh = refreshNativeScalarTarget(selectorPath: selector, rootPID: rootPID, expectedPID: ownerPID,
        recordedAtPath: { path in path.isEmpty ? (root, rootPID) : path.count == 1 ? (prefix, prefixPID) : (owner, ownerPID) },
        processMatches: { _ in true }, createRoot: { root }, setTimeout: { _ in .success },
        readAttribute: { current, _ in ReadResult(value: [CFEqual(current, root) ? prefix : owner] as CFArray, error: .success, attempts: 1) },
        elementPID: { current in ReadResult(value: NSNumber(value: CFEqual(current, prefix) ? prefixPID : ownerPID), error: .success, attempts: 1) })
    let exact = run(ReadResult(value: root, error: .success, attempts: 1), refresh: { exactRefresh })
    try require(exact.error == .success && queries == 1 && retainedChecks == 0 && exact.recovery?["query_target"] as? String == "fresh_exact_reference" &&
                exact.recovery?["retained_reference"] is NSNull && exact.recovery?["query_retained_reference_validation"] is NSNull,
                "A fresh exact native reference remains the normal one-query path")
    let typed = run(ReadResult(value: root, error: .success, attempts: 1))
    try require(typed.error == .success && queries == 1 && retainedChecks == 1 &&
                typed.recovery?["query_target"] as? String == "retained_original_reference" &&
                (typed.recovery?["refresh"] as? [String: Any])?["resolved"] as? Bool == false,
                "One typed-value query uses the original owner and preserves failed fresh evidence")
    let absence = run(ReadResult(value: changed, error: .noValue, attempts: 1))
    try require(absence.error == .noValue && absence.value == nil && queries == 1 && absence.recovery?["resolution_kind"] as? String == "absence",
                "Native noValue is absence and drops untrusted returned content")
    for next in [ReadResult<CFTypeRef>(value: owner, error: .attributeUnsupported, attempts: 1),
                 ReadResult<CFTypeRef>(value: nil, error: .invalidUIElement, attempts: 1),
                 ReadResult<CFTypeRef>(value: nil, error: .success, attempts: 1),
                 ReadResult<CFTypeRef>(value: [] as CFArray, error: .success, attempts: 1)] {
        let result = run(next)
        try require(result.error == .attributeUnsupported && queries == 1 && result.recovery?["resolved"] as? Bool == false,
                    "Native scalar errors, nil-success and wrong types retain the original failure")
    }
    let badRefreshes = [fresh(selected: [] as CFArray), fresh(selected: [kCFBooleanTrue!] as CFArray),
                        fresh(pidError: .invalidUIElement), fresh(pid: prefixPID + 1), fresh(process: false), fresh(timeout: .failure)]
    for invalid in badRefreshes {
        let result = run(ReadResult(value: root, error: .success, attempts: 1), refresh: { invalid })
        try require(result.error == .attributeUnsupported && queries == 0 && retainedChecks == 0,
                    "A native path/type/PID/process/timeout failure must never select retained mode")
    }
    var failedRead = mismatch.evidence
    var failedSteps = failedRead["steps"] as! [[String: Any]]
    failedSteps[0]["query_status"] = ["code": AXError.failure.rawValue, "name": "failure", "attempts": 1]
    failedRead["steps"] = failedSteps
    try require(!nativeScalarRetainedReferenceEligible(failedRead), "A failed native prefix read is not an isolated reference mismatch")
    let badBefore = [retained(target: changed), retained(rootError: .invalidUIElement), retained(ownerError: .invalidUIElement),
                     retained(rootNativePID: rootPID + 1), retained(ownerNativePID: ownerPID + 1), retained(process: { _ in false })]
    for invalid in badBefore {
        let result = run(ReadResult(value: root, error: .success, attempts: 1), before: { invalid })
        try require(result.error == .attributeUnsupported && queries == 0 && retainedChecks == 1 &&
                    result.recovery?["query_target"] is NSNull,
                    "Unconfirmed registry/native PID/launch identity withholds the scalar query")
    }
    for invalid in [retained(ownerError: .invalidUIElement), retained(ownerNativePID: ownerPID + 1), retained(process: { _ in false })] {
        let result = run(ReadResult(value: root, error: .success, attempts: 1), after: { invalid })
        try require(result.error == .attributeUnsupported && queries == 1 && result.recovery?["query_target"] as? String == "retained_original_reference",
                    "Post-query native PID/launch failure preserves query evidence and original failure")
    }
    let changedIdentity = run(ReadResult(value: root, error: .success, attempts: 1), identity: false)
    try require(changedIdentity.error == .attributeUnsupported && queries == 1,
                "Existing post-query launch continuity remains mandatory in retained mode")
    try require(retained(role: "AXButton").evidence["resolved"] as? Bool == false,
                "An arbitrary non-menu role cannot validate for retained mode")
    try require(retained(roleRead: ["code": AXError.failure.rawValue, "name": "failure", "attempts": 1]).evidence["resolved"] as? Bool == false,
                "A failed captured native role read cannot authorize retained mode")
    let otherAttribute = run(ReadResult(value: root, error: .success, attempts: 1), attribute: "AXGrowArea")
    try require(otherAttribute.error == .attributeUnsupported && queries == 0 && retainedChecks == 0,
                "Retained-reference routing is limited to AXTopLevelUIElement")
    var launchChecks = 0
    let duringValidation = retained(process: { _ in launchChecks += 1; return launchChecks < 3 })
    try require(duringValidation.evidence["resolved"] as? Bool == false && duringValidation.evidence["owner_pid_status"] is [String: Any],
                "Launch continuity is checked again after native PID validation")
    return fixtures
}

func nativeMetadataBatchRecoverySelfTest() throws -> Int {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw EngineError.message("Native bulk metadata fixture failed: \(message)") }
    }
    func initial(_ names: [String], error: AXError = .failure) -> [String: ReadResult<CFTypeRef>] {
        Dictionary(uniqueKeysWithValues: names.map { ($0, ReadResult(value: nil, error: error, attempts: error == .cannotComplete ? 3 : 1)) })
    }
    func envelope(_ error: AXError) -> AXValue {
        var error = error
        return AXValueCreate(.axError, &error)!
    }
    var fixtures = 0
    let names = ["AXEnabled", "AXValue", "AXSelectedTextRanges", "AXDescription", "AXHelp", "AXPosition"]
    var point = CGPoint(x: 2, y: 3)
    let nativePoint = AXValueCreate(.cgPoint, &point)!
    let mixed: [Any] = [kCFBooleanFalse!, NSNumber(value: 0), [] as CFArray, kCFNull!, envelope(.attributeUnsupported), nativePoint]
    var queryCalls = 0
    let recovered = recoverNativeMetadataBatch(names, initial: initial(names), query: {
        queryCalls += 1; return ReadResult(value: mixed as CFArray, error: .success, attempts: 1)
    })
    try check(queryCalls == 1 && recovered["AXEnabled"]?.error == .success &&
              (recovered["AXEnabled"]?.value as? NSNumber)?.boolValue == false &&
              recovered["AXValue"]?.error == .success && (recovered["AXValue"]?.value as? NSNumber)?.intValue == 0 &&
              recovered["AXSelectedTextRanges"]?.error == .success && (recovered["AXSelectedTextRanges"]?.value as? [Any])?.isEmpty == true &&
              recovered["AXDescription"]?.error == .failure && recovered["AXDescription"]?.recovery?["item_kind"] as? String == "null" &&
              recovered["AXHelp"]?.error == .failure && recovered["AXHelp"]?.recovery?["item_error_decoded"] as? Bool == true &&
              (recovered["AXHelp"]?.recovery?["item_status"] as? [String: Any])?["code"] as? Int32 == AXError.attributeUnsupported.rawValue &&
              recovered["AXPosition"]?.error == .success, "mixed native values, null, and error envelopes remain distinct")
    fixtures += 1
    let one = ["AXTitle"]
    let outerFailure = recoverNativeMetadataBatch(one, initial: initial(one), query: {
        ReadResult(value: ["Native title"] as CFArray, error: .cannotComplete, attempts: 1)
    })
    try check(outerFailure["AXTitle"]?.error == .failure && outerFailure["AXTitle"]?.value == nil &&
              (outerFailure["AXTitle"]?.recovery?["query_status"] as? [String: Any])?["code"] as? Int32 == AXError.cannotComplete.rawValue,
              "an outer query error never turns a returned slot into success")
    fixtures += 1
    let nilArray = recoverNativeMetadataBatch(one, initial: initial(one), query: { ReadResult(value: nil, error: .success, attempts: 1) })
    try check(nilArray["AXTitle"]?.error == .failure && nilArray["AXTitle"]?.recovery?["has_array"] as? Bool == false &&
              nilArray["AXTitle"]?.recovery?["returned_slot_count"] is NSNull, "success with nil is unresolved")
    fixtures += 1
    let two = ["AXTitle", "AXDescription"]
    for payload: [Any] in [["only-one"], ["one", "two", "unexpected-third"]] {
        let cardinality = recoverNativeMetadataBatch(two, initial: initial(two), query: { ReadResult(value: payload as CFArray, error: .success, attempts: 1) })
        try check(cardinality.values.allSatisfy { $0.error == .failure && $0.value == nil && $0.recovery?["resolved"] as? Bool == false },
                  "a cardinality mismatch invalidates every slot mapping")
        fixtures += 1
    }
    let ordered = recoverNativeMetadataBatch(two, initial: initial(two), query: { ReadResult(value: ["first", "second"] as CFArray, error: .success, attempts: 1) })
    try check(ordered["AXTitle"]?.value as? String == "first" && ordered["AXDescription"]?.value as? String == "second" &&
              ordered["AXTitle"]?.recovery?["query_attributes"] as? [String] == two, "native slots preserve exact query order")
    fixtures += 1
    let null = recoverNativeMetadataBatch(one, initial: initial(one), query: { ReadResult(value: [kCFNull!] as CFArray, error: .success, attempts: 1) })
    try check(null["AXTitle"]?.error == .failure && null["AXTitle"]?.recovery?["item_kind"] as? String == "null" &&
              null["AXTitle"]?.recovery?["cf_type_id"] as? Int == Int(CFNullGetTypeID()), "CFNull retains its native runtime type and is not an empty value")
    fixtures += 1
    for error: AXError in [.noValue, .illegalArgument, .failure, .cannotComplete, .success] {
        let item = recoverNativeMetadataBatch(one, initial: initial(one), query: { ReadResult(value: [envelope(error)] as CFArray, error: .success, attempts: 1) })
        try check(item["AXTitle"]?.error == (error == .noValue ? .noValue : .failure) && item["AXTitle"]?.value == nil &&
                  item["AXTitle"]?.recovery?["item_error_decoded"] as? Bool == true &&
                  (item["AXTitle"]?.recovery?["item_status"] as? [String: Any])?["code"] as? Int32 == error.rawValue &&
                  item["AXTitle"]?.recovery?["resolution_kind"] as? String == (error == .noValue ? "absence" : "unresolved"),
                  "decoded noValue confirms absence; other error envelopes retain the original failure without inventing a value")
        fixtures += 1
    }
    let unreadable = recoverNativeMetadataBatch(one, initial: initial(one), query: { ReadResult(value: [envelope(.failure)] as CFArray, error: .success, attempts: 1) }, decodeError: { _ in nil })
    try check(unreadable["AXTitle"]?.error == .failure && unreadable["AXTitle"]?.recovery?["item_error_decoded"] as? Bool == false &&
              unreadable["AXTitle"]?.recovery?["item_status"] is NSNull, "undecodable error envelopes stay unresolved")
    fixtures += 1
    queryCalls = 0
    let absent = recoverNativeMetadataBatch([], initial: [:], query: { queryCalls += 1; return ReadResult(value: nil, error: .failure, attempts: 1) })
    try check(absent.isEmpty && queryCalls == 0, "no failed candidates means no bulk query")
    fixtures += 1
    return fixtures
}

func nativeAbsenceRecoverySelfTest() throws -> Int {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw EngineError.message("Native absence recovery fixture failed: \(message)") }
    }
    func envelope(_ error: AXError) -> AXValue {
        var error = error
        return AXValueCreate(.axError, &error)!
    }
    let name = "AXHelp"
    let initial = ReadResult<CFTypeRef>(value: nil, error: .failure, attempts: 1)
    let noValue = envelope(.noValue)
    var fixtures = 0
    let bulk = recoverNativeMetadataBatch([name], initial: [name: initial], query: {
        ReadResult(value: [noValue] as CFArray, error: .success, attempts: 1)
    })[name]!
    try check(bulk.error == .noValue && bulk.value == nil && bulk.attempts == 1 &&
              bulk.recovery?["resolved"] as? Bool == true && bulk.recovery?["resolution_kind"] as? String == "absence" &&
              bulk.recovery?["item_kind"] as? String == "ax_error" && bulk.recovery?["item_error_decoded"] as? Bool == true &&
              (bulk.recovery?["item_status"] as? [String: Any])?["code"] as? Int32 == AXError.noValue.rawValue,
              "an exact native noValue slot confirms absence with its real envelope evidence")
    fixtures += 1
    var arrayCalls = 0
    func composite(_ original: ReadResult<CFTypeRef>, payload: CFArray? = [noValue] as CFArray,
                   error: AXError = .success) -> ReadResult<CFTypeRef> {
        recoverNativeMetadataReads([name], initial: [name: original], batchQuery: {
            ReadResult(value: payload, error: error, attempts: 1)
        }, arrayQuery: { _, result in
            arrayCalls += 1
            return recoverNativeArray(result, count: { ReadResult(value: nil, error: .illegalArgument, attempts: 1) },
                                      values: { _, _ in throwawayArrayPage() })
        }, scalarQuery: { _, original in original })[name]!
    }
    let cannotComplete = ReadResult<CFTypeRef>(value: nil, error: .cannotComplete, attempts: 3)
    let terminal = composite(cannotComplete)
    try check(terminal.error == .noValue && terminal.value == nil && terminal.attempts == 3 && arrayCalls == 0 &&
              terminal.recovery?["resolution_kind"] as? String == "absence" &&
              terminal.recovery?["selected_method"] as? String == "AXUIElementCopyMultipleAttributeValues" &&
              (terminal.recovery?["queries"] as? [[String: Any]])?.count == 1 &&
              (terminal.recovery?["initial_status"] as? [String: Any])?["code"] as? Int32 == AXError.cannotComplete.rawValue,
              "confirmed absence is terminal and retains the original failed read and attempts")
    fixtures += 1
    let untrusted = ReadResult<CFTypeRef>(value: kCFBooleanTrue!, error: .failure, attempts: 1)
    let discarded = composite(untrusted)
    try check(discarded.error == .noValue && discarded.value == nil && arrayCalls == 0,
              "confirmed absence drops any value accompanying the original failed read")
    fixtures += 1
    let empty = composite(initial, payload: [[] as CFArray] as CFArray)
    try check(empty.error == .success && (empty.value as? [Any])?.isEmpty == true &&
              empty.recovery?["resolution_kind"] as? String == "value" && arrayCalls == 0,
              "a genuine empty array remains a native value rather than absence")
    fixtures += 1
    for (payload, error): (CFArray?, AXError) in [([] as CFArray, .success),
                                                ([noValue, noValue] as CFArray, .success),
                                                ([noValue] as CFArray, .failure), (nil, .success)] {
        let result = composite(initial, payload: payload, error: error)
        try check(result.error == .failure && result.value == nil && result.recovery?["resolved"] as? Bool == false &&
                  result.recovery?["resolution_kind"] as? String == "unresolved",
                  "outer failure, nil, or invalid cardinality cannot confirm a noValue slot")
        fixtures += 1
    }
    let null = composite(initial, payload: [kCFNull!] as CFArray)
    try check(null.error == .failure && null.value == nil && null.recovery?["resolution_kind"] as? String == "unresolved",
              "CFNull is not native noValue evidence")
    fixtures += 1
    for error: AXError in [.success, .attributeUnsupported] {
        let result = recoverNativeMetadataBatch([name], initial: [name: initial], query: {
            ReadResult(value: [envelope(error)] as CFArray, error: .success, attempts: 1)
        })[name]!
        try check(result.error == .failure && result.value == nil && result.recovery?["resolution_kind"] as? String == "unresolved",
                  "success or unsupported error envelopes do not become absence or content")
        fixtures += 1
    }
    let undecodable = recoverNativeMetadataBatch([name], initial: [name: initial], query: {
        ReadResult(value: [noValue] as CFArray, error: .success, attempts: 1)
    }, decodeError: { _ in nil })[name]!
    try check(undecodable.error == .failure && undecodable.value == nil &&
              undecodable.recovery?["resolution_kind"] as? String == "unresolved" &&
              undecodable.recovery?["item_error_decoded"] as? Bool == false,
              "an undecodable native error envelope cannot confirm absence")
    fixtures += 1
    let names = ["AXHelp", "AXSelectedTextRanges"]
    let mixed = recoverNativeMetadataBatch(names, initial: [names[0]: initial, names[1]: initial], query: {
        ReadResult(value: [noValue, [] as CFArray] as CFArray, error: .success, attempts: 1)
    })
    try check(mixed[names[0]]?.error == .noValue && mixed[names[0]]?.value == nil &&
              mixed[names[0]]?.recovery?["slot_index"] as? Int == 0 &&
              mixed[names[1]]?.error == .success && (mixed[names[1]]?.value as? [Any])?.isEmpty == true &&
              mixed[names[1]]?.recovery?["resolution_kind"] as? String == "value" &&
              mixed[names[1]]?.recovery?["slot_index"] as? Int == 1,
              "exact mixed slots preserve independent absence and real empty-array outcomes")
    fixtures += 1
    let pagedEmpty = recoverNativeArray(initial, count: { ReadResult(value: NSNumber(value: 0), error: .success, attempts: 1) },
                                       values: { _, _ in throwawayArrayPage() })
    try check(pagedEmpty.error == .success && pagedEmpty.recovery?["resolution_kind"] as? String == "value",
              "native count-confirmed empty arrays resolve as values")
    fixtures += 1
    let actions = recoverNativeActionNames(ReadResult(value: nil, error: .failure, attempts: 1), query: {
        ReadResult(value: [] as CFArray, error: .success, attempts: 1)
    })
    try check(actions.error == .success && actions.recovery?["resolution_kind"] as? String == "value",
              "native empty action-name arrays resolve as values")
    fixtures += 1
    let unsupported = composite(ReadResult(value: nil, error: .attributeUnsupported, attempts: 1))
    try check(unsupported.error == .noValue && unsupported.value == nil &&
              unsupported.recovery?["resolution_kind"] as? String == "absence" &&
              (unsupported.recovery?["queries"] as? [[String: Any]])?.count == 1 && arrayCalls == 5,
              "an advertised unsupported original read may be resolved by exact noValue evidence without another array query")
    fixtures += 1
    return fixtures
}

func nativeMetadataCompositeRecoverySelfTest() throws -> Int {
    let name = "AXSelectedTextRanges"
    let original = ReadResult<CFTypeRef>(value: nil, error: .cannotComplete, attempts: 3)
    var arrayCalls = 0
    let bulk = recoverNativeMetadataReads([name], initial: [name: original], batchQuery: {
        ReadResult(value: [kCFBooleanFalse!] as CFArray, error: .success, attempts: 1)
    }, arrayQuery: { _, result in arrayCalls += 1; return result }, scalarQuery: { _, original in original })
    guard arrayCalls == 0, bulk[name]?.error == .success, bulk[name]?.attempts == 3,
          bulk[name]?.recovery?["method"] as? String == "native_metadata_recovery",
          bulk[name]?.recovery?["selected_method"] as? String == "AXUIElementCopyMultipleAttributeValues",
          (bulk[name]?.recovery?["queries"] as? [[String: Any]])?.count == 1,
          (bulk[name]?.recovery?["initial_status"] as? [String: Any])?["native_read_recovery"] == nil else {
        throw EngineError.message("Composite native bulk success fixture failed.")
    }
    let array = recoverNativeMetadataReads([name], initial: [name: original], batchQuery: {
        ReadResult(value: [kCFNull!] as CFArray, error: .success, attempts: 1)
    }, arrayQuery: { _, result in
        recoverNativeArray(result, count: { ReadResult(value: NSNumber(value: 0), error: .success, attempts: 1) }, values: { _, _ in throwawayArrayPage() })
    }, scalarQuery: { _, original in original })
    let arrayQueries = array[name]?.recovery?["queries"] as? [[String: Any]]
    guard array[name]?.error == .success, (array[name]?.value as? [Any])?.isEmpty == true, arrayQueries?.count == 2,
          array[name]?.recovery?["selected_method"] as? String == "AXUIElementGetAttributeValueCount/AXUIElementCopyAttributeValues",
          (arrayQueries?[1]["initial_status"] as? [String: Any])?["code"] as? Int32 == AXError.cannotComplete.rawValue,
          (arrayQueries?[1]["initial_status"] as? [String: Any])?["native_read_recovery"] == nil else {
        throw EngineError.message("Composite native empty-array fallback fixture failed.")
    }
    let scalar = recoverNativeMetadataReads([name], initial: [name: original], batchQuery: { ReadResult(value: [kCFNull!] as CFArray, error: .success, attempts: 1) },
                                            arrayQuery: { _, result in recoverNativeArray(result, count: { ReadResult(value: nil, error: .illegalArgument, attempts: 1) }, values: { _, _ in throwawayArrayPage() }) }, scalarQuery: { _, original in original })
    let scalarQueries = scalar[name]?.recovery?["queries"] as? [[String: Any]]
    guard scalar[name]?.error == .cannotComplete, scalar[name]?.attempts == 3, scalar[name]?.value == nil,
          scalar[name]?.recovery?["resolved"] as? Bool == false, scalar[name]?.recovery?["selected_method"] is NSNull,
          (scalarQueries?[1]["count_before_status"] as? [String: Any])?["code"] as? Int32 == AXError.illegalArgument.rawValue else {
        throw EngineError.message("Composite scalar array-query rejection fixture failed.")
    }
    let pageFailed = recoverNativeMetadataReads([name], initial: [name: original], batchQuery: { ReadResult(value: nil, error: .failure, attempts: 1) },
                                                arrayQuery: { _, result in recoverNativeArray(result, count: { ReadResult(value: NSNumber(value: 1), error: .success, attempts: 1) }, values: { _, _ in ReadResult(value: nil, error: .cannotComplete, attempts: 3) }) }, scalarQuery: { _, original in original })
    let pageQueries = pageFailed[name]?.recovery?["queries"] as? [[String: Any]]
    let pages = pageQueries?[1]["pages"] as? [[String: Any]]
    guard pageFailed[name]?.error == .cannotComplete, pageFailed[name]?.value == nil,
          (pages?.first?["status"] as? [String: Any])?["code"] as? Int32 == AXError.cannotComplete.rawValue else {
        throw EngineError.message("Composite native page failure evidence fixture failed.")
    }
    let unsupported = ReadResult<CFTypeRef>(value: nil, error: .attributeUnsupported, attempts: 1)
    let recoveredUnsupported = recoverNativeMetadataReads([name], initial: [name: unsupported], batchQuery: { ReadResult(value: nil, error: .failure, attempts: 1) },
                                                          arrayQuery: { _, result in recoverNativeArray(result, count: { ReadResult(value: NSNumber(value: 0), error: .success, attempts: 1) }, values: { _, _ in throwawayArrayPage() }) }, scalarQuery: { _, original in original })
    guard recoveredUnsupported[name]?.error == .success,
          (recoveredUnsupported[name]?.recovery?["initial_status"] as? [String: Any])?["code"] as? Int32 == AXError.attributeUnsupported.rawValue else {
        throw EngineError.message("Advertised unsupported-attribute native array recovery fixture failed.")
    }
    return 5
}

func nativeActionNamesRecoverySelfTest() throws -> Int {
    let initial = ReadResult<CFArray>(value: nil, error: .failure, attempts: 1)
    var fixtures = 0
    for names in [[], ["AXPress"]] {
        var calls = 0
        let result = recoverNativeActionNames(initial, query: { calls += 1; return ReadResult(value: names as CFArray, error: .success, attempts: 1) })
        guard calls == 1, result.error == .success, result.value as? [String] == names,
              result.recovery?["resolved"] as? Bool == true, result.recovery?["names_valid"] as? Bool == true,
              result.recovery?["returned_count"] as? Int == names.count else {
            throw EngineError.message("Native action-name genuine string-array recovery fixture failed.")
        }
        fixtures += 1
    }
    for query: ReadResult<CFArray> in [ReadResult(value: nil, error: .failure, attempts: 1),
                                     ReadResult(value: nil, error: .success, attempts: 1),
                                     ReadResult(value: ["AXPress", NSNumber(value: 0)] as CFArray, error: .success, attempts: 1),
                                     ReadResult(value: ["AXPress"] as CFArray, error: .attributeUnsupported, attempts: 1)] {
        let result = recoverNativeActionNames(initial, query: { query })
        guard result.error == .failure, result.value == nil, result.recovery?["resolved"] as? Bool == false else {
            throw EngineError.message("Native action-name failed/malformed recovery fixture failed.")
        }
        fixtures += 1
    }
    for untouched: ReadResult<CFArray> in [ReadResult(value: nil, error: .cannotComplete, attempts: 3),
                                         ReadResult(value: [] as CFArray, error: .success, attempts: 1)] {
        var calls = 0
        let result = recoverNativeActionNames(untouched, query: { calls += 1; return ReadResult(value: nil, error: .failure, attempts: 1) })
        guard calls == 0, result.error == untouched.error, result.recovery == nil else {
            throw EngineError.message("Native action-name non-failure query exclusion fixture failed.")
        }
        fixtures += 1
    }
    let presentFailure = ReadResult<CFArray>(value: ["AXPress"] as CFArray, error: .failure, attempts: 1)
    let stillFailed = recoverNativeActionNames(presentFailure, query: { ReadResult(value: nil, error: .failure, attempts: 1) })
    guard stillFailed.error == .failure, stillFailed.value as? [String] == ["AXPress"],
          nativeActionNamesForExport(stillFailed) == nil,
          stillFailed.recovery?["initial_has_array"] as? Bool == true,
          stillFailed.recovery?["initial_returned_count"] as? Int == 1 else {
        throw EngineError.message("Failed native action-name arrays were advertised or their returned evidence was discarded.")
    }
    fixtures += 1
    return fixtures
}

func nativeArrayRecoverySelfTest() throws -> Int {
    let original = ReadResult<CFTypeRef>(value: nil, error: .failure, attempts: 1)
    var pageCalls = 0
    let empty = recoverNativeArray(original, count: { ReadResult(value: NSNumber(value: 0), error: .success, attempts: 1) },
                                   values: { _, _ in pageCalls += 1; return ReadResult(value: nil, error: .failure, attempts: 1) })
    guard empty.error == .success, (empty.value as? [Any])?.isEmpty == true, pageCalls == 0,
          (empty.recovery?["initial_status"] as? [String: Any])?["code"] as? Int32 == AXError.failure.rawValue else {
        throw EngineError.message("Native array empty-count recovery fixture failed.")
    }
    let failedCount = recoverNativeArray(original, count: { ReadResult(value: nil, error: .failure, attempts: 1) },
                                         values: { _, _ in throwawayArrayPage() })
    guard failedCount.error == .failure, failedCount.value == nil, failedCount.recovery?["resolved"] as? Bool == false else {
        throw EngineError.message("Failed native count was incorrectly recovered.")
    }
    let full = (0..<600).map { NSNumber(value: $0) }
    let paged = recoverNativeArray(original, count: { ReadResult(value: NSNumber(value: 600), error: .success, attempts: 1) },
                                  values: { start, count in ReadResult(value: Array(full[start..<(start + count)]) as CFArray, error: .success, attempts: 1) })
    guard paged.error == .success, (paged.value as? [NSNumber]) == full,
          (paged.recovery?["pages"] as? [[String: Any]])?.count == 3 else { throw EngineError.message("Native array paging fixture failed.") }
    let short = recoverNativeArray(original, count: { ReadResult(value: NSNumber(value: 2), error: .success, attempts: 1) },
                                  values: { _, _ in ReadResult(value: [NSNumber(value: 1)] as CFArray, error: .success, attempts: 1) })
    let shortPages = short.recovery?["pages"] as? [[String: Any]]
    guard short.error == .failure, short.value == nil,
          shortPages?.first?["has_value"] as? Bool == true,
          shortPages?.first?["returned_count"] as? Int == 1 else {
        throw EngineError.message("Short native page was incorrectly accepted or its length was not retained.")
    }
    var countCalls = 0
    let changing = recoverNativeArray(original, count: { countCalls += 1; return ReadResult(value: NSNumber(value: countCalls == 1 ? 0 : 1), error: .success, attempts: 1) },
                                     values: { _, _ in throwawayArrayPage() })
    guard changing.error == .failure, changing.value == nil else { throw EngineError.message("Changing native count was incorrectly accepted.") }
    let invalid = ReadResult<CFTypeRef>(value: nil, error: .invalidUIElement, attempts: 1)
    var unexpectedCalls = 0
    let invalidResult = recoverNativeArray(invalid, count: { unexpectedCalls += 1; return ReadResult(value: NSNumber(value: 0), error: .success, attempts: 1) },
                                          values: { _, _ in throwawayArrayPage() })
    guard invalidResult.error == .invalidUIElement, unexpectedCalls == 0 else { throw EngineError.message("Invalid native handle was treated as an empty array.") }
    let pageError = recoverNativeArray(original, count: { ReadResult(value: NSNumber(value: 1), error: .success, attempts: 1) },
                                      values: { _, _ in ReadResult(value: nil, error: .cannotComplete, attempts: 3) })
    let failedPages = pageError.recovery?["pages"] as? [[String: Any]]
    guard pageError.error == .failure, pageError.value == nil,
          failedPages?.first?["has_value"] as? Bool == false,
          failedPages?.first?["returned_count"] is NSNull else {
        throw EngineError.message("Failed native page was incorrectly accepted or its absent value was not retained.")
    }
    let present = ReadResult<CFTypeRef>(value: [] as CFArray, error: .success, attempts: 1)
    let untouched = recoverNativeArray(present, count: { unexpectedCalls += 1; return ReadResult(value: nil, error: .failure, attempts: 1) },
                                      values: { _, _ in throwawayArrayPage() })
    guard untouched.error == .success, untouched.recovery == nil, unexpectedCalls == 0 else { throw EngineError.message("Successful array read was unnecessarily recovered.") }
    return 8
}

private func throwawayArrayPage() -> ReadResult<CFArray> {
    ReadResult(value: nil, error: .failure, attempts: 1)
}

struct HierarchyReadOutcome {
    let resolved: Bool
    let reason: String?
}

func hierarchyReadOutcome(name: String, advertised: Bool, error: AXError, hasValue: Bool,
                          validValue: Bool, unresolvedReference: Bool) -> HierarchyReadOutcome {
    // AXError.noValue explicitly means that the requested value or element does
    // not exist. Keep its raw status, but do not conflate absence with a timeout.
    if error == .noValue { return HierarchyReadOutcome(resolved: true, reason: nil) }
    if name == "AXChildren", !advertised, error == .attributeUnsupported {
        return HierarchyReadOutcome(resolved: true, reason: nil)
    }
    guard error == .success else { return HierarchyReadOutcome(resolved: false, reason: "Hierarchy read did not succeed.") }
    guard hasValue else { return HierarchyReadOutcome(resolved: false, reason: "Success returned no value; hierarchy completeness is unknown.") }
    guard validValue && !unresolvedReference else {
        return HierarchyReadOutcome(resolved: false, reason: "Malformed hierarchy value or unresolved element reference.")
    }
    return HierarchyReadOutcome(resolved: true, reason: nil)
}

func classifyLeaf(namesResolved: Bool, hierarchyResolved: Bool, childCount: Int) -> String {
    guard namesResolved && hierarchyResolved else { return "unknown" }
    return childCount == 0 ? "leaf" : "branch"
}

final class ElementRegistry {
    var elements: [AXUIElement] = []
    var buckets: [CFHashCode: [Int]] = [:]
    var paths: [[[String: Any]]] = []
    func register(_ element: AXUIElement, path: [[String: Any]]) -> Int {
        let hash = CFHash(element)
        for index in buckets[hash] ?? [] where CFEqual(elements[index], element) { return index }
        let index = elements.count
        elements.append(element)
        paths.append(path)
        buckets[hash, default: []].append(index)
        return index
    }
}

struct AppIdentity {
    let application: NSRunningApplication
    var json: [String: Any] {
        ["name": application.localizedName ?? "", "bundle_id": application.bundleIdentifier ?? "",
         "pid": Int(application.processIdentifier), "bundle_path": application.bundleURL?.path ?? "",
         "executable_path": application.executableURL?.path ?? "",
         "launch_date": application.launchDate.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"]
    }
    var studyLock: Bool {
        [application.bundleIdentifier, application.localizedName, application.bundleURL?.path, application.executableURL?.path]
            .compactMap { $0 }.contains { $0.lowercased().contains("studylock") }
    }
}

func resolveApp(_ query: String) throws -> AppIdentity {
    let lowered = query.lowercased()
    let matches = NSWorkspace.shared.runningApplications.filter {
        !$0.isTerminated && (($0.bundleIdentifier ?? "").lowercased() == lowered || ($0.localizedName ?? "").lowercased() == lowered)
    }
    guard matches.count == 1, let app = matches.first else {
        throw EngineError.message(matches.isEmpty ? "The requested application is not running. No application was launched." : "Application name is ambiguous. Specify its exact bundle identifier.")
    }
    let identity = AppIdentity(application: app)
    return identity
}

final class Capture {
    let identity: AppIdentity
    let label: String
    let started = now()
    let root: AXUIElement
    let registry = ElementRegistry()
    var elements: [AXUIElement] { registry.elements }
    var paths: [[[String: Any]]] { registry.paths }
    var elementPIDs: [pid_t] = []
    var allowedProcesses: [pid_t: AppIdentity] = [:]
    var nodes: [[String: Any]] = []
    var allEdges: [[String: Any]] = []
    var hierarchyFailures: [[String: Any]] = []
    var metadataFailures: [[String: Any]] = []
    var nativeReadRecoveryAttempts = 0
    var nativeReadRecoverySuccesses = 0
    var nativeReadRecoveryValueSuccesses = 0
    var nativeReadRecoveryAbsenceSuccesses = 0
    var nativeScalarRetainedReferenceAttempts = 0
    var nativeScalarRetainedReferenceWithheld = 0
    var nativeScalarRetainedReferenceValueSuccesses = 0
    var nativeScalarRetainedReferenceAbsenceSuccesses = 0
    var absentValues: [[String: Any]] = []
    var cutoffs: [[String: Any]] = []
    var sourceNode = 0
    var sourceAttribute = ""
    var currentReferences: [Int] = []
    var attributeUnresolvedReference = false

    init(identity: AppIdentity, label: String) throws {
        self.identity = identity
        self.label = label
        guard AXIsProcessTrusted() else {
            throw EngineError.message("Accessibility permission is absent for this process. No permission prompt was requested.")
        }
        root = AXUIElementCreateApplication(identity.application.processIdentifier)
        let result = AXUIElementSetMessagingTimeout(root, messagingTimeout)
        guard result == .success else { throw EngineError.message("Cannot set the accessibility request timeout: \(errorName(result)) (\(result.rawValue)).") }
        allowedProcesses[identity.application.processIdentifier] = identity
        _ = register(root, path: [], pid: identity.application.processIdentifier)
    }

    func register(_ element: AXUIElement, path: [[String: Any]], pid: pid_t) -> Int {
        let index = registry.register(element, path: path)
        if nodes.count < registry.elements.count { nodes.append([:]); elementPIDs.append(pid) }
        return index
    }

    func allowedProcess(_ pid: pid_t) -> Bool {
        if let recorded = allowedProcesses[pid] {
            guard let fresh = NSRunningApplication(processIdentifier: pid), !fresh.isTerminated else { return false }
            let current = AppIdentity(application: fresh)
            return (
                current.application.processIdentifier == recorded.application.processIdentifier &&
                current.application.bundleIdentifier == recorded.application.bundleIdentifier &&
                current.application.executableURL == recorded.application.executableURL &&
                current.application.launchDate != nil &&
                current.application.launchDate == recorded.application.launchDate
            )
        }
        // Follow a running external process only when encountered through a
        // native element reference. Keep its launch identity for later checks;
        // do not enumerate other applications as extra extraction roots.
        guard let application = NSRunningApplication(processIdentifier: pid), !application.isTerminated else { return false }
        let candidate = AppIdentity(application: application)

        let helperRoot = AXUIElementCreateApplication(pid)
        guard AXUIElementSetMessagingTimeout(helperRoot, messagingTimeout) == .success else { return false }
        allowedProcesses[pid] = candidate
        return true
    }

    func failure(_ id: Int, _ name: String, _ stage: String, _ status: [String: Any], _ reason: String? = nil, hierarchy: Bool = false) {
        var item: [String: Any] = ["node": id, "attribute": name, "stage": stage, "status": status]
        if let reason { item["reason"] = reason }
        if hierarchy { hierarchyFailures.append(item) } else { metadataFailures.append(item) }
    }

    func refreshedScalarOwner(_ id: Int) -> NativeScalarRefreshResult {
        refreshNativeScalarTarget(selectorPath: paths[id], rootPID: identity.application.processIdentifier,
                                  expectedPID: elementPIDs[id], recordedAtPath: { prefix in
            guard let index = self.paths.firstIndex(where: { canonical($0) == canonical(prefix) }) else { return nil }
            return (element: self.elements[index], pid: self.elementPIDs[index])
        }, processMatches: { self.allowedProcess($0) }, createRoot: {
            AXUIElementCreateApplication(self.identity.application.processIdentifier)
        }, setTimeout: { AXUIElementSetMessagingTimeout($0, messagingTimeout) }, readAttribute: { element, name in
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return ReadResult(value: value, error: error, attempts: 1)
        }, elementPID: { element in
            var pid: pid_t = 0
            let error = AXUIElementGetPid(element, &pid)
            return ReadResult(value: error == .success ? NSNumber(value: pid) : nil, error: error, attempts: 1)
        })
    }

    func retainedScalarOwner(_ id: Int, role: String?, roleStatus: [String: Any],
                             queryElement: AXUIElement? = nil) -> NativeScalarRefreshResult {
        validateRetainedNativeScalarTarget(nodeID: id, rootID: 0, rootPID: identity.application.processIdentifier,
                                          expectedPID: elementPIDs[id], ownerRole: role, ownerRoleStatus: roleStatus,
                                          retainedOwner: queryElement ?? elements[id], recordedAtID: { index in
            guard self.elements.indices.contains(index) else { return nil }
            return (element: self.elements[index], pid: self.elementPIDs[index])
        }, processMatches: { self.allowedProcess($0) }, elementPID: { element in
            var pid: pid_t = 0
            let error = AXUIElementGetPid(element, &pid)
            return ReadResult(value: error == .success ? NSNumber(value: pid) : nil, error: error, attempts: 1)
        })
    }

    func encode(_ value: Any, valuePath: [Any] = []) -> Any {
        let cf = value as CFTypeRef
        let type = CFGetTypeID(cf)
        if type == AXUIElementGetTypeID() {
            let element = cf as! AXUIElement
            var pid: pid_t = 0
            let status = AXUIElementGetPid(element, &pid)
            var edge: [String: Any] = ["from": sourceNode, "attribute": sourceAttribute, "value_path": valuePath,
                                       "relationship": hierarchyNames.contains(sourceAttribute) ? "hierarchy" : "reference"]
            if status != .success {
                attributeUnresolvedReference = true
                edge["to"] = NSNull(); edge["resolution"] = "pid_read_failed"
                edge["status"] = ["code": status.rawValue, "name": errorName(status)]
                cutoffs.append(edge)
                allEdges.append(edge)
                return ["type": "AXUIElement", "id": NSNull(), "resolution": "pid_read_failed"]
            }
            guard allowedProcess(pid) else {
                attributeUnresolvedReference = true
                edge["to"] = NSNull(); edge["external_pid"] = Int(pid); edge["resolution"] = "outside_selected_process"
                // References whose process identity cannot be checked remain
                // explicit cutoffs rather than fabricated resolved elements.
                cutoffs.append(edge)
                allEdges.append(edge)
                return ["type": "AXUIElement", "id": NSNull(), "external_pid": Int(pid), "resolution": "outside_selected_process"]
            }
            let nextPath = paths[sourceNode] + [["attribute": sourceAttribute, "value_path": valuePath]]
            let id = register(element, path: nextPath, pid: pid)
            currentReferences.append(id)
            edge["to"] = id; edge["resolution"] = "visited"
            allEdges.append(edge)
            return ["type": "AXUIElement", "id": id]
        }
        if type == AXValueGetTypeID() {
            let ax = cf as! AXValue
            switch AXValueGetType(ax) {
            case .cgPoint:
                var point = CGPoint.zero
                if AXValueGetValue(ax, .cgPoint, &point) { return ["type": "CGPoint", "x": finite(point.x), "y": finite(point.y)] }
            case .cgSize:
                var size = CGSize.zero
                if AXValueGetValue(ax, .cgSize, &size) { return ["type": "CGSize", "width": finite(size.width), "height": finite(size.height)] }
            case .cgRect:
                var rect = CGRect.zero
                if AXValueGetValue(ax, .cgRect, &rect) { return ["type": "CGRect", "x": finite(rect.origin.x), "y": finite(rect.origin.y), "width": finite(rect.width), "height": finite(rect.height)] }
            case .cfRange:
                var range = CFRange(location: 0, length: 0)
                if AXValueGetValue(ax, .cfRange, &range) { return ["type": "CFRange", "location": range.location, "length": range.length] }
            case .axError:
                var error = AXError.success
                if AXValueGetValue(ax, .axError, &error) { return ["type": "AXError", "code": error.rawValue, "name": errorName(error)] }
            default: break
            }
            failure(sourceNode, sourceAttribute, "serialization", ["code": 0, "name": "success"], "Unreadable or unrecognized AXValue type.")
            return ["type": "opaque_AXValue", "ax_value_type": AXValueGetType(ax).rawValue]
        }
        if let marker = NativeTextCodec.encode(cf, type: type, warning: { reason in
            self.failure(self.sourceNode, self.sourceAttribute, "serialization", ["code": 0, "name": "success"], reason)
        }) { return marker }
        if let graphics = NativeGraphicsCodec.encode(cf, type: type, warning: { reason in
            self.failure(self.sourceNode, self.sourceAttribute, "serialization", ["code": 0, "name": "success"], reason)
        }) { return graphics }
        if type == CFAttributedStringGetTypeID() {
            let attributed = cf as! CFAttributedString
            let length = CFAttributedStringGetLength(attributed)
            var runs: [[String: Any]] = []
            var index = 0
            while index < length {
                var effective = CFRange(location: 0, length: 0)
                let attributes = CFAttributedStringGetAttributes(attributed, index, &effective)
                let encoded: Any
                if let attributes { encoded = encode(attributes, valuePath: valuePath + ["runs", runs.count, "attributes"]) }
                else {
                    encoded = NSNull()
                    failure(sourceNode, sourceAttribute, "serialization", ["code": 0, "name": "success"], "Attributed string run returned no attributes dictionary.")
                }
                runs.append(["range": ["location": effective.location, "length": effective.length], "attributes": encoded])
                guard effective.length > 0 else {
                    failure(sourceNode, sourceAttribute, "serialization", ["code": 0, "name": "success"], "Attributed string contained a non-advancing range.")
                    break
                }
                index = effective.location + effective.length
            }
            return ["type": "CFAttributedString", "string": CFAttributedStringGetString(attributed) as String, "runs": runs]
        }
        if let array = value as? [Any] { return array.enumerated().map { encode($0.element, valuePath: valuePath + [$0.offset]) } }
        if let dictionary = value as? [String: Any] {
            var result: [String: Any] = [:]
            for key in dictionary.keys.sorted() { result[key] = encode(dictionary[key]!, valuePath: valuePath + [key]) }
            return result
        }
        if type == CFDictionaryGetTypeID() {
            let dictionary = cf as! CFDictionary
            let count = CFDictionaryGetCount(dictionary)
            var keys = [UnsafeRawPointer?](repeating: nil, count: count)
            var values = [UnsafeRawPointer?](repeating: nil, count: count)
            keys.withUnsafeMutableBufferPointer { keyBuffer in
                values.withUnsafeMutableBufferPointer { valueBuffer in
                    CFDictionaryGetKeysAndValues(dictionary, keyBuffer.baseAddress, valueBuffer.baseAddress)
                }
            }
            var entries: [[String: Any]] = []
            for index in 0..<count {
                guard let keyPointer = keys[index], let valuePointer = values[index] else { continue }
                let keyObject = Unmanaged<AnyObject>.fromOpaque(keyPointer).takeUnretainedValue()
                let valueObject = Unmanaged<AnyObject>.fromOpaque(valuePointer).takeUnretainedValue()
                entries.append(["key": encode(keyObject, valuePath: valuePath + ["entries", index, "key"]),
                                "value": encode(valueObject, valuePath: valuePath + ["entries", index, "value"])])
            }
            return ["type": "CFDictionary", "entries": entries]
        }
        if let text = value as? String { return text }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
            return number.doubleValue.isFinite ? number : ["type": "nonfinite_number", "value": number.stringValue]
        }
        if let data = value as? Data { return ["type": "data", "base64": data.base64EncodedString()] }
        if let url = value as? URL { return ["type": "URL", "value": url.absoluteString] }
        if let date = value as? Date { return ["type": "Date", "value": ISO8601DateFormatter().string(from: date)] }
        if let attributed = value as? NSAttributedString {
            var runs: [[String: Any]] = []
            attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attributes, range, _ in
                var encoded: [String: Any] = [:]
                for key in attributes.keys.sorted(by: { $0.rawValue < $1.rawValue }) { encoded[key.rawValue] = self.encode(attributes[key]!, valuePath: valuePath + ["runs", runs.count, key.rawValue]) }
                runs.append(["range": ["location": range.location, "length": range.length], "attributes": encoded])
            }
            return ["type": "NSAttributedString", "string": attributed.string, "runs": runs]
        }
        if value is NSNull { return NSNull() }
        failure(sourceNode, sourceAttribute, "serialization", ["code": 0, "name": "success"], "Opaque native value was retained as a type marker; contents cannot be serialized by this engine.")
        return ["type": "opaque_native_value", "cf_type_id": Int(type)]
    }

    func finite(_ value: CGFloat) -> Any { value.isFinite ? Double(value) : ["type": "nonfinite_number", "value": String(describing: value)] }

    func hierarchyValueIsValid(_ value: CFTypeRef, name: String) -> Bool {
        if CFGetTypeID(value) == AXUIElementGetTypeID() { return !arrayHierarchyNames.contains(name) }
        guard let items = value as? [Any] else { return false }
        return items.allSatisfy { CFGetTypeID($0 as CFTypeRef) == AXUIElementGetTypeID() }
    }

    func run() throws -> [String: Any] {
        var cursor = 0
        while cursor < elements.count {
            guard !identity.application.isTerminated else { throw EngineError.message("The selected application exited during extraction. No complete snapshot was written.") }
            let element = elements[cursor]
            sourceNode = cursor
            guard allowedProcess(elementPIDs[cursor]) else {
                throw EngineError.message("A selected application or native-referenced process exited or changed process identity during extraction.")
            }
            let namesRead: ReadResult<CFArray> = read { AXUIElementCopyAttributeNames(element, &$0) }
            let names = namesRead.value as? [String]
            if cursor == 0 && (namesRead.error != .success || names == nil) {
                throw EngineError.message("Application-root attribute enumeration failed: \(errorName(namesRead.error)) (\(namesRead.error.rawValue)); no complete snapshot was written.")
            }
            var node: [String: Any] = ["id": cursor, "pid": Int(elementPIDs[cursor]),
                                      "process_identity": allowedProcesses[elementPIDs[cursor]]!.json,
                                      "selector_path": paths[cursor], "first_depth": paths[cursor].count,
                                      "attribute_names_status": namesRead.status]
            var unknownHierarchy = namesRead.error != .success || names == nil
            if unknownHierarchy { failure(cursor, "attribute_names", "enumeration", namesRead.status, "Hierarchy names are unresolved.", hierarchy: true) }
            let advertised = Set(names ?? [])
            node["attribute_names"] = advertised.sorted()
            var attributes: [String: Any] = [:]
            var statuses: [String: Any] = [:]
            var nativeReadRecoveries: [String: Any] = [:]
            var hierarchy: [String: [Int]] = [:]
            let orderedNames = advertised.union(["AXChildren"]).sorted()
            var reads: [String: ReadResult<CFTypeRef>] = [:]
            for name in orderedNames { reads[name] = attribute(element, name) }
            let recoveryNames = advertised.sorted().filter {
                !hierarchyNames.contains($0) && reads[$0].map { nativeMetadataRecoveryEligible($0.error) } == true
            }
            if !recoveryNames.isEmpty {
                let recovered = recoverNativeMetadataReads(recoveryNames, initial: reads, batchQuery: {
                    // One options=0 batch per node. Do not retry the batch or
                    // request already-read hierarchy attributes a second time.
                    var values: CFArray?
                    let error = AXUIElementCopyMultipleAttributeValues(element, recoveryNames as CFArray,
                                                                      AXCopyMultipleAttributeOptions(rawValue: 0), &values)
                    return ReadResult(value: values, error: error, attempts: 1)
                }, arrayQuery: { name, original in
                    recoverNativeArray(original, count: {
                        read { value in
                            var count: CFIndex = 0
                            let error = AXUIElementGetAttributeValueCount(element, name as CFString, &count)
                            if error == .success { value = NSNumber(value: count) }
                            return error
                        }
                    }, values: { index, limit in
                        read { AXUIElementCopyAttributeValues(element, name as CFString, index, limit, &$0) }
                    })
                }, scalarQuery: { name, original in
                    let roleRead = reads["AXRole"]
                    let role = roleRead?.error == .success ? roleRead?.value as? String : nil
                    let roleStatus = roleRead?.status ?? [:]
                    let retained: (() -> NativeScalarRefreshResult)? = role == "AXMenu" || role == "AXMenuItem" ? {
                        self.retainedScalarOwner(cursor, role: role, roleStatus: roleStatus)
                    } : nil
                    return recoverNativeScalar(name, original, refresh: { self.refreshedScalarOwner(cursor) }, query: { queryElement in
                        var value: CFTypeRef?
                        let error = AXUIElementCopyAttributeValue(queryElement, name as CFString, &value)
                        return ReadResult(value: value, error: error, attempts: 1)
                    }, queryIdentityMatches: {
                        self.allowedProcess(self.identity.application.processIdentifier) && self.allowedProcess(self.elementPIDs[cursor])
                    }, retainedTarget: retained, retainedQueryValidation: { queryElement in
                        self.retainedScalarOwner(cursor, role: role, roleStatus: roleStatus, queryElement: queryElement)
                    })
                })
                reads.merge(recovered) { _, recovered in recovered }
            }
            for name in orderedNames {
                sourceAttribute = name
                currentReferences = []
                attributeUnresolvedReference = false
                let result = reads[name]!
                statuses[name] = result.status
                if let recovery = result.recovery {
                    nativeReadRecoveries[name] = recovery
                    nativeReadRecoveryAttempts += 1
                    for query in recovery["queries"] as? [[String: Any]] ?? [] where query["method"] as? String == "native_scalar_recovery" {
                        if query["query_target"] as? String == "retained_original_reference", query["query_status"] is [String: Any] {
                            nativeScalarRetainedReferenceAttempts += 1
                            if query["resolved"] as? Bool == true {
                                if query["resolution_kind"] as? String == "absence" { nativeScalarRetainedReferenceAbsenceSuccesses += 1 }
                                else if query["resolution_kind"] as? String == "value" { nativeScalarRetainedReferenceValueSuccesses += 1 }
                            }
                        } else if query["retained_reference"] is [String: Any], query["query_status"] is NSNull {
                            nativeScalarRetainedReferenceWithheld += 1
                        }
                    }
                    if recovery["resolved"] as? Bool == true {
                        nativeReadRecoverySuccesses += 1
                        if recovery["resolution_kind"] as? String == "absence" { nativeReadRecoveryAbsenceSuccesses += 1 }
                        else { nativeReadRecoveryValueSuccesses += 1 }
                    }
                }
                if result.error == .noValue {
                    absentValues.append(["node": cursor, "attribute": name, "status": result.status])
                }
                let isHierarchy = hierarchyNames.contains(name)
                if result.error == .success, let value = result.value {
                    attributes[name] = encode(value)
                    if isHierarchy {
                        hierarchy[name] = Array(Set(currentReferences)).sorted()
                        let outcome = hierarchyReadOutcome(name: name, advertised: advertised.contains(name), error: result.error,
                                                           hasValue: true, validValue: hierarchyValueIsValid(value, name: name),
                                                           unresolvedReference: attributeUnresolvedReference)
                        if !outcome.resolved {
                            unknownHierarchy = true
                            failure(cursor, name, "hierarchy_read", result.status, outcome.reason, hierarchy: true)
                        }
                    }
                } else if isHierarchy {
                    let outcome = hierarchyReadOutcome(name: name, advertised: advertised.contains(name), error: result.error,
                                                       hasValue: false, validValue: false, unresolvedReference: false)
                    if !outcome.resolved {
                        unknownHierarchy = true
                        failure(cursor, name, "hierarchy_read", result.status, outcome.reason, hierarchy: true)
                    }
                } else if result.error != .noValue && (advertised.contains(name) || result.error != .attributeUnsupported) {
                    failure(cursor, name, "attribute_read", result.status, result.error == .success ? "Success returned no value." : nil)
                }
            }
            let initialActionsRead: ReadResult<CFArray> = read { AXUIElementCopyActionNames(element, &$0) }
            let actionsRead = recoverNativeActionNames(initialActionsRead, query: {
                // A single fresh native query, not another retry loop.
                var names: CFArray?
                let error = AXUIElementCopyActionNames(element, &names)
                return ReadResult(value: names, error: error, attempts: 1)
            })
            if let recovery = actionsRead.recovery {
                nativeReadRecoveries["action_names"] = recovery
                nativeReadRecoveryAttempts += 1
                if recovery["resolved"] as? Bool == true {
                    nativeReadRecoverySuccesses += 1
                    if recovery["resolution_kind"] as? String == "absence" { nativeReadRecoveryAbsenceSuccesses += 1 }
                    else { nativeReadRecoveryValueSuccesses += 1 }
                }
            }
            let actions = nativeActionNamesForExport(actionsRead)
            if actionsRead.error != .success && actionsRead.error != .actionUnsupported {
                failure(cursor, "action_names", "enumeration", actionsRead.status)
            } else if actionsRead.error == .success && actions == nil {
                failure(cursor, "action_names", "enumeration", actionsRead.status, "Success returned malformed action names.")
            }
            let parameterizedRead: ReadResult<CFArray> = read { AXUIElementCopyParameterizedAttributeNames(element, &$0) }
            let parameterized = parameterizedRead.value as? [String]
            if parameterizedRead.error != .success && parameterizedRead.error != .parameterizedAttributeUnsupported {
                failure(cursor, "parameterized_attribute_names", "enumeration", parameterizedRead.status)
            } else if parameterizedRead.error == .success && parameterized == nil {
                failure(cursor, "parameterized_attribute_names", "enumeration", parameterizedRead.status, "Success returned malformed parameterized names.")
            }
            node["attributes"] = attributes
            node["attribute_statuses"] = statuses
            node["native_read_recoveries"] = nativeReadRecoveries
            node["hierarchy"] = hierarchy
            node["action_names"] = (actions ?? []).sorted()
            node["action_names_status"] = actionsRead.status
            node["parameterized_attribute_names"] = (parameterized ?? []).sorted()
            node["parameterized_attribute_names_status"] = parameterizedRead.status
            node["parameterized_values_evaluated"] = false
            let hierarchyCount = Set(hierarchy.values.flatMap { $0 }).count
            let leafStatus = classifyLeaf(namesResolved: namesRead.error == .success && names != nil,
                                          hierarchyResolved: !unknownHierarchy, childCount: hierarchyCount)
            node["leaf_status"] = leafStatus
            node["hierarchy_leaf"] = unknownHierarchy ? NSNull() : hierarchyCount == 0
            node["hierarchy_child_count"] = hierarchyCount
            node["signature"] = signature(node)
            nodes[cursor] = node
            cursor += 1
        }
        var roleCounts: [String: Int] = [:]
        for node in nodes {
            let attrs = node["attributes"] as? [String: Any] ?? [:]
            roleCounts[attrs["AXRole"] as? String ?? "unknown", default: 0] += 1
        }
        let leaves = nodes.filter { $0["leaf_status"] as? String == "leaf" }
        let unknown = nodes.filter { $0["leaf_status"] as? String == "unknown" }
        let normalized = normalizedGraph()
        let graphDigest = sha256(try jsonData(normalized))
        let semanticDigest = sha256(try jsonData(semanticGraph(normalized)))
        let leafRecords = leaves.map { ["selector_path": $0["selector_path"]!, "signature": $0["signature"]!] }
        let leafDigest = sha256(try jsonData(leafRecords.sorted { canonical($0) < canonical($1) }))
        return ["schema_version": schemaVersion, "app": identity.json, "bundle": identity.application.bundleIdentifier ?? "",
                "pid": Int(identity.application.processIdentifier), "label": label, "started_at": started, "finished_at": now(),
                "trusted_process": true, "root_id": 0, "node_count": nodes.count, "leaf_count": leaves.count,
                "unknown_leaf_count": unknown.count, "leaf_ids": leaves.map { $0["id"]! },
                "unknown_leaf_ids": unknown.map { $0["id"]! }, "role_counts": roleCounts,
                "maximum_depth": paths.map { $0.count }.max() ?? 0, "nodes": nodes,
                "all_reference_edges": allEdges, "hierarchy_failures": hierarchyFailures, "metadata_failures": metadataFailures,
                "metadata_classification_version": 2,
                "scalar_recovery_version": 3,
                "native_metadata_failure_summary": nativeMetadataFailureSummary(metadataFailures),
                "metadata_read_failures": metadataFailures.filter { $0["stage"] as? String != "serialization" },
                "serialization_warnings": metadataFailures.filter { $0["stage"] as? String == "serialization" },
                "native_read_recovery_attempts": nativeReadRecoveryAttempts,
                "native_read_recovery_successes": nativeReadRecoverySuccesses,
                "native_read_recovery_outcome_version": 2,
                "native_read_recovery_value_successes": nativeReadRecoveryValueSuccesses,
                "native_read_recovery_absence_successes": nativeReadRecoveryAbsenceSuccesses,
                "native_scalar_retained_reference_attempts": nativeScalarRetainedReferenceAttempts,
                "native_scalar_retained_reference_withheld": nativeScalarRetainedReferenceWithheld,
                "native_scalar_retained_reference_value_successes": nativeScalarRetainedReferenceValueSuccesses,
                "native_scalar_retained_reference_absence_successes": nativeScalarRetainedReferenceAbsenceSuccesses,
                "absent_attribute_values": absentValues,
                "cutoffs": cutoffs, "scope": scope(), "graph_digest": graphDigest, "leaf_fingerprint": leafDigest,
                "semantic_graph_digest": semanticDigest,
                "process_identities": allowedProcesses.keys.sorted().map { allowedProcesses[$0]!.json },
                "digest_algorithm": "SHA-256", "digest_scope": "Normalized recorded graph, excluding timestamps, PID, retry counts, and application launch identity.",
                "semantic_digest_scope": "Same normalized graph, omitting only top-level native attribute values AXPosition and AXSize. All advertised names, read statuses, reference records/order and other values remain significant.",
                "leaf_fingerprint_scope": "Sorted first selector paths and identity/action signatures of confirmed containment leaves; leaf values and geometry remain in the graph digest.",
                "exposed_hierarchy_resolved": hierarchyFailures.isEmpty && cutoffs.isEmpty,
                "capture_consistency": "Sequential AX reads are not an atomic application snapshot. Use repeated verification to check observed stability."]
    }

    func scope() -> [String: Any] {
        ["native_only": true, "boundary": "Selected running application plus running processes reached through returned native element references, with recorded launch identity",
              "process_traversal_policy": "native_references_with_launch_identity",
              "hierarchy_attributes": hierarchyNames.sorted(), "references": "Every returned AXUIElement is followed when its running process identity can be checked; other applications are not enumerated as extraction roots",
         "parameterized_attributes": "Names are enumerated; parameter-dependent values are not exhaustively evaluated",
         "depth_limit": NSNull(), "node_limit": NSNull(), "request_timeout_seconds": messagingTimeout,
         "retry_limit": retryLimit, "retry_policy": "Retry only AXError.cannotComplete; maximum three attempts",
         "native_metadata_recovery": "Advertised non-hierarchy attributes returning failure/cannotComplete/attributeUnsupported may use one native options=0 bulk query per node. Actual native value slots resolve as values; a successfully decoded noValue error envelope in an exact successful bulk result confirms absence and ends recovery. Null, other error envelopes, failed outer queries and malformed results retain the original failure and slot evidence.",
         "native_read_recovery_outcomes": "Outcome version 2 distinguishes value, absence and unresolved. Confirmed absence has native noValue status, no exported attribute value, and an absent_attribute_values record; value and absence counts sum to total resolved recoveries.",
         "native_array_recovery": "Still-failed advertised non-hierarchy attributes may use native array count and paged reads, with matching counts before and after and exact page lengths. Original failure and every recovery query are retained; unsuccessful recovery keeps the original error.",
         "native_scalar_recovery": "Known scalar attributes AXGrowArea and AXTopLevelUIElement require native AXUIElement values, AXPosition/AXSize require native CGPoint/CGSize AXValues, and the observed native AXFrame shape is CGRect. These attributes never use array queries. Scalar recovery version 3 permits one direct read after unresolved bulk recovery for failure/cannotComplete/attributeUnsupported. The normal query target is the exact refreshed CFEqual selector reference. For AXTopLevelUIElement on a successfully captured native AXMenu/AXMenuItem, an isolated fresh prefix CFEqual mismatch may instead query the original retained capture-registry owner, with native root/owner PID and captured launch identity validated before and after. The failed fresh context remains recorded; a retained reference does not establish current tree membership. No changed prefix or matching label supplies the query target. Only correct native value types or explicit native noValue resolve; still-unsupported or other failed queries retain their original failures. No frame or control is derived or inferred.",
         "native_action_names_recovery": "An action-name enumeration returning failure may use one bounded fresh native query. Only a successful native string array resolves it; no actions are inferred from other attributes.",
         "native_graphics_serialization": "Native CGColor components, alpha, public color-space data, and ordered CGPath commands/control points are preserved using runtime type IDs. Binary64 bitstrings retain numeric representation; inaccessible pattern definitions or unknown models/commands remain explicit warnings.",
         "metadata_classification": "metadata_read_failures records native read or malformed-return failures; serialization_warnings records values read successfully but not fully encoded. metadata_failures remains their combined legacy array.",
         "transition_freshness": "Semantic graph equality excluding only AXPosition/AXSize values, plus selector/ancestor/sibling/process validation; selected-path geometry remains checked by native context guards",
         "transition_intent": "Requires an exact expected native title or identifier checked against recorded, fresh and immediate native identity",
         "excluded_transition_lifecycle_identifiers": excludedLifecycleIdentifiers.sorted(),
         "application_state_scope": "One observed state; undiscovered menus, documents, accounts and future states are outside this capture"]
    }

    func signature(_ node: [String: Any]) -> [String: Any] {
        let attrs = node["attributes"] as? [String: Any] ?? [:]
        var signature: [String: Any] = [:]
        for key in identityAttributes { if let value = attrs[key] { signature[key] = value } }
        signature["action_names"] = node["action_names"] ?? []
        return signature
    }

    func normalizedGraph() -> [String: Any] {
        let normalizedNodes = nodes.map { node -> [String: Any] in
            let statuses = node["attribute_statuses"] as? [String: [String: Any]] ?? [:]
            var statusCodes: [String: Any] = [:]
            for (key, status) in statuses { statusCodes[key] = status["code"] ?? NSNull() }
            let owner = node["process_identity"] as? [String: Any] ?? [:]
            return ["id": node["id"]!, "owner_bundle": owner["bundle_id"] ?? "", "owner_executable": owner["executable_path"] ?? "",
                    "selector_path": node["selector_path"]!, "attributes": node["attributes"]!,
                    "attribute_names": node["attribute_names"]!, "attribute_status_codes": statusCodes,
                    "attribute_names_status_code": (node["attribute_names_status"] as? [String: Any])?["code"] ?? NSNull(),
                    "action_names": node["action_names"]!, "action_names_status_code": (node["action_names_status"] as? [String: Any])?["code"] ?? NSNull(),
                    "parameterized_attribute_names": node["parameterized_attribute_names"]!,
                    "parameterized_names_status_code": (node["parameterized_attribute_names_status"] as? [String: Any])?["code"] ?? NSNull(),
                    "hierarchy": node["hierarchy"]!, "leaf_status": node["leaf_status"]!]
        }
        return ["bundle": identity.application.bundleIdentifier ?? "", "nodes": normalizedNodes,
                "reference_edges": allEdges.map { edge -> [String: Any] in
                    var result = edge; result.removeValue(forKey: "external_pid"); return result
                }]
    }
}

func writeJSON(_ object: Any, to url: URL) throws { try jsonData(object, pretty: true).write(to: url, options: .atomic) }
func loadJSON(_ url: URL) throws -> [String: Any] {
    guard let dictionary = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
        throw EngineError.message("Expected a JSON object at the specified snapshot path.")
    }
    return dictionary
}

func preflightOutputIdentity(_ directory: URL, appIdentity: [String: Any]) throws {
    for file in ["snapshot.json", "coverage.json", "stategraph.json", "transition.json"] {
        let url = directory.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        let document = try loadJSON(url)
        let recordedIdentity = (file == "stategraph.json" || file == "transition.json") ? document["app_identity"] : document["app"]
        guard document["schema_version"] as? String == schemaVersion,
              canonical(recordedIdentity ?? [:]) == canonical(appIdentity) else {
            throw EngineError.message("Output directory contains \(file) with an incompatible schema or application identity. Existing files were preserved; use a new directory.")
        }
        if file == "stategraph.json" {
            guard document["states"] is [[String: Any]], document["transitions"] is [[String: Any]] else {
                throw EngineError.message("Output state graph has a malformed states/transitions schema. Existing files were preserved.")
            }
        }
    }
}

func persist(_ snapshot: [String: Any], to directory: URL) throws {
    guard let appIdentity = snapshot["app"] as? [String: Any] else { throw EngineError.message("Snapshot is missing application identity.") }
    try preflightOutputIdentity(directory, appIdentity: appIdentity)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // Verification belongs to a specific observation sequence, never to an
    // output folder forever. Invalidate it before replacing any snapshot,
    // including after a native transition or a single-pass capture.
    let verification = directory.appendingPathComponent("verification.json")
    if FileManager.default.fileExists(atPath: verification.path) { try FileManager.default.removeItem(at: verification) }
    try writeJSON(snapshot, to: directory.appendingPathComponent("snapshot.json"))
    let nodes = snapshot["nodes"] as? [[String: Any]] ?? []
    var leafData = Data()
    for node in nodes where node["leaf_status"] as? String == "leaf" {
        leafData.append(try jsonData(node)); leafData.append(0x0a)
    }
    try leafData.write(to: directory.appendingPathComponent("leaves.ndjson"), options: .atomic)
    var coverage = snapshot
    coverage.removeValue(forKey: "nodes"); coverage.removeValue(forKey: "all_reference_edges")
    try writeJSON(coverage, to: directory.appendingPathComponent("coverage.json"))
}

func appendStateGraph(_ snapshots: [[String: Any]], transition: [String: Any]?, to directory: URL) throws {
    let url = directory.appendingPathComponent("stategraph.json")
    guard let appIdentity = snapshots.first?["app"] as? [String: Any],
          snapshots.allSatisfy({ canonical($0["app"] ?? [:]) == canonical(appIdentity) }) else {
        throw EngineError.message("State graph refused observations with inconsistent application identities.")
    }
    var graph: [String: Any] = ["schema_version": schemaVersion, "app_identity": appIdentity, "states": [], "transitions": [],
                               "scope": "Observed native accessibility states only; this graph does not establish all possible app states."]
    if FileManager.default.fileExists(atPath: url.path) {
        graph = try loadJSON(url)
        guard graph["schema_version"] as? String == schemaVersion,
              canonical(graph["app_identity"] ?? [:]) == canonical(appIdentity),
              graph["states"] is [[String: Any]], graph["transitions"] is [[String: Any]] else {
            throw EngineError.message("Existing state graph has an incompatible schema or application identity. Use a new output directory.")
        }
    }
    // The graph must retain the full tree for every observed state, rather than
    // pointing all state entries to the mutable latest snapshot.json file.
    var archives: [(snapshot: [String: Any], relativePath: String, url: URL, exists: Bool)] = []
    for snapshot in snapshots {
        guard let digest = snapshot["graph_digest"] as? String,
              digest.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw EngineError.message("Cannot archive a state without a valid SHA-256 graph digest.")
        }
        let relativePath = "states/\(digest)/snapshot.json"
        let archiveURL = directory.appendingPathComponent(relativePath)
        let exists = FileManager.default.fileExists(atPath: archiveURL.path)
        if exists {
            let existing = try loadJSON(archiveURL)
            guard existing["schema_version"] as? String == schemaVersion,
                  canonical(existing["app"] ?? [:]) == canonical(appIdentity),
                  existing["graph_digest"] as? String == digest,
                  existing["semantic_graph_digest"] as? String == snapshot["semantic_graph_digest"] as? String,
                  existing["node_count"] as? Int == snapshot["node_count"] as? Int,
                  existing["leaf_count"] as? Int == snapshot["leaf_count"] as? Int else {
                throw EngineError.message("An existing state archive has incompatible identity or digest metadata. It was preserved; use a new output directory.")
            }
        }
        archives.append((snapshot, relativePath, archiveURL, exists))
    }
    // Validate every destination before creating any archive file. Equal graph
    // observations preserve the first complete tree and update graph metadata.
    for archive in archives where !archive.exists && !FileManager.default.fileExists(atPath: archive.url.path) {
        try FileManager.default.createDirectory(at: archive.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeJSON(archive.snapshot, to: archive.url)
    }
    var states = graph["states"] as? [[String: Any]] ?? []
    for (index, snapshot) in snapshots.enumerated() {
        let digest = snapshot["graph_digest"] as? String ?? ""
        var entry: [String: Any] = ["graph_digest": digest, "leaf_fingerprint": snapshot["leaf_fingerprint"]!,
                                   "semantic_graph_digest": snapshot["semantic_graph_digest"] ?? NSNull(),
                                   "snapshot_path": archives[index].relativePath,
                                   "label": snapshot["label"]!, "node_count": snapshot["node_count"]!, "leaf_count": snapshot["leaf_count"]!,
                                   "unknown_leaf_count": snapshot["unknown_leaf_count"]!, "last_seen": snapshot["finished_at"]!]
        if let existing = states.firstIndex(where: { $0["graph_digest"] as? String == digest }) {
            entry["observations"] = (states[existing]["observations"] as? Int ?? 1) + 1
            states[existing] = entry
        } else { entry["observations"] = 1; states.append(entry) }
    }
    var transitions = graph["transitions"] as? [[String: Any]] ?? []
    if let transition { transitions.append(transition) }
    graph["states"] = states; graph["transitions"] = transitions; graph["updated_at"] = now()
    try writeJSON(graph, to: url)
}

struct FreshCaptureSequenceResult {
    let completedSnapshots: [[String: Any]]
    let latestSnapshot: [String: Any]?
    let recovery: [String: Any]
    let failureDescription: String?
}

func invalidHierarchyReferenceCounts(_ snapshot: [String: Any]) -> (references: Int, failures: Int) {
    let failures = (snapshot["hierarchy_failures"] as? [[String: Any]] ?? []).filter {
        ((($0["status"] as? [String: Any])?["code"]) as? NSNumber)?.intValue == Int(AXError.invalidUIElement.rawValue)
    }
    let nodeIDs = Set(failures.compactMap { $0["node"] as? Int })
    let unidentified = failures.filter { $0["node"] as? Int == nil }.count
    return (nodeIDs.count + unidentified, failures.count)
}

// The callbacks make the sequence policy independently testable without an AX
// server. Production creates a completely new Capture (and registry) each time.
// A failed later attempt has no current snapshot: prior graphs remain evidence,
// never a silently substituted "best" result. No nodes or references are merged.
func freshCaptureSequence(maxAttempts: Int, expectedIdentity: [String: Any],
                          currentIdentity: () throws -> [String: Any],
                          capture: (Int) throws -> [String: Any],
                          archive: ([String: Any]) throws -> Void) throws -> FreshCaptureSequenceResult {
    guard (1...3).contains(maxAttempts) else { throw EngineError.message("Capture attempts must be between one and three.") }
    var completed: [[String: Any]] = []
    var records: [[String: Any]] = []
    var archivedCount = 0

    func finish(latest: [String: Any]?, reason: String, exhausted: Bool = false, error: String? = nil) -> FreshCaptureSequenceResult {
        var recovery: [String: Any] = [
            "attempts": records, "max_attempts": maxAttempts, "attempt_count": records.count,
            "completed_capture_count": completed.count, "archived_capture_count": archivedCount,
            "selected_attempt": latest == nil ? NSNull() : (records.last?["attempt"] ?? NSNull()),
            "stop_reason": reason, "budget_exhausted": exhausted, "succeeded": latest != nil,
            "retry_trigger": "AXError.invalidUIElement (-25202) in hierarchy failures",
            "identity_policy": "Selected application identity is checked before every fresh capture",
            "selection_policy": "Latest capture only; no merging of nodes, IDs, edges, or best-of selection",
            "invalid_reference_count_definition": "Distinct node IDs with invalidUIElement hierarchy failures, plus invalid hierarchy failures without a node ID"
        ]
        if let error { recovery["error"] = error }
        var output = latest
        output?["capture_recovery"] = recovery
        return FreshCaptureSequenceResult(completedSnapshots: completed, latestSnapshot: output,
                                          recovery: recovery, failureDescription: error)
    }

    for attempt in 1...maxAttempts {
        var record: [String: Any] = ["attempt": attempt, "status": "identity_check_pending", "graph_digest": NSNull(),
                                    "node_count": NSNull(), "unknown_leaf_count": NSNull(), "invalid_reference_count": NSNull(),
                                    "exposed_hierarchy_resolved": NSNull(), "started_at": now()]
        let observedIdentity: [String: Any]
        do { observedIdentity = try currentIdentity() }
        catch {
            record["status"] = "identity_check_failed"; record["error"] = String(describing: error); record["finished_at"] = now()
            records.append(record)
            return finish(latest: nil, reason: "identity_check_failed", error: "Application identity continuity could not be checked; prior captures remain archived.")
        }
        guard canonical(observedIdentity) == canonical(expectedIdentity) else {
            record["status"] = "app_identity_changed"; record["identity_continuity"] = false; record["finished_at"] = now()
            records.append(record)
            return finish(latest: nil, reason: "app_identity_changed", error: "Application identity changed before a fresh capture; prior captures remain archived.")
        }
        record["identity_continuity"] = true
        let snapshot: [String: Any]
        do { snapshot = try capture(attempt) }
        catch {
            record["status"] = "capture_failed"; record["error"] = String(describing: error); record["finished_at"] = now()
            records.append(record)
            return finish(latest: nil, reason: "fresh_capture_failed", error: "A fresh native capture failed: \(error). Completed prior captures remain archived and were not published as the latest result.")
        }
        guard canonical(snapshot["app"] ?? [:]) == canonical(expectedIdentity) else {
            record["status"] = "capture_identity_changed"; record["graph_digest"] = snapshot["graph_digest"] ?? NSNull()
            record["identity_continuity"] = false; record["finished_at"] = now()
            records.append(record)
            return finish(latest: nil, reason: "capture_identity_changed", error: "The completed capture did not retain the selected application identity; no current snapshot was published.")
        }
        let invalid = invalidHierarchyReferenceCounts(snapshot)
        record["status"] = "captured"
        record["graph_digest"] = snapshot["graph_digest"] ?? NSNull()
        record["semantic_graph_digest"] = snapshot["semantic_graph_digest"] ?? NSNull()
        record["node_count"] = snapshot["node_count"] ?? NSNull()
        record["leaf_count"] = snapshot["leaf_count"] ?? NSNull()
        record["unknown_leaf_count"] = snapshot["unknown_leaf_count"] ?? NSNull()
        record["invalid_reference_count"] = invalid.references
        record["invalid_hierarchy_failure_count"] = invalid.failures
        record["hierarchy_failure_count"] = (snapshot["hierarchy_failures"] as? [Any] ?? []).count
        record["metadata_read_failure_count"] = (snapshot["metadata_read_failures"] as? [Any] ?? []).count
        record["serialization_warning_count"] = (snapshot["serialization_warnings"] as? [Any] ?? []).count
        record["exposed_hierarchy_resolved"] = snapshot["exposed_hierarchy_resolved"] ?? false
        record["finished_at"] = now()
        completed.append(snapshot)
        do { try archive(snapshot); archivedCount += 1; record["archived"] = true }
        catch {
            record["status"] = "archive_failed"; record["archived"] = false; record["error"] = String(describing: error)
            records.append(record)
            return finish(latest: nil, reason: "archive_failed", error: "The completed native capture could not be archived; no current snapshot was published.")
        }
        records.append(record)
        if invalid.failures == 0 { return finish(latest: snapshot, reason: "no_retryable_invalid_hierarchy_references") }
        if attempt == maxAttempts { return finish(latest: snapshot, reason: "capture_attempt_budget_exhausted", exhausted: true) }
    }
    throw EngineError.message("Fresh capture sequence ended without an observation.")
}

func freshCaptureSequenceSelfTest() throws -> Int {
    let identity: [String: Any] = ["bundle_id": "fixture.app", "pid": 1, "launch_date": "fixture-launch"]
    func snapshot(_ name: String, invalid: Bool, ids: [Int]) -> [String: Any] {
        ["app": identity, "graph_digest": name, "node_count": ids.count, "unknown_leaf_count": invalid ? 1 : 0,
         "exposed_hierarchy_resolved": !invalid, "nodes": ids.map { ["id": $0] },
         "all_reference_edges": ids.dropFirst().map { ["from": ids[0], "to": $0] },
         "hierarchy_failures": invalid ? [["node": ids.last!, "status": ["code": Int(AXError.invalidUIElement.rawValue)]]] : []]
    }
    let stale = snapshot("stale", invalid: true, ids: [0, 16])
    let good = snapshot("good", invalid: false, ids: [0, 1, 2])
    var archived: [[String: Any]] = []
    var calls = 0
    let recovered = try freshCaptureSequence(maxAttempts: 3, expectedIdentity: identity, currentIdentity: { identity },
                                            capture: { index in calls += 1; return index == 1 ? stale : good }, archive: { archived.append($0) })
    guard calls == 2, archived.count == 2, recovered.latestSnapshot?["graph_digest"] as? String == "good",
          recovered.completedSnapshots.count == 2, recovered.recovery["selected_attempt"] as? Int == 2 else {
        throw EngineError.message("Fresh capture invalid-to-good recovery fixture failed.")
    }
    archived = []; calls = 0
    let exhausted = try freshCaptureSequence(maxAttempts: 3, expectedIdentity: identity, currentIdentity: { identity },
                                            capture: { index in calls += 1; return snapshot("stale-\(index)", invalid: true, ids: [0, index]) }, archive: { archived.append($0) })
    guard calls == 3, archived.count == 3, exhausted.recovery["budget_exhausted"] as? Bool == true,
          exhausted.latestSnapshot?["graph_digest"] as? String == "stale-3" else {
        throw EngineError.message("Fresh capture bounded exhaustion fixture failed.")
    }
    archived = []; calls = 0
    let unchanged = try freshCaptureSequence(maxAttempts: 3, expectedIdentity: identity, currentIdentity: { identity },
                                            capture: { _ in calls += 1; return good }, archive: { archived.append($0) })
    guard calls == 1, archived.count == 1, unchanged.completedSnapshots.count == 1 else {
        throw EngineError.message("Fresh capture non-invalid single-attempt fixture failed.")
    }
    guard let nodes = recovered.latestSnapshot?["nodes"] as? [[String: Any]],
          nodes.compactMap({ $0["id"] as? Int }) == [0, 1, 2],
          recovered.latestSnapshot?["node_count"] as? Int == 3,
          (recovered.latestSnapshot?["all_reference_edges"] as? [[String: Any]] ?? []).count == 2,
          (recovered.completedSnapshots[0]["nodes"] as? [[String: Any]] ?? []).compactMap({ $0["id"] as? Int }) == [0, 16] else {
        throw EngineError.message("Fresh capture graph identity/no-merge fixture failed.")
    }
    archived = []; calls = 0
    let failure = try freshCaptureSequence(maxAttempts: 3, expectedIdentity: identity, currentIdentity: { identity },
                                          capture: { index in calls += 1; if index == 2 { throw EngineError.message("fixture capture failure") }; return stale }, archive: { archived.append($0) })
    guard calls == 2, archived.count == 1, failure.latestSnapshot == nil, failure.completedSnapshots.count == 1,
          failure.recovery["stop_reason"] as? String == "fresh_capture_failed",
          (failure.recovery["attempts"] as? [[String: Any]] ?? []).count == 2 else {
        throw EngineError.message("Fresh capture failure evidence fixture failed.")
    }
    archived = []; calls = 0
    var identityChecks = 0
    let changed = try freshCaptureSequence(maxAttempts: 3, expectedIdentity: identity,
                                          currentIdentity: { identityChecks += 1; if identityChecks == 2 { return ["bundle_id": "fixture.app", "pid": 2] }; return identity },
                                          capture: { _ in calls += 1; return stale }, archive: { archived.append($0) })
    guard identityChecks == 2, calls == 1, archived.count == 1, changed.latestSnapshot == nil,
          changed.recovery["stop_reason"] as? String == "app_identity_changed" else {
        throw EngineError.message("Fresh capture application-identity continuity fixture failed.")
    }
    var nativeStatusFixture = stale
    let invalidRead = ReadResult<CFTypeRef>(value: nil, error: .invalidUIElement, attempts: 1)
    nativeStatusFixture["hierarchy_failures"] = [["node": 16, "status": invalidRead.status]]
    let nativeCounts = invalidHierarchyReferenceCounts(nativeStatusFixture)
    guard nativeCounts.references == 1, nativeCounts.failures == 1 else {
        throw EngineError.message("Fresh capture native AXError numeric representation fixture failed.")
    }
    return 7
}

struct Options {
    var command = "snapshot"
    var app = ""
    var output = ""
    var label = "current"
    var verify = 1
    var captureAttempts = 3
    var transitionFrom: String?
    var nodeID: Int?
    var action: String?
    var expectedTitle: String?
    var expectedIdentifier: String?
    var help = false
    var selfTest = false
    init() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        var index = 0
        if let first = arguments.first, ["snapshot", "transition"].contains(first) { command = first; index += 1 }
        while index < arguments.count {
            let key = arguments[index]
            if key == "--help" || key == "-h" { help = true; index += 1; continue }
            if key == "--self-test" { selfTest = true; index += 1; continue }
            if key == "--verify" && (index + 1 == arguments.count || arguments[index + 1].hasPrefix("--")) { verify = 2; index += 1; continue }
            guard index + 1 < arguments.count else { throw EngineError.message("Missing value for \(key).") }
            let value = arguments[index + 1]
            switch key {
            case "--app": app = value
            case "--output": output = value
            case "--label": label = value
            case "--verify":
                guard let count = Int(value), count >= 2 else { throw EngineError.message("--verify needs an integer of at least two.") }
                verify = count
            case "--capture-attempts":
                guard let count = Int(value), (1...3).contains(count) else { throw EngineError.message("--capture-attempts needs an integer between one and three.") }
                captureAttempts = count
            case "--transition-from": transitionFrom = value; command = "transition"
            case "--node":
                guard let parsed = Int(value), parsed >= 0 else { throw EngineError.message("--node needs a nonnegative snapshot-local node ID.") }
                nodeID = parsed
            case "--action": action = value
            case "--expect-title": expectedTitle = value
            case "--expect-identifier": expectedIdentifier = value
            default: throw EngineError.message("Unknown option \(key).")
            }
            index += 2
        }
    }
}

func printHelp() {
    print("""
    Native AX engine — read-only capture, or one explicitly selected native action
    Usage:
      native-ax-engine snapshot --app BUNDLE_ID_OR_EXACT_NAME --output DIRECTORY [--label TEXT] [--verify [COUNT]] [--capture-attempts 1..3]
      native-ax-engine transition --app BUNDLE_ID_OR_EXACT_NAME --output DIRECTORY --transition-from SNAPSHOT.json --node ID --action EXPOSED_AX_ACTION (--expect-title EXACT_NATIVE_TITLE | --expect-identifier EXACT_NATIVE_ID)
      native-ax-engine --self-test

    Only already-running applications are supported. No launch or permission prompt.
    StudyLock transitions are excluded.
    Native system lifecycle transitions (restart, shut down, logout, sleep,
    lock and force quit) are excluded, while their nodes remain in captures.
    Files can contain private application text and native values; keep output local.
    Leaf status is leaf, branch, or unknown. Repeated observations check stability,
    Each observation retries a whole fresh capture up to three times only for
    invalidUIElement hierarchy failures. Every completed attempt is archived;
    the latest graph is reported, with no merging or best-of selection.
    not coverage of hidden application states. Parameterized attribute names are
    listed; their arbitrary parameter domains are not exhaustively evaluated.
    """)
}

func nodesByPath(_ nodes: [[String: Any]]) -> [String: [String: Any]] {
    Dictionary(uniqueKeysWithValues: nodes.map { (canonical($0["selector_path"] ?? []), $0) })
}

func nodeContext(_ node: [String: Any]) -> [String: Any] {
    let attrs = node["attributes"] as? [String: Any] ?? [:]
    var context: [String: Any] = ["signature": node["signature"] ?? [:], "process_identity": node["process_identity"] ?? [:]]
    for key in ["AXEnabled", "AXValue", "AXPosition", "AXSize"] {
        if let value = attrs[key] { context[key] = value }
    }
    return context
}

func referenceContext(_ value: Any, nodesByID: [Int: [String: Any]]) -> Any {
    if let object = value as? [String: Any] {
        if object["type"] as? String == "AXUIElement", let id = object["id"] as? Int,
           let node = nodesByID[id] { return ["type": "AXUIElement_context", "context": nodeContext(node)] }
        var output: [String: Any] = [:]
        for key in object.keys.sorted() { output[key] = referenceContext(object[key]!, nodesByID: nodesByID) }
        return output
    }
    if let items = value as? [Any] { return items.map { referenceContext($0, nodesByID: nodesByID) } }
    return value
}

func validateSelectorContext(oldPath: [[String: Any]], oldNodes: [[String: Any]], freshNodes: [[String: Any]]) throws {
    let oldByPath = nodesByPath(oldNodes), freshByPath = nodesByPath(freshNodes)
    let oldByID = Dictionary(uniqueKeysWithValues: oldNodes.compactMap { node -> (Int, [String: Any])? in
        guard let id = node["id"] as? Int else { return nil }; return (id, node)
    })
    let freshByID = Dictionary(uniqueKeysWithValues: freshNodes.compactMap { node -> (Int, [String: Any])? in
        guard let id = node["id"] as? Int else { return nil }; return (id, node)
    })
    // Validate every ancestor's role/labels/actions, stable native value/geometry,
    // and the complete ordered sibling context for the relationship traversed.
    // An identical ID or a matching leaf title alone is never sufficient.
    for depth in 0...oldPath.count {
        let prefix = Array(oldPath.prefix(depth))
        let key = canonical(prefix)
        guard let previous = oldByPath[key], let current = freshByPath[key],
              canonical(nodeContext(previous)) == canonical(nodeContext(current)) else {
            throw EngineError.message("Transition refused: an ancestor's identity, value, or geometry changed.")
        }
        if depth < oldPath.count {
            guard let attributeName = oldPath[depth]["attribute"] as? String,
                  let oldAttributes = previous["attributes"] as? [String: Any],
                  let freshAttributes = current["attributes"] as? [String: Any],
                  let oldRelationship = oldAttributes[attributeName], let freshRelationship = freshAttributes[attributeName],
                  canonical(referenceContext(oldRelationship, nodesByID: oldByID)) == canonical(referenceContext(freshRelationship, nodesByID: freshByID)) else {
                throw EngineError.message("Transition refused: the selected relationship or ordered sibling identities changed.")
            }
        }
    }
    guard let target = oldByPath[canonical(oldPath)], let signature = target["signature"] as? [String: Any],
          ["AXIdentifier", "AXTitle", "AXDescription", "AXHelp"].contains(where: { !(signature[$0] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
        throw EngineError.message("Transition refused: the selected control lacks a meaningful native identifier or label.")
    }
}

func runTransition(_ options: Options, identity: AppIdentity, output: URL) throws {
    guard !identity.studyLock else { throw EngineError.message("Native actions on StudyLock are excluded; read-only snapshots remain available.") }
    guard let from = options.transitionFrom, let requestedNode = options.nodeID, let action = options.action else {
        throw EngineError.message("A transition requires --transition-from, --node, and --action.")
    }
    guard options.expectedTitle != nil || options.expectedIdentifier != nil else {
        throw EngineError.message("A transition requires --expect-title or --expect-identifier; no action was performed.")
    }
    let old = try loadJSON(URL(fileURLWithPath: from))
    guard old["schema_version"] as? String == schemaVersion,
          let oldApp = old["app"] as? [String: Any],
          canonical(oldApp) == canonical(identity.json),
          let oldNodes = old["nodes"] as? [[String: Any]],
          let oldNode = oldNodes.first(where: { $0["id"] as? Int == requestedNode }),
          let oldPath = oldNode["selector_path"] as? [[String: Any]],
          let oldSignature = oldNode["signature"] as? [String: Any],
          (oldNode["action_names"] as? [String] ?? []).contains(action) else {
        throw EngineError.message("Transition refused: snapshot application identity, selector, signature, or advertised action is invalid or stale.")
    }
    try validateTransitionExpectation(oldSignature, expectedTitle: options.expectedTitle, expectedIdentifier: options.expectedIdentifier)
    let beforeCapture = try Capture(identity: identity, label: options.label + "-before")
    let before = try beforeCapture.run()
    guard let oldSemantic = old["semantic_graph_digest"] as? String, !oldSemantic.isEmpty,
          oldSemantic == before["semantic_graph_digest"] as? String,
          old["exposed_hierarchy_resolved"] as? Bool == true,
          before["exposed_hierarchy_resolved"] as? Bool == true else {
        throw EngineError.message("Transition refused: the complete semantic graph changed, its digest is missing, or hierarchy branches are unresolved. Capture the current state again; no action was performed.")
    }
    try persist(before, to: output.appendingPathComponent("before"))
    // The output graph was preflighted before capture. Do not register this
    // observation twice; the final transition write records before and after.
    try validateSelectorContext(oldPath: oldPath, oldNodes: oldNodes, freshNodes: beforeCapture.nodes)
    let matches = beforeCapture.nodes.filter {
        canonical($0["selector_path"] ?? []) == canonical(oldPath) && canonical($0["signature"] ?? [:]) == canonical(oldSignature)
    }
    guard matches.count == 1, let freshNode = matches.first, let freshID = freshNode["id"] as? Int,
          (freshNode["action_names"] as? [String] ?? []).contains(action) else {
        throw EngineError.message("Transition refused: the fresh native selector and signature do not uniquely match the recorded node. The before snapshot was saved; no action was performed.")
    }
    try validateTransitionExpectation(freshNode["signature"] as? [String: Any] ?? [:], expectedTitle: options.expectedTitle, expectedIdentifier: options.expectedIdentifier)
    guard !identity.application.isTerminated, canonical(identity.json) == canonical(oldApp) else {
        throw EngineError.message("Application process or launch identity changed. No action was performed.")
    }
    // Re-read identity and action support immediately before execution. The
    // selected control may still disappear asynchronously; AX returns that error.
    let element = beforeCapture.elements[freshID]
    let owningPID = beforeCapture.elementPIDs[freshID]
    guard beforeCapture.allowedProcess(owningPID) else {
        throw EngineError.message("Transition refused: the native control's owning process changed launch identity.")
    }
    var immediatePID: pid_t = 0
    guard AXUIElementGetPid(element, &immediatePID) == .success, immediatePID == owningPID else {
        throw EngineError.message("Transition refused: the native control's owning process cannot be validated.")
    }
    var finalSignature: [String: Any] = [:]
    for key in identityAttributes {
        let result = attribute(element, key)
        if result.error == .success, let value = result.value {
            if let text = value as? String { finalSignature[key] = text }
            else { throw EngineError.message("Transition refused: non-text identity field cannot be validated.") }
        } else if result.error != .attributeUnsupported && result.error != .noValue {
            throw EngineError.message("Transition refused: identity validation returned \(errorName(result.error)).")
        }
    }
    let currentActions: ReadResult<CFArray> = read { AXUIElementCopyActionNames(element, &$0) }
    guard currentActions.error == .success, let actions = currentActions.value as? [String], actions.contains(action) else {
        throw EngineError.message("Transition refused: the selected action is no longer advertised.")
    }
    finalSignature["action_names"] = actions.sorted()
    try validateTransitionExpectation(finalSignature, expectedTitle: options.expectedTitle, expectedIdentifier: options.expectedIdentifier)
    guard canonical(finalSignature) == canonical(oldSignature) else { throw EngineError.message("Transition refused: selected control identity changed immediately before execution.") }
    var transition: [String: Any] = ["schema_version": schemaVersion, "timestamp": now(), "phase": "prepared", "from": before["graph_digest"]!,
                                   "app_identity": identity.json,
                                   "recorded_source_digest": old["graph_digest"] ?? NSNull(), "source_node": requestedNode,
                                   "recorded_source_semantic_digest": oldSemantic,
                                   "before_semantic_digest": before["semantic_graph_digest"]!,
                                   "fresh_node": freshID, "selector_path": oldPath, "signature": oldSignature,
                                   "action": action, "to": NSNull(), "action_status": ["name": "outcome_not_recorded", "attempts": NSNull()],
                                   "expected_title": options.expectedTitle ?? NSNull(),
                                   "expected_identifier": options.expectedIdentifier ?? NSNull(),
                                   "prepared_journal_uncertainty": "An interruption after execution but before the outcome write may leave this prepared journal. It does not prove that the action was not attempted. Never retry automatically.",
                                   "automatic_retry_allowed": false,
                                   "completion_semantics": "AX success acknowledges the action; it does not prove task completion or application settling."]
    // Commit the intent before mutating the app. If the process stops after this
    // write, the journal makes the ambiguous action outcome visible on disk.
    try writeJSON(transition, to: output.appendingPathComponent("transition.json"))
    // Mutating actions are deliberately never retried: a timeout may mean the
    // app executed the action even though the acknowledgement was lost.
    let result = AXUIElementPerformAction(element, action as CFString)
    transition["phase"] = "action_attempted"
    transition["action_attempted_at"] = now()
    transition["action_status"] = ["code": result.rawValue, "name": errorName(result), "attempts": 1]
    do { try writeJSON(transition, to: output.appendingPathComponent("transition.json")) }
    catch { throw EngineError.message("The native action was attempted, but its outcome journal could not be saved. The prepared journal may remain; inspect it before retrying.") }
    do {
        let afterCapture = try Capture(identity: identity, label: options.label + "-after")
        let after = try afterCapture.run()
        try persist(after, to: output.appendingPathComponent("after"))
        try persist(after, to: output)
        transition["to"] = after["graph_digest"]!
        transition["after_semantic_digest"] = after["semantic_graph_digest"]!
        transition["changed"] = before["graph_digest"] as? String != after["graph_digest"] as? String
        transition["semantic_changed"] = before["semantic_graph_digest"] as? String != after["semantic_graph_digest"] as? String
        transition["phase"] = "after_capture_recorded"
        try writeJSON(transition, to: output.appendingPathComponent("transition.json"))
        try appendStateGraph([before, after], transition: transition, to: output)
        print(canonical(["action_status": errorName(result), "action_status_code": result.rawValue,
                         "before_nodes": before["node_count"]!, "after_nodes": after["node_count"]!,
                         "after_leaves": after["leaf_count"]!, "output": output.path]))
        if result != .success { exit(3) }
    } catch {
        transition["to"] = NSNull(); transition["after_capture_error"] = String(describing: error)
        try writeJSON(transition, to: output.appendingPathComponent("transition.json"))
        try appendStateGraph([before], transition: transition, to: output)
        throw EngineError.message("The native action was attempted and recorded, but the after capture failed. Inspect transition.json before retrying.")
    }
}

do {
    let options = try Options()
    if options.help { printHelp(); exit(0) }
    if options.selfTest {
        let vectors = [("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
                       ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")]
        guard vectors.allSatisfy({ sha256(Data($0.0.utf8)) == $0.1 }) else { throw EngineError.message("SHA-256 self-test failed.") }
        let fixtureInputs: [(String, Bool, AXError, Bool, Bool, Bool, Bool, Int, String)] = [
            ("AXChildren", true, .success, true, true, false, true, 0, "leaf"),
            ("AXChildren", true, .success, true, true, false, true, 2, "branch"),
            ("AXChildren", false, .attributeUnsupported, false, false, false, true, 0, "leaf"),
            ("AXChildren", true, .attributeUnsupported, false, false, false, true, 0, "unknown"),
            ("AXChildren", true, .cannotComplete, false, false, false, true, 0, "unknown"),
            ("AXChildren", true, .success, false, false, false, true, 0, "unknown"),
            ("AXChildren", true, .success, true, false, false, true, 0, "unknown"),
            ("AXChildren", true, .success, true, true, true, true, 0, "unknown"),
            ("AXChildren", false, .attributeUnsupported, false, false, false, false, 0, "unknown"),
            ("AXRows", true, .noValue, false, false, false, true, 0, "leaf"),
            ("AXWindows", true, .invalidUIElement, false, false, false, true, 2, "unknown")
        ]
        for fixture in fixtureInputs {
            let outcome = hierarchyReadOutcome(name: fixture.0, advertised: fixture.1, error: fixture.2,
                                               hasValue: fixture.3, validValue: fixture.4, unresolvedReference: fixture.5)
            guard classifyLeaf(namesResolved: fixture.6, hierarchyResolved: outcome.resolved, childCount: fixture.7) == fixture.8 else {
                throw EngineError.message("Native hierarchy classification self-test failed.")
            }
        }
        let registry = ElementRegistry()
        let first = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let equalHandle = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let rootIndex = registry.register(first, path: [])
        let aliasIndex = registry.register(first, path: [["attribute": "AXParent", "value_path": []]])
        let equalIndex = registry.register(equalHandle, path: [["attribute": "AXOther", "value_path": []]])
        let distinct = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier + 1)
        let distinctIndex = registry.register(distinct, path: [["attribute": "AXOther", "value_path": [0]]])
        guard rootIndex == aliasIndex, rootIndex == equalIndex, distinctIndex != rootIndex, registry.elements.count == 2,
              registry.paths[rootIndex].isEmpty else { throw EngineError.message("Native reference alias/cycle deduplication self-test failed.") }
        var retryCalls = 0
        let retried: ReadResult<CFTypeRef> = read { _ in retryCalls += 1; return .cannotComplete }
        var terminalCalls = 0
        let terminal: ReadResult<CFTypeRef> = read { _ in terminalCalls += 1; return .attributeUnsupported }
        guard retryCalls == 3, retried.attempts == 3, terminalCalls == 1, terminal.attempts == 1 else {
            throw EngineError.message("Native read retry self-test failed.")
        }
        let digestFixture: [String: Any] = ["bundle": "fixture.app", "nodes": [
            ["id": 0, "attributes": ["AXRole": "AXButton", "AXTitle": "Delete", "AXValue": "record-a",
                                     "AXPosition": ["type": "CGPoint", "x": 1, "y": 2],
                                     "AXSize": ["type": "CGSize", "width": 20, "height": 30]],
             "action_names": ["AXPress"], "attribute_status_codes": ["AXPosition": 0, "AXSize": 0],
             "hierarchy": ["AXChildren": [1, 2]]]
        ], "reference_edges": [["from": 0, "to": 1, "attribute": "AXChildren", "value_path": [0]],
                                ["from": 0, "to": 2, "attribute": "AXChildren", "value_path": [1]]]]
        let expectedSemantic = sha256(try jsonData(semanticGraph(digestFixture)))
        func fixtureChangingAttributes(_ changes: [String: Any]) -> [String: Any] {
            var graph = digestFixture
            var nodes = graph["nodes"] as! [[String: Any]]
            var attributes = nodes[0]["attributes"] as! [String: Any]
            for (key, value) in changes { attributes[key] = value }
            nodes[0]["attributes"] = attributes
            graph["nodes"] = nodes
            return graph
        }
        let geometryChanged = fixtureChangingAttributes(["AXPosition": ["type": "CGPoint", "x": 600, "y": 900],
                                                        "AXSize": ["type": "CGSize", "width": 200, "height": 300]])
        guard sha256(try jsonData(semanticGraph(geometryChanged))) == expectedSemantic,
              sha256(try jsonData(geometryChanged)) != sha256(try jsonData(digestFixture)),
              sha256(try jsonData(semanticGraph(fixtureChangingAttributes(["AXTitle": "Restore"])))) != expectedSemantic,
              sha256(try jsonData(semanticGraph(fixtureChangingAttributes(["AXValue": "record-b"])))) != expectedSemantic else {
            throw EngineError.message("Semantic digest geometry/label/value self-test failed.")
        }
        var reordered = digestFixture
        reordered["reference_edges"] = Array((digestFixture["reference_edges"] as! [[String: Any]]).reversed())
        guard sha256(try jsonData(semanticGraph(reordered))) != expectedSemantic else {
            throw EngineError.message("Semantic digest reference-order self-test failed.")
        }
        func expectationIsAccepted(_ signature: [String: Any], title: String?, identifier: String?) -> Bool {
            do { try validateTransitionExpectation(signature, expectedTitle: title, expectedIdentifier: identifier); return true }
            catch { return false }
        }
        let basicSignature: [String: Any] = ["AXRole": "AXMenuItem", "AXTitle": "Basic", "AXIdentifier": "basicMode:"]
        guard expectationIsAccepted(basicSignature, title: "Basic", identifier: nil),
              expectationIsAccepted(basicSignature, title: nil, identifier: "basicMode:"),
              !expectationIsAccepted(basicSignature, title: "Scientific", identifier: nil),
              !expectationIsAccepted(basicSignature, title: nil, identifier: "otherMode:"),
              !expectationIsAccepted(basicSignature, title: nil, identifier: nil),
              !expectationIsAccepted(basicSignature, title: "", identifier: nil) else {
            throw EngineError.message("Explicit native transition intent self-test failed.")
        }
        for identifier in excludedLifecycleIdentifiers {
            let signature: [String: Any] = ["AXRole": "AXMenuItem", "AXTitle": "Lifecycle fixture", "AXIdentifier": identifier]
            guard !expectationIsAccepted(signature, title: "Lifecycle fixture", identifier: identifier) else {
                throw EngineError.message("System lifecycle transition exclusion self-test failed.")
            }
        }
        let nativeTextCodecFixtures = try NativeTextCodec.selfTest()
        let nativeGraphicsCodecFixtures = try NativeGraphicsCodec.selfTest()
        let nativeArrayRecoveryFixtures = try nativeArrayRecoverySelfTest()
        let nativeMetadataBatchFixtures = try nativeMetadataBatchRecoverySelfTest()
        let nativeMetadataCompositeFixtures = try nativeMetadataCompositeRecoverySelfTest()
        let nativeActionNamesFixtures = try nativeActionNamesRecoverySelfTest()
        let nativeAbsenceRecoveryFixtures = try nativeAbsenceRecoverySelfTest()
        let nativeScalarRecoveryFixtures = try nativeScalarRecoverySelfTest()
        let nativeScalarUnsupportedRetryFixtures = try nativeScalarUnsupportedRetrySelfTest()
        let nativeMenuReferenceRetryFixtures = try nativeMenuReferenceRetrySelfTest()
        let freshSequenceFixtures = try freshCaptureSequenceSelfTest()
        let existingFixtureCount = 2 + fixtureInputs.count + 4 + 2 + 4 + 6 + excludedLifecycleIdentifiers.count
        print(canonical(["sha256_test_vectors": 2, "hierarchy_leaf_fixtures": fixtureInputs.count,
                         "native_reference_identity_fixtures": 4, "retry_fixtures": 2,
                         "semantic_digest_fixtures": 4, "transition_intent_fixtures": 6,
                         "excluded_lifecycle_fixtures": excludedLifecycleIdentifiers.count,
                         "native_text_codec_fixtures": nativeTextCodecFixtures,
                         "native_graphics_codec_fixtures": nativeGraphicsCodecFixtures,
                         "native_array_recovery_fixtures": nativeArrayRecoveryFixtures,
                         "native_metadata_batch_fixtures": nativeMetadataBatchFixtures,
                         "native_metadata_composite_fixtures": nativeMetadataCompositeFixtures,
                         "native_action_names_recovery_fixtures": nativeActionNamesFixtures,
                         "native_absence_recovery_fixtures": nativeAbsenceRecoveryFixtures,
                         "native_scalar_recovery_fixtures": nativeScalarRecoveryFixtures,
                         "native_scalar_unsupported_retry_fixtures": nativeScalarUnsupportedRetryFixtures,
                         "native_menu_reference_retry_fixtures": nativeMenuReferenceRetryFixtures,
                         "fresh_capture_sequence_fixtures": freshSequenceFixtures,
                         "fixtures_total": existingFixtureCount + nativeTextCodecFixtures + nativeGraphicsCodecFixtures + nativeArrayRecoveryFixtures + nativeMetadataBatchFixtures + nativeMetadataCompositeFixtures + nativeActionNamesFixtures + nativeAbsenceRecoveryFixtures + nativeScalarRecoveryFixtures + nativeScalarUnsupportedRetryFixtures + nativeMenuReferenceRetryFixtures + freshSequenceFixtures,
                         "passed": true])); exit(0)
    }
    guard !options.app.isEmpty, !options.output.isEmpty else { throw EngineError.message("Specify --app and --output. Use --help for syntax.") }
    let identity = try resolveApp(options.app)
    let output = URL(fileURLWithPath: options.output, isDirectory: true)
    try preflightOutputIdentity(output, appIdentity: identity.json)
    if options.command == "snapshot", options.verify > 1 {
        for index in 0..<options.verify {
            try preflightOutputIdentity(output.appendingPathComponent(String(format: "observation-%03d", index + 1)), appIdentity: identity.json)
        }
    }
    if options.command == "transition" {
        try preflightOutputIdentity(output.appendingPathComponent("before"), appIdentity: identity.json)
        try preflightOutputIdentity(output.appendingPathComponent("after"), appIdentity: identity.json)
    }
    if options.command == "transition" {
        try runTransition(options, identity: identity, output: output)
    } else {
        var observations: [[String: Any]] = []
        var recoveryObservations: [[String: Any]] = []
        let expectedIdentity = identity.json
        let expectedLaunchDate = identity.application.launchDate
        for index in 0..<options.verify {
            let sequence = try freshCaptureSequence(maxAttempts: options.captureAttempts, expectedIdentity: expectedIdentity,
                                                    currentIdentity: {
                guard !identity.application.isTerminated,
                      let current = NSRunningApplication(processIdentifier: identity.application.processIdentifier), !current.isTerminated,
                      current.bundleIdentifier == identity.application.bundleIdentifier,
                      current.executableURL == identity.application.executableURL,
                      current.launchDate != nil, current.launchDate == expectedLaunchDate else {
                    throw EngineError.message("The selected application exited or changed process launch identity.")
                }
                return AppIdentity(application: current).json
            }, capture: { _ in
                let capture = try Capture(identity: identity, label: options.label)
                return try capture.run()
            }, archive: { snapshot in
                // Every completed attempt is recorded once, including stale
                // snapshots. Only this observation's latest graph is verified.
                try appendStateGraph([snapshot], transition: nil, to: output)
            })
            var recovery = sequence.recovery
            recovery["observation"] = index + 1
            recoveryObservations.append(recovery)
            guard let snapshot = sequence.latestSnapshot else {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try writeJSON(["schema_version": schemaVersion, "app_identity": expectedIdentity,
                               "capture_recovery_observations": recoveryObservations,
                               "latest_snapshot_published": false, "failed_observation": index + 1],
                              to: output.appendingPathComponent("capture-recovery.json"))
                throw EngineError.message(sequence.failureDescription ?? "Fresh capture recovery failed; completed attempts remain archived.")
            }
            observations.append(snapshot)
            if options.verify > 1 { try persist(snapshot, to: output.appendingPathComponent(String(format: "observation-%03d", index + 1))) }
        }
        let final = observations.last!
        try persist(final, to: output)
        try writeJSON(["schema_version": schemaVersion, "app_identity": expectedIdentity,
                       "capture_recovery_observations": recoveryObservations, "latest_snapshot_published": true],
                      to: output.appendingPathComponent("capture-recovery.json"))
        if options.verify > 1 {
            let graphs = observations.map { $0["graph_digest"] as! String }
            let leaves = observations.map { $0["leaf_fingerprint"] as! String }
            let semantics = observations.map { $0["semantic_graph_digest"] as! String }
            let verified: [String: Any] = ["observations": options.verify, "graph_digests": graphs,
                                          "leaf_fingerprints": leaves, "graph_stable": Set(graphs).count == 1,
                                          "leaf_set_stable": Set(leaves).count == 1,
                                          "semantic_graph_digests": semantics, "semantic_graph_stable": Set(semantics).count == 1,
                                          "capture_recovery_observations": recoveryObservations,
                                          "all_exposed_hierarchies_resolved": observations.allSatisfy { $0["exposed_hierarchy_resolved"] as? Bool == true },
                                          "scope": "Stability of sequential recorded native observations; no hidden-state coverage guarantee"]
            try writeJSON(verified, to: output.appendingPathComponent("verification.json"))
        }
        print(canonical(["node_count": final["node_count"]!, "leaf_count": final["leaf_count"]!,
                         "unknown_leaf_count": final["unknown_leaf_count"]!,
                         "hierarchy_failures": (final["hierarchy_failures"] as? [Any] ?? []).count,
                         "metadata_read_failures": (final["metadata_read_failures"] as? [Any] ?? []).count,
                         "serialization_warnings": (final["serialization_warnings"] as? [Any] ?? []).count,
                         "native_read_recovery_attempts": final["native_read_recovery_attempts"] ?? 0,
                         "native_read_recovery_successes": final["native_read_recovery_successes"] ?? 0,
                         "native_read_recovery_value_successes": final["native_read_recovery_value_successes"] ?? 0,
                         "native_read_recovery_absence_successes": final["native_read_recovery_absence_successes"] ?? 0,
                         "native_scalar_retained_reference_attempts": final["native_scalar_retained_reference_attempts"] ?? 0,
                         "native_scalar_retained_reference_withheld": final["native_scalar_retained_reference_withheld"] ?? 0,
                         "native_scalar_retained_reference_value_successes": final["native_scalar_retained_reference_value_successes"] ?? 0,
                         "native_scalar_retained_reference_absence_successes": final["native_scalar_retained_reference_absence_successes"] ?? 0,
                         "native_metadata_failure_summary": final["native_metadata_failure_summary"] ?? [:],
                         "invalid_reference_count": invalidHierarchyReferenceCounts(final).references,
                         "whole_capture_attempts": recoveryObservations.reduce(0) { $0 + ($1["completed_capture_count"] as? Int ?? 0) },
                         "cutoffs": (final["cutoffs"] as? [Any] ?? []).count,
                         "observations": options.verify, "output": output.path]))
    }
} catch {
    fputs("native-ax-engine: \(error)\n", stderr)
    exit(2)
}
