//
//  GraphTools.swift
//  GraphEvo
//
//  Created by Valerio Buriani on 19/09/25.
//

import Foundation
import PDFKit

enum GraphTools {
    
    @discardableResult
    static func saveImageToDisk(_ image: Any, named name: String) -> URL? {
        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("ExportedImages", isDirectory: true)
        
        do {
            // Create the directory when it does not exist.
            if !FileManager.default.fileExists(atPath: exportDir.path) {
                try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
            }
            
            let fileURL = exportDir.appendingPathComponent("\(name).png")
            
            guard let data = GraphImageSupport.pngData(from: image) else {
                print("⚠️ Image could not be converted to PNG")
                return nil
            }
            
            // Save to disk.
            try data.write(to: fileURL)
            print("✅ Image saved: \(fileURL.path)")
            
            return fileURL
            
        } catch {
            print("❌ Image save error '\(name)': \(error)")
            return nil
        }
    }
    
    @discardableResult
    static func saveDocumentToDisk(_ document: PDFDocument, named name: String) -> URL? {
        let exportDir = FileManager.default.temporaryDirectory.appendingPathComponent("ExportedDocuments", isDirectory: true)
        
        do {
            // Create the directory when it does not exist.
            if !FileManager.default.fileExists(atPath: exportDir.path) {
                try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
            }
            
            // Genera il path
            let fileURL = exportDir.appendingPathComponent("\(name).pdf")
            
            guard let data = document.dataRepresentation() else {
                print("⚠️ PDF could not be converted to data")
                return nil
            }
            
            // Save to disk.
            try data.write(to: fileURL)
            print("✅ Document saved: \(fileURL.path)")
            
            return fileURL
            
        } catch {
            print("❌ PDF save error '\(name)': \(error)")
            return nil
        }
    }
    
    
    /// Shared helpers for scan functions (available in all builds)
    internal static func dataHexHeader(_ data: Data, count: Int) -> String {
        let prefix = data.prefix(count)
        return prefix.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    
    internal static func dataKind(for data: Data) -> String {
        if data.count >= 8 {
            let bytes = [UInt8](data.prefix(8))
            // PNG: 89 50 4E 47 0D 0A 1A 0A
            if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "PNG (raw)" }
            // PDF: 25 50 44 46
            if bytes.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "PDF (raw)" }
            // JPEG: FF D8
            if bytes.starts(with: [0xFF, 0xD8]) { return "JPEG (raw)" }
            // bplist00
            if bytes.starts(with: [0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x30, 0x30]) { return "NSKeyedArchive/Plist" }
        }
        return "Unknown"
    }
    
}
