import Foundation

#if os(Windows)
private let tarExecutablePath = "C:\\Windows\\System32\\tar.exe"
#else
private let tarExecutablePath = "/usr/bin/tar"
#endif

internal func unzip(url: URL, to destination: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw DocxFileError.fileNotFound(url)
    }
    
    // Ensure destination exists
    try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tarExecutablePath)
    process.arguments = ["-xf", url.path, "-C", destination.path]
    
    // Suppress output
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        // Fallback or error handling
        throw DocxFileError.unreadableArchive(url, error)
    }
    
    if process.terminationStatus != 0 {
        throw DocxFileError.unreadableArchive(url, nil)
    }
}
