import SwiftUI
import Combine
import UniformTypeIdentifiers
import PhotosUI

// MARK: - Design System
extension Color {
    static let appAccent = Color(hex: "#34D1BF")
    static let appAccentSecondary = Color(hex: "#00B4D8")
    static let appBackground = Color(hex: "#000000")
    static let appCardBg = Color(white: 1, opacity: 0.06)
    static let appBorder = Color.white.opacity(0.08)
    static let appTextSecondary = Color.white.opacity(0.55)
}

struct ContentView: View {
    @StateObject private var manager = AudioPlayerManager()
    
    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            
            DashboardView(manager: manager)
            
            if manager.currentTrack != nil {
                VStack {
                    Spacer()
                    MiniPlayerView(manager: manager)
                        .padding(.horizontal, 16) // Increased padding to floating look
                        .padding(.bottom, 12)
                        .onTapGesture {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                manager.isPlayerExpanded = true
                            }
                        }
                }
            }
            
            if manager.isPlayerExpanded {
                PlayerPageView(manager: manager)
                    .ignoresSafeArea()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: manager.isPlayerExpanded) { oldValue, newValue in
            if newValue {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
        .alert(isPresented: $manager.showErrorAlert) {
            Alert(
                title: Text("Error"),
                message: Text(manager.errorMessage ?? "An error occurred."),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

struct DashboardView: View {
    @ObservedObject var manager: AudioPlayerManager
    @State private var localSearch: String = ""
    @State private var showAddSongSheet: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Music")
                    .font(.system(size: 38, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                Spacer()
                Button(action: {
                    showAddSongSheet = true
                }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.appAccent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                TextField("Search songs...", text: $localSearch)
                    .foregroundColor(.white)
                    .onChange(of: localSearch) { oldValue, newValue in
                        manager.searchQuery = newValue
                    }
                if !localSearch.isEmpty {
                    Button(action: {
                        localSearch = ""
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(10)
            .background(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .cornerRadius(24)
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.appBorder, lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    FilterPill(title: "All", isActive: manager.activeFilter == "All") {
                        manager.filterSelected("All")
                    }
                    FilterPill(title: "Loaded", isActive: manager.activeFilter == "Loaded") {
                        manager.filterSelected("Loaded")
                    }
                    FilterPill(title: "Offline", isActive: manager.activeFilter == "Offline") {
                        manager.filterSelected("Offline")
                    }
                    FilterPill(title: "Playlist #1", isActive: manager.activeFilter == "Playlist #1") {
                        manager.filterSelected("Playlist #1")
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 10)
            
            List {
                if !manager.searchQuery.isEmpty {
                    if !manager.displayedTracks.isEmpty {
                        Section(header: Text("Local Library").font(.headline).foregroundColor(.white).padding(.leading, 0)) {
                            ForEach(manager.displayedTracks) { track in
                                TrackRow(track: track, manager: manager)
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                                    .onTapGesture {
                                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                        manager.playTrack(track)
                                    }
                            }
                        }
                    }
                } else {
                    ForEach(manager.displayedTracks) { track in
                        TrackRow(track: track, manager: manager)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20))
                            .onTapGesture {
                                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                manager.playTrack(track)
                            }
                    }
                    .onDelete(perform: manager.deleteTrack)
                    .onMove { source, destination in
                        manager.moveTrack(from: source, to: destination)
                    }
                }
                
                Color.clear.frame(height: 90)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.immediately)
        }
        .sheet(isPresented: $showAddSongSheet) {
            AddSongView(manager: manager)
                .presentationDetents([.medium])
                .presentationBackground(.ultraThinMaterial)
        }
    }
}

struct AddSongView: View {
    @ObservedObject var manager: AudioPlayerManager
    @Environment(\.dismiss) var dismiss
    @State private var youtubeURL: String = ""
    @State private var showFileImporter = false
    
    var body: some View {
        VStack(spacing: 24) {
            Capsule()
                .fill(Color.white.opacity(0.3))
                .frame(width: 40, height: 5)
                .padding(.top, 10)
            
            Text("Add New Song")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            
            if manager.isDownloadingNewSong {
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(.appAccent)
                        .scaleEffect(1.5)
                    Text(manager.downloadProgressMessage)
                        .foregroundColor(.gray)
                        .font(.subheadline)
                }
                .padding(.top, 30)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Direct Audio URLs (comma or newline separated)")
                        .font(.caption)
                        .foregroundColor(.gray)
                    
                    TextField("https://...", text: $youtubeURL, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(16)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(12)
                        .foregroundColor(.white)
                        .accentColor(.appAccent)
                }
                .padding(.horizontal, 24)
                
                Button(action: {
                    let urls = youtubeURL
                        .components(separatedBy: CharacterSet(charactersIn: ",\n "))
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    
                    for url in urls {
                        manager.downloadAndAddSong(youtubeURL: url)
                    }
                    dismiss()
                }) {
                    Text("Download & Sync Lyrics")
                        .font(.headline)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            youtubeURL.isEmpty ? Color.gray.opacity(0.5) : Color.appAccent
                        )
                        .cornerRadius(12)
                }
                .disabled(youtubeURL.isEmpty)
                .padding(.horizontal, 24)
                
                // OR Divider
                HStack {
                    Rectangle().fill(Color.white.opacity(0.2)).frame(height: 1)
                    Text("OR").foregroundColor(.gray).font(.caption).padding(.horizontal, 8)
                    Rectangle().fill(Color.white.opacity(0.2)).frame(height: 1)
                }
                .padding(.horizontal, 32)
                .padding(.top, 8)
                
                Button(action: {
                    showFileImporter = true
                }) {
                    HStack {
                        Image(systemName: "folder.fill")
                        Text("Import Local Audio File")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(12)
                }
                .padding(.horizontal, 24)
            }
            
            Spacer()
        }
        .preferredColorScheme(.dark)
        .onChange(of: manager.isDownloadingNewSong) { oldValue, newValue in
            if !newValue && manager.downloadProgressMessage == "" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    dismiss()
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let selectedURL = urls.first else { return }
                
                guard selectedURL.startAccessingSecurityScopedResource() else {
                    return
                }
                
                defer { selectedURL.stopAccessingSecurityScopedResource() }
                
                let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                let destinationURL = documentsDirectory.appendingPathComponent(selectedURL.lastPathComponent)
                
                do {
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.copyItem(at: selectedURL, to: destinationURL)
                    
                    // Parse filename
                    let filename = selectedURL.deletingPathExtension().lastPathComponent
                    var artist = "Unknown Artist"
                    var title = filename
                    
                    if let dashRange = filename.range(of: " - ") {
                        artist = String(filename[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                        title = String(filename[dashRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    
                    manager.fetchLyricsForLocalFile(filename: selectedURL.lastPathComponent, artist: artist, title: title)
                    
                } catch {
                    print("Error importing file: \(error)")
                }
            case .failure(let error):
                print("Error selecting file: \(error.localizedDescription)")
            }
        }
        .onChange(of: manager.isDownloadingNewSong) { isDownloading in
            if !isDownloading {
                dismiss()
            }
        }
    }
}

struct FilterPill: View {
    let title: String
    let isActive: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(isActive ? .black : Color.white.opacity(0.7))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Group {
                        if isActive {
                            LinearGradient(colors: [.appAccent, .appAccentSecondary], startPoint: .leading, endPoint: .trailing)
                        } else {
                            Color.clear
                        }
                    }
                )
                .background(isActive ? Color.clear : Color.clear)
                .background {
                    if !isActive {
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .environment(\.colorScheme, .dark)
                    }
                }
                .clipShape(Capsule())
                .overlay(
                    Group {
                        if !isActive {
                            Capsule().stroke(Color.appBorder, lineWidth: 1)
                        }
                    }
                )
        }
        .buttonStyle(BouncyButtonStyle())
    }
}

struct TrackRow: View {
    let track: Track
    @ObservedObject var manager: AudioPlayerManager
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var showEditLyrics = false
    @State private var isShowingPhotoPicker = false
    
    var body: some View {
        let isPlaying = manager.currentTrack?.id == track.id
        
        HStack(spacing: 12) {
            // Small grey button on the left for downloading
            if !track.isDownloaded {
                if manager.downloadingTracks.contains(track.sourceFileName) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .gray))
                        .scaleEffect(0.7)
                        .frame(width: 20, height: 20)
                } else {
                    Button(action: {
                        manager.downloadAndAddSong(youtubeURL: track.sourceFileName)
                    }) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                    .frame(width: 20, height: 20)
                }
            }
            
            if let image = track.getCoverImage() {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: 52, height: 52)
                    .cornerRadius(14)
                    .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
            } else if let url = track.coverURL {
                AsyncImage(url: URL(string: url)) { phase in
                    if let img = phase.image {
                        img.resizable().scaledToFill()
                    } else {
                        Color.gray
                    }
                }
                .frame(width: 52, height: 52)
                .cornerRadius(14)
                .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
            }
            
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if isPlaying {
                        SpinningVinyl(track: track, manager: manager)
                    }
                    Text(track.title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(isPlaying ? Color.appAccent : .white)
                        .lineLimit(1)
                }
                
                HStack(spacing: 4) {
                    if track.isDownloaded {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.appAccent)
                    } else {
                        Text("Stream")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.appAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.appAccent.opacity(0.12))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.appAccent.opacity(0.3), lineWidth: 1)
                            )
                    }
                    Text(track.artist)
                        .font(.system(size: 13, design: .rounded))
                        .foregroundColor(.appTextSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            
            if !track.isDownloaded {
                HStack(spacing: 16) {
                    // Download button moved to the left

                    Button(action: {
                        manager.preloadTrack(track)
                    }) {
                        if track.isPreloaded {
                            Image(systemName: "checkmark.icloud.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.appAccent)
                        } else if track.isPreloading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .appAccent))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "icloud.and.arrow.down")
                                .font(.system(size: 20))
                                .foregroundColor(.gray)
                        }
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
                .padding(.trailing, 8)
            }
            
            Image(systemName: "line.3.horizontal")
                .foregroundColor(.appAccent.opacity(0.4))
        }
        .padding(10)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .cornerRadius(24)
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color.appBorder, lineWidth: 1)
        )
        .contextMenu {
            if track.isDownloaded {
                Button(role: .destructive) {
                    manager.deleteTrackPermanently(track)
                } label: {
                    Label("Delete Permanently", systemImage: "trash")
                }
                
                Button(action: {
                    isShowingPhotoPicker = true
                }) {
                    Label("Change Cover", systemImage: "photo")
                }
                
                Button(action: {
                    showEditLyrics = true
                }) {
                    Label("Edit Lyrics", systemImage: "text.quote")
                }
            }
        }
        .sheet(isPresented: $showEditLyrics) {
            EditLyricsView(manager: manager, track: track)
        }
        .photosPicker(isPresented: $isShowingPhotoPicker, selection: $selectedPhotoItem, matching: .images, photoLibrary: .shared())
        .onChange(of: selectedPhotoItem) { newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self) {
                    manager.saveCustomCover(for: track, imageData: data)
                }
            }
        }
    }
}

