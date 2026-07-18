import Foundation
import AVFoundation
import SwiftUI
import Combine
import MediaPlayer

class AudioPlayerManager: NSObject, ObservableObject {
    static var nextOnlineId = 10000
    
    @Published var tracks: [Track] = []
    @Published var displayedTracks: [Track] = []
    @Published var loadedTracks: [Track] = []
    @Published var playlist1Tracks: [Track] = []
    
    private var playbackTimer: Timer?
    
    let backendURL = "https://music100-backend.onrender.com"
    
    func savePlaylist() {
        if let data = try? JSONEncoder().encode(playlist1Tracks) {
            UserDefaults.standard.set(data, forKey: "playlist1Tracks")
        }
    }
    
    func loadPlaylist() {
        if let data = UserDefaults.standard.data(forKey: "playlist1Tracks"),
           let saved = try? JSONDecoder().decode([Track].self, from: data) {
            self.playlist1Tracks = saved
        }
    }
    
    func addToPlaylist(_ track: Track) {
        if !playlist1Tracks.contains(where: { $0.id == track.id }) {
            playlist1Tracks.append(track)
            savePlaylist()
        }
    }
    
    func removeFromPlaylist(_ track: Track) {
        playlist1Tracks.removeAll { $0.id == track.id }
        savePlaylist()
        if activeFilter == "Playlist #1" {
            applyFilters()
        }
    }
    
    @Published var activeFilter: String = "All"
    @Published var searchQuery: String = "" {
        didSet {
            applyFilters()
        }
    }
    private var cancellables = Set<AnyCancellable>()
    
    @Published var currentTrack: Track?
    @Published var isPlaying: Bool = false
    @Published var isLoading: Bool = false
    @Published var playbackProgress: Double = 0.0
    @Published var playbackDuration: Double = 1.0
    
    @Published var parsedLyrics: [LyricLine] = []
    @Published var currentLyricIndex: Int = -1
    @Published var karaokeMode: Int = 0 { // 0 = Off, 1 = Word-by-Word, 2 = Sliding
        didSet {
            if karaokeMode != oldValue, let currentTrack = currentTrack {
                let wasKaraoke = oldValue > 0
                let isNowKaraoke = karaokeMode > 0
                if wasKaraoke != isNowKaraoke {
                    loadLyrics(for: currentTrack)
                }
            }
        }
    }
    
    var isKaraokeMode: Bool { karaokeMode > 0 }
    
    @Published var isPlayerExpanded: Bool = false
    
    @Published var errorMessage: String? = nil
    @Published var showErrorAlert: Bool = false
    
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var keepUpObservation: NSKeyValueObservation?
    private var durationObservation: NSKeyValueObservation?
    
    private var preloadedItems: [Int: AVPlayerItem] = [:]
    
