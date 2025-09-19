//
//  GraphValueTransformerRoundtripTests.swift
//  GraphCK
//
//  Created by Valerio Buriani on 19/09/25.
//

//
//  GraphValueTransformerRoundtripTests.swift
//  GraphCKTests
//
//  Created by ChatGPT on 19/09/25.
//

import XCTest
import UIKit
import PDFKit
@testable import GraphCK

final class GraphValueTransformerRoundtripTests: XCTestCase {

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
        if let pdfURL = Bundle.module.url(forResource: "sample", withExtension: "pdf"),
           let pdf = PDFDocument(url: pdfURL) {
            samples.append(pdf)
        } else {
            XCTFail("⚠️ Resource sample.pdf mancante in bundle test")
        }
        
        // UIImage sample
        if let img = UIImage(systemName: "star.fill") {
            samples.append(img)
        } else {
            XCTFail("⚠️ UIImage systemName star.fill non disponibile")
        }
        
        for sample in samples {
            do {
                let archived = try GraphArchiver.archive(sample)
                let unarchived = GraphValueTransformer().reverseTransformedValue(archived)
                
                print("🔁 Roundtrip type=\(type(of: sample)) → \(String(describing: type(of: unarchived)))")
                
                if let str = sample as? NSString {
                    XCTAssertEqual(str as String, unarchived as? String, "String mismatch")
                } else if let num = sample as? NSNumber {
                    XCTAssertEqual(num, unarchived as? NSNumber, "NSNumber mismatch")
                } else if sample is Date {
                    XCTAssertNotNil(unarchived as? Date, "Date roundtrip failed")
                } else if sample is Data {
                    XCTAssertNotNil(unarchived as? Data, "Data roundtrip failed")
                } else if sample is UIImage {
                    XCTAssertTrue(unarchived is Data || unarchived is UIImage, "UIImage roundtrip unexpected type")
                } else if sample is PDFDocument {
                    XCTAssertTrue(unarchived is Data || unarchived is PDFDocument, "PDF roundtrip unexpected type")
                } else if sample is NSNull {
                    XCTAssertTrue(unarchived is NSNull, "NSNull roundtrip failed")
                } else if let array = sample as? NSArray {
                    XCTAssertEqual(array.count, (unarchived as? NSArray)?.count, "NSArray roundtrip count mismatch")
                } else if let dict = sample as? NSDictionary {
                    XCTAssertEqual(dict.count, (unarchived as? NSDictionary)?.count, "NSDictionary roundtrip count mismatch")
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
                XCTFail("❌ Archiviazione fallita per \(type(of: sample)): \(error)")
            }
        }
    }
}