struct SpinningVinyl: View {
    let track: Track
    @ObservedObject var manager: AudioPlayerManager
    
    @State private var rotation: Double = 0
    @State private var glowPulse: Bool = false
    
    // 60 FPS timer for smooth rotation tracking
    let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    
    var body: some View {
        let size: CGFloat = 26
        let isPlaying = manager.isPlaying
        
        ZStack {
            // Outer glow when playing
            Circle()
                .fill(Color.appAccent.opacity(isPlaying ? 0.25 : 0))
                .frame(width: size + 6, height: size + 6)
                .blur(radius: 4)
                .scaleEffect(glowPulse ? 1.15 : 1.0)
            
            // The record and its contents
            ZStack {
                // Vinyl disc base — dark with subtle sheen
                Circle()
                    .fill(
                        AngularGradient(
                            colors: [
                                Color(white: 0.08), Color(white: 0.14),
                                Color(white: 0.06), Color(white: 0.12),
                                Color(white: 0.05), Color(white: 0.13),
                                Color(white: 0.07), Color(white: 0.08)
                            ],
                            center: .center
                        )
                    )
                
                // Vinyl grooves — concentric rings
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                        .frame(width: size * (0.55 + CGFloat(i) * 0.12), height: size * (0.55 + CGFloat(i) * 0.12))
                }
                
                // Album art label in the center
                Group {
                    if let image = track.getCoverImage() {
                        image.resizable().scaledToFill()
                    } else if let url = track.coverURL {
                        AsyncImage(url: URL(string: url)) { phase in
                            if let img = phase.image {
                                img.resizable().scaledToFill()
                            } else {
                                Color.gray
                            }
                        }
                    } else {
                        Color.gray
                    }
                }
                .frame(width: size * 0.48, height: size * 0.48)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color(white: 0.2), lineWidth: 0.5))
                