    override init() {
        super.init()
        setupAudioSession()
        setupRemoteTransportControls()
        loadTracks()
        loadPlaylist()
    }
    
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            
            NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: session)
        } catch {
            print("Failed to set up audio session: \(error)")
        }
    }
    
    // MARK: - Auto-Download & Sync
    
    @Published var isDownloadingNewSong = false
    @Published var downloadProgressMessage = ""
    @Published var downloadingTracks: Set<String> = []
    
    func downloadAndAddSong(youtubeURL: String) {
        guard let url = URL(string: "\(backendURL)/api/track/download_and_sync?url=\(youtubeURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") else { return }
        
        let placeholderId = -Int.random(in: 100000...999999)
        let placeholderTrack = Track(
            id: placeholderId,
            title: youtubeURL.contains("http") ? "Resolving Link..." : youtubeURL,
            artist: "Downloading...",
            isDownloaded: false,
            coverBase64: nil,
            coverURL: nil,
            sourceFileName: youtubeURL,
            cachedCoverImage: nil
        )
        
        DispatchQueue.main.async {
            self.tracks.insert(placeholderTrack, at: 0)
            self.loadedTracks.insert(placeholderTrack, at: 0)
            self.isDownloadingNewSong = true
            self.downloadingTracks.insert(youtubeURL)
            self.downloadProgressMessage = "Fetching metadata..."
        }
        
        let removePlaceholder = {
            DispatchQueue.main.async {
                self.tracks.removeAll { $0.id == placeholderId }
                self.loadedTracks.removeAll { $0.id == placeholderId }
                self.isDownloadingNewSong = false
                self.downloadingTracks.remove(youtubeURL)
            }
        }
        
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                print("Download failed: \(error)")
                DispatchQueue.main.async {
                    self.errorMessage = "Download failed: \(error.localizedDescription)"
                    self.showErrorAlert = true
                }
                removePlaceholder()
                return
            }
            
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("Failed to parse backend response")
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to get response from server."
                    self.showErrorAlert = true
                }
                removePlaceholder()
                return
            }
            
            // Check if backend returned an error
            if let backendError = json["error"] as? String {
                print("Backend error: \(backendError)")
                DispatchQueue.main.async {
                    self.errorMessage = "Server error: \(backendError.prefix(100))"
                    self.showErrorAlert = true
                }
                removePlaceholder()
                return
            }
            
            guard let audioUrlString = json["audioUrl"] as? String,
                  let artist = json["artist"] as? String,
                  let title = json["title"] as? String else {
                print("Missing fields in backend response")
                DispatchQueue.main.async {
                    self.errorMessage = "Server returned incomplete data."
                    self.showErrorAlert = true
                }
                removePlaceholder()
                return
            }
            
            let enhancedLyrics = json["enhancedLyrics"] as? String
            let standardLyrics = json["lyrics"] as? String
            
            DispatchQueue.main.async {
                self.downloadProgressMessage = "Downloading audio..."
                // Update placeholder title and artist now that we have them
                if let idx = self.tracks.firstIndex(where: { $0.id == placeholderId }) {
                    let oldTrack = self.tracks[idx]
                    self.tracks[idx] = Track(
                        id: oldTrack.id,
                        title: title,
                        artist: artist,
                        isDownloaded: oldTrack.isDownloaded,
                        coverBase64: oldTrack.coverBase64,
                        coverURL: oldTrack.coverURL,
                        sourceFileName: oldTrack.sourceFileName,
                        cachedCoverImage: oldTrack.cachedCoverImage
                    )
                }
                if let idx = self.loadedTracks.firstIndex(where: { $0.id == placeholderId }) {
                    let oldTrack = self.loadedTracks[idx]
                    self.loadedTracks[idx] = Track(
                        id: oldTrack.id,
                        title: title,
                        artist: artist,
                        isDownloaded: oldTrack.isDownloaded,
                        coverBase64: oldTrack.coverBase64,
                        coverURL: oldTrack.coverURL,
                        sourceFileName: oldTrack.sourceFileName,
                        cachedCoverImage: oldTrack.cachedCoverImage
                    )
                }
            }
            
            guard let audioDownloadURL = URL(string: audioUrlString) else {
                removePlaceholder()
                return
            }
            
            let downloadTask = URLSession.shared.downloadTask(with: audioDownloadURL) { localURL, response, error in
                defer { removePlaceholder() } // This will remove the placeholder and reset the spinner
                
                if let error = error {
                    print("Audio download error: \(error)")
                    DispatchQueue.main.async {
                        self.errorMessage = "Failed to download audio file: \(error.localizedDescription)"
                        self.showErrorAlert = true
                    }
                    return
                }
                
                guard let localURL = localURL else {
                    DispatchQueue.main.async {
                        self.errorMessage = "Failed to locate downloaded audio file."
                        self.showErrorAlert = true
                    }
                    return
                }
                
                guard let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
                
                let baseName = "\(artist) - \(title)".replacingOccurrences(of: "/", with: "-")
                let destinationAudioURL = docsURL.appendingPathComponent("\(baseName).m4a")
                
                do {
                    if FileManager.default.fileExists(atPath: destinationAudioURL.path) {
                        try FileManager.default.removeItem(at: destinationAudioURL)
                    }
                    try FileManager.default.moveItem(at: localURL, to: destinationAudioURL)
                    
                    if let lyrics = enhancedLyrics, !lyrics.isEmpty {
                        let lyricsURL = docsURL.appendingPathComponent("\(baseName).enhanced.lrc")
                        try lyrics.write(to: lyricsURL, atomically: true, encoding: .utf8)
                    }
                    
                    if let standard = standardLyrics, !standard.isEmpty {
                        let standardURL = docsURL.appendingPathComponent("\(baseName).lrc")
                        try standard.write(to: standardURL, atomically: true, encoding: .utf8)
                    }
                    
                    DispatchQueue.main.async {
                        self.loadTracks() // Automatically repopulates tracks with the actual downloaded file!
                        self.downloadProgressMessage = "Done!"
                    }
                } catch {
                    print("Error saving downloaded files: \(error)")
                    DispatchQueue.main.async {
                        self.errorMessage = "Error saving audio file: \(error.localizedDescription)"
                        self.showErrorAlert = true
                    }
                }
            }
            downloadTask.resume()
            
        }.resume()
    }
    
    // MARK: - Import Local File Lyrics
    func fetchLyricsForLocalFile(filename: String, artist: String, title: String) {
        let query = "\(artist) \(title)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "https://lrclib.net/api/search?q=\(query)"
        guard let url = URL(string: urlString) else { return }
        
        DispatchQueue.main.async {
            self.isDownloadingNewSong = true
            self.downloadProgressMessage = "Fetching lyrics..."
        }
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            defer {
                DispatchQueue.main.async {
                    self.isDownloadingNewSong = false
                    self.downloadProgressMessage = ""
                    self.loadTracks()
                }
            }
            if let error = error {
                print("Lyrics fetch error: \(error)")
                return
            }
            guard let data = data else { return }
            do {
                if let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    // Find the best match: prefer one that has syncedLyrics
                    var bestMatch: [String: Any]? = nil
                    for match in jsonArray {
                        if let synced = match["syncedLyrics"] as? String, !synced.isEmpty {
                            bestMatch = match
                            break
                        }
                    }
                    if bestMatch == nil { bestMatch = jsonArray.first }
                    
                    if let match = bestMatch {
                        let plainLyrics = match["plainLyrics"] as? String ?? ""
                        let syncedLyrics = match["syncedLyrics"] as? String ?? ""
                        let baseFilename = (filename as NSString).deletingPathExtension
                        
                        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                        
                        // syncedLyrics has [MM:SS.xx] timestamps — save as BOTH .lrc and .enhanced.lrc
                        // plainLyrics has NO timestamps — only use as fallback if synced is empty
                        if !syncedLyrics.isEmpty {
                            let lrcUrl = documentsDirectory.appendingPathComponent(baseFilename + ".lrc")
                            try syncedLyrics.write(to: lrcUrl, atomically: true, encoding: .utf8)
                            
                            let synthesized = LRCParser.synthesizeWordTimestamps(from: syncedLyrics)
                            let enhancedUrl = documentsDirectory.appendingPathComponent(baseFilename + ".enhanced.lrc")
                            try synthesized.write(to: enhancedUrl, atomically: true, encoding: .utf8)
                            print("Saved synced lyrics as both .lrc and .enhanced.lrc for \(baseFilename)")
                        } else if !plainLyrics.isEmpty {
                            // No synced lyrics available — save plain text as .lrc as a fallback
                            let lrcUrl = documentsDirectory.appendingPathComponent(baseFilename + ".lrc")
                            try plainLyrics.write(to: lrcUrl, atomically: true, encoding: .utf8)
                            print("Saved plain lyrics as .lrc for \(baseFilename) (no synced lyrics available)")
                        }
                    }
                }
            } catch {
                print("JSON Error parsing lyrics: \(error)")
            }
        }.resume()
    }
    
    // MARK: - Track Management
    func deleteTrackPermanently(_ track: Track) {
        if currentTrack?.id == track.id {
            stopCurrentPlayer()
            currentTrack = nil
        }
        
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let baseName = track.sourceFileName
        let exts = ["mp3", "m4a", "lrc", "enhanced.lrc", "cover.jpg"]
        
        for ext in exts {
            let fileURL = documentsDirectory.appendingPathComponent("\(baseName).\(ext)")
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        
        DispatchQueue.main.async {
            self.tracks.removeAll { $0.id == track.id }
            self.loadedTracks.removeAll { $0.id == track.id }
            self.playlist1Tracks.removeAll { $0.id == track.id }
            self.displayedTracks.removeAll { $0.id == track.id }
        }
    }
    
    func saveCustomCover(for track: Track, imageData: Data) {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let coverURL = documentsDirectory.appendingPathComponent("\(track.sourceFileName).cover.jpg")
        
        guard let originalImage = UIImage(data: imageData),
              let cgImage = originalImage.cgImage else { return }
        
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let minDimension = min(width, height)
        let xOffset = (width - minDimension) / 2.0
        let yOffset = (height - minDimension) / 2.0
        let cropRect = CGRect(x: xOffset, y: yOffset, width: minDimension, height: minDimension)
        
        guard let croppedCGImage = cgImage.cropping(to: cropRect) else { return }
        let croppedImage = UIImage(cgImage: croppedCGImage, scale: originalImage.scale, orientation: originalImage.imageOrientation)
        
        guard let finalJPEGData = croppedImage.jpegData(compressionQuality: 0.8) else { return }
        try? finalJPEGData.write(to: coverURL)
        
        DispatchQueue.main.async {
            let uiImage = croppedImage
                if let index = self.tracks.firstIndex(where: { $0.id == track.id }) {
                    self.tracks[index].cachedCoverImage = uiImage
                }
                if let index = self.loadedTracks.firstIndex(where: { $0.id == track.id }) {
                    self.loadedTracks[index].cachedCoverImage = uiImage
                }
                if let index = self.playlist1Tracks.firstIndex(where: { $0.id == track.id }) {
                    self.playlist1Tracks[index].cachedCoverImage = uiImage
                }
                if let index = self.displayedTracks.firstIndex(where: { $0.id == track.id }) {
                    self.displayedTracks[index].cachedCoverImage = uiImage
                }
                Track.imageCache.setObject(uiImage, forKey: NSString(string: "\(track.id)"))
                
                if self.currentTrack?.id == track.id {
                    self.currentTrack?.cachedCoverImage = uiImage
                }
            }
    }
    
    func getRawLyrics(for track: Track, type: String) -> String? {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documentsDirectory.appendingPathComponent("\(track.sourceFileName).\(type)")
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }
    
    func saveRawLyrics(for track: Track, type: String, content: String) {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documentsDirectory.appendingPathComponent("\(track.sourceFileName).\(type)")
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
        
        DispatchQueue.main.async {
            if self.currentTrack?.id == track.id {
                self.loadLyrics(for: track)
            }
        }
    }
    
    @objc private func handleInterruption(notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
              
        if type == .began {
            self.pause()
        } else if type == .ended {
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                self.play()
            }
        }
    }
    
    private func setupRemoteTransportControls() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: event.positionTime)
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.playNext()
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.playPrevious()
            return .success
        }
    }
    
    func playNext() {
        guard let current = currentTrack,
              !displayedTracks.isEmpty,
              let index = displayedTracks.firstIndex(where: { $0.id == current.id }) else { return }
        
        let nextIndex = (index + 1) % displayedTracks.count
        playTrack(displayedTracks[nextIndex])
    }
    
    func playPrevious() {
        guard let current = currentTrack,
              !displayedTracks.isEmpty,
              let index = displayedTracks.firstIndex(where: { $0.id == current.id }) else { return }
        
        let prevIndex = (index - 1 + displayedTracks.count) % displayedTracks.count
        playTrack(displayedTracks[prevIndex])
    }
    
    private func updateNowPlayingInfo() {
        guard let track = currentTrack else { return }
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = track.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = track.artist
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = player?.currentTime().seconds ?? 0.0
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = playbackDuration
        
        if let image = track.getUIImage() {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in return image }
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    func updateWhichOneCovers() {
        // Obsolete: Which One now has its own proper cover art
    }

    func loadTracks() {
        var localLoaded: [Track] = []
        let bundleURL = Bundle.main.bundleURL
        
        do {
            var allFiles: [URL] = []
            
            // Files in root bundle
            let contents = try FileManager.default.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil)
            allFiles.append(contentsOf: contents)
            
            // Files in MoreSongs folder
            let moreSongsURL = bundleURL.appendingPathComponent("MoreSongs")
            if FileManager.default.fileExists(atPath: moreSongsURL.path) {
                let moreContents = try FileManager.default.contentsOfDirectory(at: moreSongsURL, includingPropertiesForKeys: nil)
                allFiles.append(contentsOf: moreContents)
            }
            
            // Files in Documents folder
            if let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                if let docContents = try? FileManager.default.contentsOfDirectory(at: docsURL, includingPropertiesForKeys: nil) {
                    allFiles.append(contentsOf: docContents)
                }
            }
            
            var trackBases: [String: (mp3URL: URL?, lrcURL: URL?)] = [:]
            
            for fileURL in allFiles {
                let ext = fileURL.pathExtension.lowercased()
                if ext == "mp3" || ext == "m4a" || ext == "lrc" {
                    var baseName = fileURL.deletingPathExtension().lastPathComponent
                    if ext == "lrc" && baseName.lowercased().hasSuffix(".enhanced") {
                        baseName = String(baseName.dropLast(9))
                    }
                    let key = baseName.lowercased()
                    
                    var entry = trackBases[key] ?? (mp3URL: nil, lrcURL: nil)
                    if ext == "mp3" || ext == "m4a" {
                        entry.mp3URL = fileURL
                    } else if ext == "lrc" {
                        entry.lrcURL = fileURL
                    }
                    trackBases[key] = entry
                }
            }
            
            var trackId = 1
            for key in trackBases.keys.sorted() {
                guard let entry = trackBases[key] else { continue }
                
                let fileURL = entry.mp3URL ?? entry.lrcURL!
                let filename = fileURL.deletingPathExtension().lastPathComponent
                
                var artist = "Unknown Artist"
                var title = filename
                
                if let dashRange = filename.range(of: " - ") {
                    artist = String(filename[..<dashRange.lowerBound])
                    title = String(filename[dashRange.upperBound...])
                }
                
                // Extract Cover Art
                var coverBase64: String? = nil
                var coverUIImage: UIImage? = nil
                if let mp3URL = entry.mp3URL {
                    let asset = AVAsset(url: mp3URL)
                    for item in asset.commonMetadata {
                        if item.commonKey == .commonKeyArtwork, let data = item.value as? Data {
                            coverBase64 = data.base64EncodedString()
                            coverUIImage = UIImage(data: data)
                            break
                        }
                    }
                }
                
                // Map local covers by title (easter eggs)
                var coverURL: String? = nil
                if title.localizedCaseInsensitiveContains("First Person Shooter") {
                    coverURL = "first_person_shooter_cover.jpg"
                } else if artist.localizedCaseInsensitiveContains("Drake") {
                    coverURL = "1000x1000bb.webp"
                    coverBase64 = nil
                    coverUIImage = nil
                } else if title.localizedCaseInsensitiveContains("7 Minute Drill") {
                    coverURL = "7_minute_drill_cover.jpg"
                }
                
                if coverURL == nil && coverBase64 == nil {
                    coverURL = "https://picsum.photos/400/400?random=\(trackId)"
                }
                
                let track = Track(
                    id: trackId,
                    title: title,
                    artist: artist,
                    isDownloaded: entry.mp3URL != nil,
                    coverBase64: coverBase64,
                    coverURL: coverURL,
                    sourceFileName: filename,
                    cachedCoverImage: coverUIImage
                )
                localLoaded.append(track)
                trackId += 1
            }
        } catch {
            print("Error loading tracks from bundle: \(error)")
        }
        
        // Custom order logic
        var finalTracks: [Track] = []
        
        let whichOneIndex = localLoaded.firstIndex(where: { $0.title.localizedCaseInsensitiveContains("Which One") })
        let whisper = localLoaded.first(where: { $0.title.localizedCaseInsensitiveContains("Whisper My Name") })

        
        let whichOne = whichOneIndex != nil ? localLoaded[whichOneIndex!] : nil
        let fps = localLoaded.first(where: { $0.title.localizedCaseInsensitiveContains("First Person Shooter") })
        let drill = localLoaded.first(where: { $0.title.localizedCaseInsensitiveContains("7 Minute Drill") })
        let pushUps = localLoaded.first(where: { $0.title.localizedCaseInsensitiveContains("Push Ups") })
        let nationalTreasure = localLoaded.first(where: { $0.title.localizedCaseInsensitiveContains("National Treasure") || $0.title.localizedCaseInsensitiveContains("National Tressure") })
        
        var remaining = localLoaded.filter { track in
            let title = track.title.lowercased()
            return !title.contains("which one") && !title.contains("whisper my name") && !title.contains("first person shooter") && !title.contains("7 minute drill") && !title.contains("push ups") && !title.contains("national treasure") && !title.contains("national tressure")
        }
        
        if let originalWhisperIndex = localLoaded.firstIndex(where: { $0.title.localizedCaseInsensitiveContains("Whisper My Name") }) {
            var insertGroup: [Track] = []
            if let w1 = whichOne { insertGroup.append(w1) }
            if let wh = whisper { insertGroup.append(wh) }
            if let f = fps { insertGroup.append(f) }
            if let pu = pushUps { insertGroup.append(pu) }
            if let nt = nationalTreasure { insertGroup.append(nt) }
            if let dr = drill { insertGroup.append(dr) }
            
            let insertPos = min(originalWhisperIndex, remaining.count)
            remaining.insert(contentsOf: insertGroup, at: insertPos)
            finalTracks = remaining
        } else {
            var insertGroup: [Track] = []
            if let w1 = whichOne { insertGroup.append(w1) }
            if let wh = whisper { insertGroup.append(wh) }
            if let f = fps { insertGroup.append(f) }
            if let pu = pushUps { insertGroup.append(pu) }
            if let nt = nationalTreasure { insertGroup.append(nt) }
            if let dr = drill { insertGroup.append(dr) }
            finalTracks = insertGroup + remaining
        }
        
        if let savedOrder = UserDefaults.standard.stringArray(forKey: "CustomTrackOrder") {
            var orderedTracks: [Track] = []
            var remainingTracks = finalTracks
            
            for filename in savedOrder {
                if let index = remainingTracks.firstIndex(where: { $0.sourceFileName == filename }) {
                    orderedTracks.append(remainingTracks.remove(at: index))
                }
            }
            orderedTracks.append(contentsOf: remainingTracks)
            finalTracks = orderedTracks
        }
        
        // Preserve any streaming (non-downloaded) tracks that were added to loadedTracks
        let existingStreamTracks = self.loadedTracks.filter { !$0.isDownloaded }
        
        self.tracks = finalTracks + existingStreamTracks.filter { st in
            !finalTracks.contains(where: { $0.sourceFileName.lowercased() == st.sourceFileName.lowercased() })
        }
        self.loadedTracks = self.tracks
        updateWhichOneCovers()
        applyFilters()
    }
    
    func applyFilters() {
        var filtered = loadedTracks
        
        if activeFilter == "Loaded" {
            // Show streaming tracks that have been loaded (preloaded or added)
            filtered = loadedTracks.filter { !$0.isDownloaded }
        } else if activeFilter == "Offline" {
            filtered = loadedTracks.filter { $0.isDownloaded }
        } else if activeFilter == "Playlist #1" {
            filtered = playlist1Tracks
        }
        // "All" shows everything in loadedTracks
        
        if !searchQuery.isEmpty {
            filtered = filtered.filter {
                $0.title.localizedCaseInsensitiveContains(searchQuery) ||
                $0.artist.localizedCaseInsensitiveContains(searchQuery)
            }
        }
        
        self.displayedTracks = filtered
        updateWhichOneCovers()
    }
    
    func deleteTrack(at offsets: IndexSet) {
        if activeFilter == "Playlist #1" {
            let toRemove = offsets.map { displayedTracks[$0] }
            playlist1Tracks.removeAll { track in toRemove.contains(where: { $0.id == track.id }) }
            savePlaylist()
        } else if activeFilter == "Loaded" {
            let toRemove = offsets.map { displayedTracks[$0] }
            loadedTracks.removeAll { track in toRemove.contains(where: { $0.id == track.id }) }
            // If they are playing, might need to handle that, but fine for now
        }
        applyFilters()
    }
    
    func filterSelected(_ filter: String) {
        self.activeFilter = filter
        applyFilters()
    }
    
    func moveTrack(from source: IndexSet, to destination: Int) {
        var currentDisplayed = displayedTracks
        currentDisplayed.move(fromOffsets: source, toOffset: destination)
        self.displayedTracks = currentDisplayed
        
        if activeFilter == "Playlist #1" {
            self.playlist1Tracks = currentDisplayed
            savePlaylist()
        } else if activeFilter == "All" {
            self.loadedTracks = currentDisplayed
            self.tracks = currentDisplayed
            saveCustomOrder()
        }
    }
    
    func saveCustomOrder() {
        let filenames = loadedTracks.map { $0.sourceFileName }
        UserDefaults.standard.set(filenames, forKey: "CustomTrackOrder")
    }
    
    func playTrack(_ track: Track) {
        // Fully stop old player to prevent overlap
        stopCurrentPlayer()
        
        self.currentTrack = track
        updateWhichOneCovers()
        self.currentLyricIndex = -1
        self.playbackProgress = 0.0
        
        if track.isDownloaded {
            loadLyrics(for: track)
            
            // Find local audio
            var localAudioURL: URL? = nil
            let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            
            // 1. Check Documents directory (.m4a and .mp3)
            if let docs = docsURL {
                let m4aURL = docs.appendingPathComponent("\(track.sourceFileName).m4a")
                let mp3URL = docs.appendingPathComponent("\(track.sourceFileName).mp3")
                if FileManager.default.fileExists(atPath: m4aURL.path) {
                    localAudioURL = m4aURL
                } else if FileManager.default.fileExists(atPath: mp3URL.path) {
                    localAudioURL = mp3URL
                }
            }
            
            // 2. Check App Bundle (.mp3 in root)
            if localAudioURL == nil {
                localAudioURL = Bundle.main.url(forResource: track.sourceFileName, withExtension: "mp3")
            }
            
            // 3. Check App Bundle (.mp3 in MoreSongs)
            if localAudioURL == nil {
                localAudioURL = Bundle.main.url(forResource: track.sourceFileName, withExtension: "mp3", subdirectory: "MoreSongs")
            }
            
            // 4. Check App Bundle (.m4a in root and MoreSongs)
            if localAudioURL == nil {
                localAudioURL = Bundle.main.url(forResource: track.sourceFileName, withExtension: "m4a") ??
                                Bundle.main.url(forResource: track.sourceFileName, withExtension: "m4a", subdirectory: "MoreSongs")
            }
            
            guard let url = localAudioURL else {
                self.errorMessage = "Could not find audio file for \"\(track.title)\""
                self.showErrorAlert = true
                return
            }
            
            setupPlayer(with: url)
        } else if track.isPreloaded, let proxyUrl = track.preloadedProxyUrl {
            self.parsedLyrics = track.preloadedLyrics ?? LRCParser.mockLyrics()
            if let item = preloadedItems[track.id] {
                self.setupPlayer(withItem: item)
            } else {
                self.setupPlayer(with: proxyUrl)
            }
        } else {
            // Online Track - Fetch stream URL and lyrics from backend
            self.isLoading = true
            self.parsedLyrics = [LyricLine(timestamp: 0.0, text: "Loading lyrics...")]
            
            let trackIdAtStart = track.id // Capture to detect if user switched tracks
            
            let query = track.sourceFileName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let urlString = "\(backendURL)/api/track/load?query=\(query)"
            guard let url = URL(string: urlString) else {
                self.isLoading = false
                return
            }
            
            URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
                guard let self = self else { return }
                
                // If user already switched to another track, discard this response
                guard self.currentTrack?.id == trackIdAtStart else { return }
                
                guard let data = data, error == nil else {
                    DispatchQueue.main.async {
                        guard self.currentTrack?.id == trackIdAtStart else { return }
                        self.isLoading = false
                        self.errorMessage = "Network error loading track."
                        self.showErrorAlert = true
                    }
                    return
                }
                
                do {
                    if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        // Check if backend returned an error
                        if let backendError = dict["error"] as? String {
                            DispatchQueue.main.async {
                                guard self.currentTrack?.id == trackIdAtStart else { return }
                                self.isLoading = false
                                self.errorMessage = "Server error: \(String(backendError.prefix(100)))"
                                self.showErrorAlert = true
                            }
                            return
                        }
                        
                        guard let proxyUrlString = dict["proxyUrl"] as? String,
                              let fullProxyUrl = URL(string: "\(self.backendURL)\(proxyUrlString)") else {
                            DispatchQueue.main.async {
                                guard self.currentTrack?.id == trackIdAtStart else { return }
                                self.isLoading = false
                                self.errorMessage = "Failed to load audio stream."
                                self.showErrorAlert = true
                            }
                            return
                        }
                        
                        let lyricsText = dict["lyrics"] as? String ?? ""
                        
                        DispatchQueue.main.async {
                            guard self.currentTrack?.id == trackIdAtStart else { return }
                            if !lyricsText.isEmpty {
                                self.parsedLyrics = LRCParser.parse(payload: lyricsText)
                            } else {
                                self.parsedLyrics = LRCParser.mockLyrics()
                            }
                            
                            var updatedTrack = track
                            updatedTrack.isPreloaded = true
                            updatedTrack.preloadedProxyUrl = fullProxyUrl
                            updatedTrack.preloadedLyrics = self.parsedLyrics
                            
                            if !self.loadedTracks.contains(where: { $0.id == track.id }) {
                                self.loadedTracks.append(updatedTrack)
                                self.tracks.append(updatedTrack)
                            } else if let idx = self.loadedTracks.firstIndex(where: { $0.id == track.id }) {
                                self.loadedTracks[idx] = updatedTrack
                            }
                            
                            self.applyFilters()
                            self.setupPlayer(with: fullProxyUrl)
                        }
                    } else {
                        DispatchQueue.main.async {
                            guard self.currentTrack?.id == trackIdAtStart else { return }
                            self.isLoading = false
                            self.errorMessage = "Invalid server response."
                            self.showErrorAlert = true
                        }
                    }
                } catch {
                    DispatchQueue.main.async {
                        guard self.currentTrack?.id == trackIdAtStart else { return }
                        self.isLoading = false
                        self.errorMessage = "Error processing server response."
                        self.showErrorAlert = true
                    }
                }
            }.resume()
        }
    }
    
    func preloadTrack(_ track: Track) {
        guard !track.isDownloaded, !track.isPreloaded, !track.isPreloading else { return }
        
        let updatePreloading = { (isPreloading: Bool) in
            if let idx = self.playlist1Tracks.firstIndex(where: { $0.id == track.id }) {
                self.playlist1Tracks[idx].isPreloading = isPreloading
            }
            if let idx = self.displayedTracks.firstIndex(where: { $0.id == track.id }) {
                self.displayedTracks[idx].isPreloading = isPreloading
            }
        }
        
        updatePreloading(true)
        
        let query = track.sourceFileName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "\(backendURL)/api/track/load?query=\(query)"
        guard let url = URL(string: urlString) else { return }
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            guard let data = data, error == nil else {
                DispatchQueue.main.async {
                    updatePreloading(false)
                }
                return
            }
            
            do {
                if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let proxyUrlString = dict["proxyUrl"] as? String,
                   let fullProxyUrl = URL(string: "\(self.backendURL)\(proxyUrlString)") {
                    
                    let lyricsText = dict["lyrics"] as? String ?? ""
                    
                    DispatchQueue.main.async {
                        var t = track
                        t.isPreloading = false
                        t.isPreloaded = true
                        t.preloadedProxyUrl = fullProxyUrl
                        if !lyricsText.isEmpty {
                            t.preloadedLyrics = LRCParser.parse(payload: lyricsText)
                        }
                        
                        let preloadedTrack = t
                        
                        if let idx = self.playlist1Tracks.firstIndex(where: { $0.id == track.id }) {
                            self.playlist1Tracks[idx] = preloadedTrack
                            self.savePlaylist()
                        }
                        
                        // Initialize AVPlayerItem to start buffering
                        let playerItem = AVPlayerItem(url: fullProxyUrl)
                        playerItem.preferredForwardBufferDuration = 0.0 // buffer aggressively
                        self.preloadedItems[track.id] = playerItem
                        
                        if !self.loadedTracks.contains(where: { $0.id == track.id }) {
                            self.loadedTracks.append(preloadedTrack)
                            self.tracks.append(preloadedTrack)
                        }
                        
                        // Refresh displayed array if necessary
                        if let dispIdx = self.displayedTracks.firstIndex(where: { $0.id == track.id }) {
                            self.displayedTracks[dispIdx] = preloadedTrack
                        }
                        
                        self.updateWhichOneCovers()
                        self.applyFilters()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    updatePreloading(false)
                }
            }
        }.resume()
    }
    /// Fully stop and destroy the current player to prevent overlap
    private func stopCurrentPlayer() {
        player?.pause()
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        keepUpObservation?.invalidate()
        keepUpObservation = nil
        durationObservation?.invalidate()
        durationObservation = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        isPlaying = false
        isLoading = false
    }
    
    private func setupPlayer(with url: URL) {
        let playerItem = AVPlayerItem(url: url)
        setupPlayer(withItem: playerItem)
    }
    
    private func setupPlayer(withItem playerItem: AVPlayerItem) {
        player?.pause()
        
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        
        playerItem.preferredForwardBufferDuration = 0.0
        
        player = AVPlayer(playerItem: playerItem)
        
        self.isLoading = true
        
        statusObservation = playerItem.observe(\.status, options: [.new, .old]) { [weak self] item, _ in
            DispatchQueue.main.async {
                if item.status == .readyToPlay {
                    self?.isLoading = false
                    self?.playbackDuration = item.duration.seconds
                    self?.updateNowPlayingInfo()
                } else if item.status == .failed {
                    self?.isLoading = false
                    self?.errorMessage = "Failed to load audio stream."
                    self?.showErrorAlert = true
                }
            }
        }
        
        keepUpObservation = playerItem.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                if item.isPlaybackLikelyToKeepUp && item.status == .readyToPlay {
                    self?.isLoading = false
                }
            }
        }
        
        durationObservation = playerItem.observe(\.duration, options: [.new]) { [weak self] item, _ in
             DispatchQueue.main.async {
                if item.duration.isNumeric {
                    self?.playbackDuration = item.duration.seconds
                    self?.updateNowPlayingInfo()
                }
            }
        }
        
        setupTimeObserver()
        play()
    }
    
    private func setupTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        
        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.playbackProgress = time.seconds
            self?.updateLyricsIndex(time: time.seconds)
        }
    }
    
    func togglePlay(forcePlay: Bool = false) {
        if forcePlay || !isPlaying {
            play()
        } else {
            pause()
        }
    }
    
    private func play() {
        player?.play()
        isPlaying = true
        updateNowPlayingInfo()
    }
    
    private func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }
    
    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 1000)
        player?.seek(to: cmTime) { [weak self] _ in
            self?.updateNowPlayingInfo()
        }
    }
    
    private func updateLyricsIndex(time: Double) {
        guard !parsedLyrics.isEmpty else { return }
        
        var newIndex = 0
        for (i, lyric) in parsedLyrics.enumerated() {
            if time >= lyric.timestamp - 0.1 {
                newIndex = i
            } else {
                break
            }
        }
        
        if newIndex != currentLyricIndex {
            withAnimation(.easeInOut(duration: 0.3)) {
                currentLyricIndex = newIndex
            }
        }
    }
    
    func loadLyrics(for track: Track) {
        if track.isDownloaded {
            var lrcUrl: URL? = nil
            let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            
            // 1. Always try enhanced (synced) lyrics first in Documents
            if let docs = docsURL {
                let enhancedURL = docs.appendingPathComponent("\(track.sourceFileName).enhanced.lrc")
                if FileManager.default.fileExists(atPath: enhancedURL.path) {
                    lrcUrl = enhancedURL
                }
            }
            // 2. Try enhanced lyrics in Bundle
            if lrcUrl == nil {
                lrcUrl = Bundle.main.url(forResource: track.sourceFileName, withExtension: "enhanced.lrc") ??
                         Bundle.main.url(forResource: track.sourceFileName, withExtension: "enhanced.lrc", subdirectory: "karokee")
            }
            
            if lrcUrl == nil {
                // Try basic (old) lyrics in Documents
                if let docs = docsURL {
                    let basicURL = docs.appendingPathComponent("\(track.sourceFileName).lrc")
                    if FileManager.default.fileExists(atPath: basicURL.path) {
                        lrcUrl = basicURL
                    }
                }
                // Try basic lyrics in Bundle
                if lrcUrl == nil {
                    lrcUrl = Bundle.main.url(forResource: track.sourceFileName, withExtension: "lrc") ??
                             Bundle.main.url(forResource: track.sourceFileName, withExtension: "lrc", subdirectory: "MoreSongs")
                }
            }
            
            if let url = lrcUrl, let payload = try? String(contentsOf: url, encoding: .utf8) {
                self.parsedLyrics = LRCParser.parse(payload: payload)
            } else {
                self.parsedLyrics = LRCParser.mockLyrics()
            }
        } else if track.isPreloaded {
            self.parsedLyrics = track.preloadedLyrics ?? LRCParser.mockLyrics()
        }
    }
}
