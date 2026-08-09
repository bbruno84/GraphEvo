//
//  GraphValueTransformerRoundtripTests.swift
//  GraphEvo
//
//  Created by Valerio Buriani on 19/09/25.
//

//
//  GraphValueTransformerRoundtripTests.swift
//  GraphEvoTests
//
//  Created by ChatGPT on 19/09/25.
//

import XCTest
import PDFKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
@testable import GraphEvo

final class GraphValueTransformerRoundtripTests: XCTestCase {

    func testTransformerRejectsUnsupportedAndMalformedValues() {
        let transformer = GraphValueTransformer()

        XCTAssertThrowsError(try GraphArchiver.archive(UUID()))
        XCTAssertNil(transformer.transformedValue(Data([0x00, 0x01, 0x02])))
        XCTAssertNil(transformer.transformedValue("not archived data"))
        XCTAssertNil(transformer.reverseTransformedValue(nil))
        GraphValueTransformer.register()
        XCTAssertNotNil(ValueTransformer(forName: GraphValueTransformer.name))
    }

    func testRoundtrip() throws {
        var samples: [Any] = [
            "ciao" as NSString,
            42 as NSNumber,
            Date(),
            "abc".data(using: .utf8)! as NSData,
            NSNull(),
            NSArray(array: ["a", "b"]),
            NSDictionary(dictionary: ["k": "v"]),
            AnyCodableObject("test"),
            NSArrayOfAnyCodableObject([AnyCodableObject("a"), AnyCodableObject("b")]),
            DictionaryOfAnyCodableObject(["key1": AnyCodableObject("v1"), "key2": AnyCodableObject("v2")]),
            NSURL(string: "https://example.com/test")!
        ]
        
        // PDF sample
        if let pdfURL = Bundle.graphTests.url(forResource: "sample", withExtension: "pdf"),
           let pdf = PDFDocument(url: pdfURL) {
            samples.append(pdf)
        } else {
            XCTFail("Resource sample.pdf was not found in the test bundle")
        }
        
#if canImport(UIKit)
        if let image = UIImage(systemName: "star.fill") {
            samples.append(image)
        } else {
            XCTFail("UIImage systemName star.fill is unavailable")
        }
#elseif canImport(AppKit)
        if let image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil) {
            samples.append(image)
        } else {
            XCTFail("NSImage systemSymbolName star.fill is unavailable")
        }
#endif
        
        for sample in samples {
            do {
                let archived = try GraphArchiver.archive(sample)
                let unarchived = GraphValueTransformer().transformedValue(archived)
                
                print("🔁 Roundtrip type=\(type(of: sample)) → \(String(describing: type(of: unarchived)))")

#if canImport(UIKit)
                if let image = sample as? UIImage {
                    XCTAssertEqual(
                        unarchived as? Data,
                        image.pngData(),
                        "UIImage must round-trip to its PNG representation"
                    )
                    continue
                }
#elseif canImport(AppKit)
                if let image = sample as? NSImage {
                    XCTAssertEqual(
                        unarchived as? Data,
                        GraphImageSupport.pngData(from: image),
                        "NSImage must round-trip to its PNG representation"
                    )
                    continue
                }
#endif

                if let str = sample as? NSString {
                    XCTAssertEqual(str as String, unarchived as? String, "String mismatch")
                } else if let num = sample as? NSNumber {
                    XCTAssertEqual(num, unarchived as? NSNumber, "NSNumber mismatch")
                } else if let date = sample as? Date {
                    XCTAssertEqual(unarchived as? Date, date, "Date roundtrip failed")
                } else if let data = sample as? Data {
                    XCTAssertEqual(unarchived as? Data, data, "Data roundtrip failed")
                } else if let pdf = sample as? PDFDocument {
                    guard let data = unarchived as? Data,
                          let roundtrippedPDF = PDFDocument(data: data) else {
                        XCTFail("PDFDocument roundtrip did not produce readable PDF data")
                        continue
                    }
                    XCTAssertEqual(roundtrippedPDF.pageCount, pdf.pageCount)
                    for pageIndex in 0..<pdf.pageCount {
                        XCTAssertEqual(
                            roundtrippedPDF.page(at: pageIndex)?.string,
                            pdf.page(at: pageIndex)?.string,
                            "PDF page \(pageIndex) content mismatch"
                        )
                    }
                } else if sample is NSNull {
                    XCTAssertTrue(unarchived is NSNull, "NSNull roundtrip failed")
                } else if let array = sample as? NSArray {
                    XCTAssertEqual(array.count, (unarchived as? NSArray)?.count, "NSArray roundtrip count mismatch")
                    XCTAssertEqual(
                        array.compactMap { $0 as? String },
                        (unarchived as? NSArray)?.compactMap { $0 as? String },
                        "NSArray contents mismatch"
                    )
                } else if let dict = sample as? NSDictionary {
                    XCTAssertEqual(dict.count, (unarchived as? NSDictionary)?.count, "NSDictionary roundtrip count mismatch")
                    XCTAssertEqual(
                        dict as? [String: String],
                        unarchived as? [String: String],
                        "NSDictionary contents mismatch"
                    )
                } else if let obj = sample as? AnyCodableObject {
                    if let unarchivedObj = unarchived as? AnyCodableObject {
                        XCTAssertEqual(String(describing: obj.value),
                                       String(describing: unarchivedObj.value),
                                       "AnyCodableObject mismatch")
                    } else {
                        XCTFail("AnyCodableObject roundtrip failed")
                    }
                } else if let array = sample as? NSArrayOfAnyCodableObject {
                    guard let unarch = unarchived as? NSArrayOfAnyCodableObject else {
                        if unarchived == nil {
                            XCTFail("NSArrayOfAnyCodableObject roundtrip failed (nil)")
                        } else {
                            XCTFail("NSArrayOfAnyCodableObject roundtrip produced unsupported type \(String(describing: type(of: unarchived)))")
                        }
                        continue
                    }
                    for (origElem, unarchElem) in zip(array.items, unarch.items) {
                        XCTAssertEqual(String(describing: origElem.value), String(describing: unarchElem.value), "NSArrayOfAnyCodableObject element mismatch")
                    }
                } else if let dict = sample as? DictionaryOfAnyCodableObject {
                    guard let unarch = unarchived as? DictionaryOfAnyCodableObject else {
                        if unarchived == nil {
                            XCTFail("DictionaryOfAnyCodableObject roundtrip failed (nil)")
                        } else {
                            XCTFail("DictionaryOfAnyCodableObject roundtrip produced unsupported type \(String(describing: type(of: unarchived)))")
                        }
                        continue
                    }
                    for (key, origVal) in dict.items {
                        guard let unarchVal = unarch.items[key] else {
                            XCTFail("DictionaryOfAnyCodableObject missing key '\(key)' after roundtrip")
                            continue
                        }
                        XCTAssertEqual(String(describing: origVal.value), String(describing: unarchVal.value), "DictionaryOfAnyCodableObject value mismatch for key '\(key)'")
                    }
                } else if let url = sample as? NSURL {
                    XCTAssertEqual(url, unarchived as? NSURL, "NSURL roundtrip mismatch")
                } else {
                    XCTFail("Unsupported sample type: \(type(of: sample))")
                }
            } catch {
                XCTFail("❌ Archiving failed for \(type(of: sample)): \(error)")
            }
        }
    }
}
