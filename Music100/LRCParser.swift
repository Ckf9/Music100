import Foundation

class LRCParser {
    static func parse(payload: String) -> [LyricLine] {
        var lyrics: [LyricLine] = []
        let pattern = "\\[(\\d{2,}):(\\d{2}(?:\\.\\d+)?)\\]"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        
        let lines = payload.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            
            let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            let matches = regex.matches(in: trimmed, options: [], range: nsRange)
            
            if !matches.isEmpty {
                let text = regex.stringByReplacingMatches(in: trimmed, options: [], range: nsRange, withTemplate: "").trimmingCharacters(in: .whitespaces)
                
                var words: [LyricWord]? = nil
                let wordPattern = "<(\\d{2,}):(\\d{2}(?:\\.\\d+)?)>([^<]*)"
                if let wordRegex = try? NSRegularExpression(pattern: wordPattern, options: []) {
                    let wordMatches = wordRegex.matches(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text))
                    if !wordMatches.isEmpty {
                        var parsedWords = [LyricWord]()
                        for wMatch in wordMatches {
                            if wMatch.numberOfRanges == 4,
                               let mRange = Range(wMatch.range(at: 1), in: text),
                               let sRange = Range(wMatch.range(at: 2), in: text),
                               let tRange = Range(wMatch.range(at: 3), in: text) {
                                
                                let mStr = String(text[mRange])
                                let sStr = String(text[sRange])
                                let wText = String(text[tRange]).trimmingCharacters(in: .whitespaces)
                                
                                if let m = Double(mStr), let s = Double(sStr) {
                                    let wTimestamp = (m * 60.0) + s
                                    parsedWords.append(LyricWord(timestamp: wTimestamp, text: wText))
                                }
                            }
                        }
                        if !parsedWords.isEmpty {
                            words = parsedWords
                        }
                    }
                }
                
                let cleanText = text.replacingOccurrences(of: "<\\d{2,}:\\d{2}(?:\\.\\d+)?>", with: "", options: .regularExpression, range: nil).trimmingCharacters(in: .whitespaces)
                
                // Transliterate Hindi (Devanagari) to Hinglish (Latin) if detected
                let finalText = transliterateIfHindi(cleanText)
                
                // Also transliterate word-level lyrics if present
                if let w = words {
                    words = w.map { LyricWord(timestamp: $0.timestamp, text: transliterateIfHindi($0.text)) }
                }
                
                for match in matches {
                    if match.numberOfRanges == 3,
                       let mRange = Range(match.range(at: 1), in: trimmed),
                       let sRange = Range(match.range(at: 2), in: trimmed) {
                        
                        let mStr = String(trimmed[mRange])
                        let sStr = String(trimmed[sRange])
                        
                        if let m = Double(mStr), let s = Double(sStr) {
                            let timestamp = (m * 60.0) + s
                            lyrics.append(LyricLine(timestamp: timestamp, text: finalText, words: words))
                        }
                    }
                }
            }
        }
        
        return lyrics.sorted { $0.timestamp < $1.timestamp }
    }
    
    static func mockLyrics() -> [LyricLine] {
        return [
            LyricLine(timestamp: 0.0, text: "No lyrics available")
        ]
    }
    
    // MARK: - Timestamp Synthesis
    
    /// Synthesizes word-level timestamps (<mm:ss.ms>word) for LRC text that only has line-level timestamps.
    /// If the text already has word-level timestamps, they are returned unchanged.
    static func synthesizeWordTimestamps(from lrc: String) -> String {
        // If it already has word-level timestamps, return as-is
        if lrc.range(of: "<\\d{2,}:\\d{2}(?:\\.\\d+)?>", options: .regularExpression) != nil {
            return lrc
        }
        
        let lines = lrc.components(separatedBy: .newlines)
        let pattern = "\\[(\\d{2,}):(\\d{2}(?:\\.\\d+)?)\\](.*)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return lrc }
        
        struct LineData {
            var original: String
            var timeInSeconds: Double
            var text: String
            var min: String
            var sec: String
        }
        
        var parsedLines: [LineData] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            
            let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let match = regex.firstMatch(in: trimmed, options: [], range: nsRange) {
                if match.numberOfRanges == 4 {
                    let mStr = String(trimmed[Range(match.range(at: 1), in: trimmed)!])
                    let sStr = String(trimmed[Range(match.range(at: 2), in: trimmed)!])
                    let text = String(trimmed[Range(match.range(at: 3), in: trimmed)!]).trimmingCharacters(in: .whitespaces)
                    
                    if let m = Double(mStr), let s = Double(sStr) {
                        let time = (m * 60) + s
                        parsedLines.append(LineData(original: trimmed, timeInSeconds: time, text: text, min: mStr, sec: sStr))
                    }
                }
            } else {
                // Not a timestamped line, maybe metadata, keep it
            }
        }
        
        if parsedLines.isEmpty { return lrc }
        
        var enhancedLRC = ""
        for i in 0..<parsedLines.count {
            let current = parsedLines[i]
            let nextTime = (i + 1 < parsedLines.count) ? parsedLines[i+1].timeInSeconds : current.timeInSeconds + 5.0
            let duration = max(0, nextTime - current.timeInSeconds)
            
            let words = current.text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if words.isEmpty {
                enhancedLRC += "[\(current.min):\(current.sec)]\n"
                continue
            }
            
            // Distribute duration across words evenly
            let timePerWord = duration / Double(words.count)
            
            var enhancedLine = "[\(current.min):\(current.sec)] "
            var currentWordTime = current.timeInSeconds
            for word in words {
                let m = Int(currentWordTime / 60)
                let s = currentWordTime.truncatingRemainder(dividingBy: 60)
                let timeString = String(format: "%02d:%05.2f", m, s)
                enhancedLine += "<\(timeString)>\(word) "
                currentWordTime += timePerWord
            }
            enhancedLRC += enhancedLine.trimmingCharacters(in: .whitespaces) + "\n"
        }
        
        return enhancedLRC
    }
    
    // MARK: - Hindi to Hinglish Transliteration
    
    /// Checks if the text contains any Devanagari (Hindi) characters
    private static func containsDevanagari(_ text: String) -> Bool {
        return text.unicodeScalars.contains { scalar in
            // Devanagari Unicode block: U+0900 to U+097F
            return (0x0900...0x097F).contains(scalar.value)
        }
    }
    
    /// Transliterates Hindi (Devanagari) text to Hinglish (Latin script).
    /// Only applies to text that contains Devanagari characters.
    /// English parts of the text are left completely untouched.
    static func transliterateIfHindi(_ text: String) -> String {
        guard containsDevanagari(text) else { return text }
        let mutableString = NSMutableString(string: text)
        // Step 1: Convert Devanagari to Latin (leaves English characters untouched)
        CFStringTransform(mutableString, nil, kCFStringTransformToLatin, false)
        // Step 2: Remove diacritical marks for cleaner Hinglish readability
        CFStringTransform(mutableString, nil, kCFStringTransformStripDiacritics, false)
        return mutableString as String
    }
}