                // Center spindle — metallic
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color(white: 0.45), Color(white: 0.15)],
                            center: .center,
                            startRadius: 0,
                            endRadius: size * 0.06
                        )
                    )
                    .frame(width: size * 0.12, height: size * 0.12)
                    .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 0.5))
                
                // Glossy light reflection — rotates with the disc
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.0), .white.opacity(0.12), .white.opacity(0.0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: size * 0.9, height: size * 0.15)
                    .rotationEffect(.degrees(45))
                    .blendMode(.screen)
            }
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1.5)
            .rotationEffect(.degrees(rotation))
        }
        .frame(width: size, height: size)
        .onReceive(timer) { _ in
            if manager.isPlaying {
                // Dynamic speed based on lyrics pacing
                var speedMultiplier = 1.0
                let idx = manager.currentLyricIndex
                if idx >= 0 && idx < manager.parsedLyrics.count {
                    let currentLine = manager.parsedLyrics[idx]
                    var duration = 3.0
                    
                    if idx + 1 < manager.parsedLyrics.count {
                        duration = manager.parsedLyrics[idx+1].timestamp - currentLine.timestamp
                    }
                    if duration < 0.5 { duration = 0.5 }
                    if duration > 10.0 { duration = 10.0 }
                    
                    let chars = Double(currentLine.text.count)
                    let cps = chars / duration // characters per second
                    
                    // Base cps around 15. Clamp between 0.4x and 2.5x speed
                    speedMultiplier = max(0.4, min(2.5, cps / 15.0))
                }
                
                // Spin forward by ~2.4 degrees per frame (2.5 sec per rotation) scaled by lyric speed
                rotation += (360.0 / (2.5 * 60.0)) * speedMultiplier
            }
        }
        .onAppear {
            if manager.isPlaying {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    glowPulse = true
                }
            }
        }
        .onChange(of: manager.isPlaying) { _, playing in
            if playing {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    glowPulse = true
                }
            } else {
                // Smart rollback to perfect straight orientation
                var targetRotation = floor(rotation / 360.0) * 360.0
                
                // If it's already too close to being straight, do an extra full backward spin for effect
                if rotation - targetRotation < 45 {
                    targetRotation -= 360.0
                }
                
                let distance = rotation - targetRotation
                let duration = max(0.5, (distance / 360.0) * 1.5)
                
                withAnimation(.easeOut(duration: duration)) {
                    rotation = targetRotation
                }
                
                withAnimation(.easeOut(duration: 0.5)) {
                    glowPulse = false
                }
            }
        }
    }
}

// MARK: - Mini Player (Liquid Glass Overhaul)
struct MiniPlayerView: View {
    @ObservedObject var manager: AudioPlayerManager
    
    var isAddedToPlaylist: Bool {
        guard let track = manager.currentTrack else { return false }
        return manager.playlist1Tracks.contains(where: { $0.id == track.id })
    }
    
    @State private var animatePlaylistIcon = false
    
    var body: some View {
        if let track = manager.currentTrack {
            VStack(spacing: 0) {
                HStack {
                    if let image = track.getCoverImage() {
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: 48, height: 48)
                            .cornerRadius(12)
                            .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
                    } else if let url = track.coverURL {
                        AsyncImage(url: URL(string: url)) { phase in
                            if let img = phase.image {
                                img.resizable().scaledToFill()
                            } else {
                                Color.gray
                            }
                        }
                        .frame(width: 48, height: 48)
                        .cornerRadius(12)
                        .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.system(size: 12, design: .rounded))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                    
                    Spacer()
                    
                    Button(action: {
                        if isAddedToPlaylist {
                            manager.removeFromPlaylist(track)
                        } else {
                            manager.addToPlaylist(track)
                        }
                        
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.5, blendDuration: 0.5)) {
                            animatePlaylistIcon = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation {
                                animatePlaylistIcon = false
                            }
                        }
                    }) {
                        Image(systemName: isAddedToPlaylist ? "checkmark.circle.fill" : "plus.circle")
                            .font(.system(size: 24))
                            .foregroundColor(isAddedToPlaylist ? .green : .white.opacity(0.7))
                            .scaleEffect(animatePlaylistIcon ? 1.3 : 1.0)
                    }
                    .padding(.trailing, 12)
                    
                    Button(action: {
                        manager.togglePlay()
                    }) {
                        Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .background(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .cornerRadius(30)
            .overlay(
                RoundedRectangle(cornerRadius: 30)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1) // Specular highlight border
            )
            .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 8)
        }
    }
}

// MARK: - Full Player Page (100% Liquid Glass Floating Card Overhaul)
struct PlayerPageView: View {
    @ObservedObject var manager: AudioPlayerManager
    @State private var isLyricsPresented = false
    
    // Stateful drag variables for the media scrubber
    @State private var isDragging: Bool = false
    @State private var dragProgress: Double = 0.0
    
    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }
    
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Album art background (no blur, fully visible)
                LyricsBackgroundView(track: manager.currentTrack, isAppleStyle: true, showCenteredAlbum: false).equatable()
                
                VStack(spacing: 0) {
                    // Top header row with collapse button
                    HStack {
                        Button(action: {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                manager.isPlayerExpanded = false
                            }
                        }) {
                            Image(systemName: "chevron.down")
                                .font(.title2.bold())
                                .foregroundColor(.white)
                                .padding(12)
                                .background(.ultraThinMaterial)
                                .environment(\.colorScheme, .dark)
                                .clipShape(Circle())
                                .overlay(
                                    Circle().stroke(Color.white.opacity(0.18), lineWidth: 1)
                                )
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, max(geo.safeAreaInsets.top, 59))
                    
                    Spacer(minLength: 0)
                    
                    // Floating glass card with extremely rounded corners, centered with padding
                    if let track = manager.currentTrack {
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            
                            // Cover art
                            let imageSize = min(geo.size.width * 0.7, geo.size.height * 0.32)
                            
                            if let image = track.getCoverImage() {
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: imageSize, height: imageSize)
                                    .cornerRadius(24)
                                    .shadow(color: .black.opacity(0.45), radius: 15, x: 0, y: 8)
                                    .shadow(color: .appAccent.opacity(0.12), radius: 24, x: 0, y: 0)
                            } else if let url = track.coverURL {
                                AsyncImage(url: URL(string: url)) { phase in
                                    if let img = phase.image {
                                        img.resizable().scaledToFill()
                                    } else {
                                        Color.gray
                                    }
                                }
                                .frame(width: imageSize, height: imageSize)
                                .cornerRadius(24)
                                .shadow(color: .black.opacity(0.45), radius: 15, x: 0, y: 8)
                                .shadow(color: .appAccent.opacity(0.12), radius: 24, x: 0, y: 0)
                            }
                            
                            Spacer(minLength: 0)
                            
                            // Titles
                            VStack(spacing: 6) {
                                Text(track.title)
                                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                                    .foregroundColor(.white)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                
                                Text(track.artist)
                                    .font(.system(size: 15, design: .rounded))
                                    .foregroundColor(Color.appTextSecondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 0)
                            
                            Spacer(minLength: 0)
                            
                            // Redesigned Media Scrubber: Elapsed, Custom Translucent Track & Solid Fill, Glass Thumb, Remaining
                            HStack(spacing: 12) {
                                let currentProgress = isDragging ? dragProgress : manager.playbackProgress
                                Text(formatTime(currentProgress))
                                    .font(.system(size: 13, weight: .semibold, design: .default).monospacedDigit())
                                    .foregroundColor(Color.white.opacity(0.6))
                                    
                                GeometryReader { sliderGeo in
                                    let ratio = manager.playbackDuration > 0 ? currentProgress / manager.playbackDuration : 0
                                    let thumbSize: CGFloat = 16
                                    
                                    ZStack(alignment: .leading) {
                                        // Translucent background track
                                        Capsule()
                                            .fill(Color.white.opacity(0.18))
                                            .frame(height: 6)
                                        
                                        // Solid fill track
                                        Capsule()
                                            .fill(Color.white)
                                            .frame(width: max(0, sliderGeo.size.width * ratio), height: 6)
                                        
                                        // Distinct circular thumb with a glass effect (inner shadow/border) positioned at end of white fill
                                        Circle()
                                            .fill(.ultraThinMaterial)
                                            .frame(width: thumbSize, height: thumbSize)
                                            .overlay(
                                                Circle()
                                                    .stroke(Color.white.opacity(0.65), lineWidth: 1)
                                            )
                                            .shadow(color: Color.black.opacity(0.35), radius: 3, x: 0, y: 1.5)
                                            .offset(x: max(0, min(sliderGeo.size.width * ratio - (thumbSize / 2), sliderGeo.size.width - thumbSize)))
                                    }
                                    .frame(height: 20)
                                    .contentShape(Rectangle())
                                    .gesture(
                                        DragGesture(minimumDistance: 0)
                                            .onChanged { value in
                                                isDragging = true
                                                let percentage = min(max(value.location.x / sliderGeo.size.width, 0), 1)
                                                dragProgress = percentage * manager.playbackDuration
                                            }
                                            .onEnded { value in
                                                let percentage = min(max(value.location.x / sliderGeo.size.width, 0), 1)
                                                manager.seek(to: percentage * manager.playbackDuration)
                                                isDragging = false
                                            }
                                    )
                                }
                                .frame(height: 20)
                                
                                Text("-" + formatTime(max(0, manager.playbackDuration - currentProgress)))
                                    .font(.system(size: 13, weight: .semibold, design: .default).monospacedDigit())
                                    .foregroundColor(Color.white.opacity(0.6))
                            }
                            .padding(.horizontal, 0)
                            
                            Spacer(minLength: 0)
                            
                            // Playback Controls (Play/Pause enclosed in prominent circular glass button, skip buttons borderless)
                            if manager.isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(1.5)
                                    .frame(height: 72)
                            } else {
                                // Enclosed Play/Pause Glass Button
                                Button(action: {
                                    manager.togglePlay()
                                }) {
                                    Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: 26, weight: .semibold))
                                        .foregroundColor(.white)
                                        .frame(width: 72, height: 72)
                                        .background(.ultraThinMaterial, in: Circle())
                                        .overlay(
                                            Circle().stroke(Color.white.opacity(0.25), lineWidth: 1)
                                        )
                                        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
                                }
                                .buttonStyle(BouncyButtonStyle())
                            }
                            
                            Spacer(minLength: 0)
                            
                            // Compact Lyric Preview Card (matching layout)
                            Button(action: {
                                isLyricsPresented = true
                            }) {
                                VStack(spacing: 5) {
                                    HStack {
                                        Image(systemName: "quote.bubble.fill")
                                            .font(.system(size: 12))
                                            .foregroundColor(.appAccent)
                                        Spacer()
                                    }
                                    let text = (manager.currentLyricIndex >= 0 && manager.currentLyricIndex < manager.parsedLyrics.count) ? manager.parsedLyrics[manager.currentLyricIndex].text.replacingOccurrences(of: "\n", with: " ") : "Lyrics"
                                    Text(text)
                                        .font(.system(size: 15, weight: .bold, design: .rounded))
                                        .foregroundColor(.white)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                }
                                .padding(14)
                                .background(.ultraThinMaterial)
                                .environment(\.colorScheme, .dark)
                                .cornerRadius(20)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 20)
                                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                                )
                            }
                            .buttonStyle(BouncyButtonStyle())
                            .padding(.horizontal, 0)
                            
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
                        .frame(maxWidth: .infinity)
                    }
                    
                    Spacer(minLength: 0)
                }
                .frame(width: geo.size.width)
                .padding(.bottom, max(geo.safeAreaInsets.bottom, 20))
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .fullScreenCover(isPresented: $isLyricsPresented) {
            LyricsView(manager: manager, isPresented: $isLyricsPresented)
        }
        .gesture(
            DragGesture().onEnded { value in
                if value.translation.height > 100 {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        manager.isPlayerExpanded = false
                    }
                }
            }
        )
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

struct BouncyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
