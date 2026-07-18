import SwiftUI

struct LyricsView: View {
    @ObservedObject var manager: AudioPlayerManager
    @Binding var isPresented: Bool
    
    @State private var isAppleStyle: Bool = true
    @State private var showCenteredAlbum: Bool = false
    @State private var isUserScrolling = false
    @State private var lastInteractionTime: Date = Date()
    @State private var showBottomControls: Bool = true
    
    var body: some View {
        VStack(spacing: 0) {
            // Top row styled with liquid glass elements
            HStack {
                Button(action: {
                    withAnimation(.easeOut(duration: 0.5)) {
                        isPresented = false
                    }
                }) {
                    Image(systemName: "chevron.down")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                        .environment(\.colorScheme, .dark)
                        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1)) // Specular Highlight Border
                        .padding(12)
                        .contentShape(Rectangle())
                }
                
                if let track = manager.currentTrack {
                    if let image = track.getCoverImage() {
                        image.resizable().scaledToFill().frame(width: 40, height: 40).cornerRadius(12)
                            .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
                    } else if let url = track.coverURL {
                        AsyncImage(url: URL(string: url)) { phase in
                            if let img = phase.image {
                                img.resizable().scaledToFill()
                            } else { Color.gray }
                        }.frame(width: 40, height: 40).cornerRadius(12)
                            .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(.white).lineLimit(1)
                        Text(track.artist).font(.system(size: 12, design: .rounded)).foregroundColor(Color.appTextSecondary).lineLimit(1)
                    }
                    .padding(.leading, 4)
                }
                
                Spacer()
            }
            .padding(.top, 10)
            
            // Lyrics ScrollView
            ZStack(alignment: .bottom) {
                GeometryReader { geometry in
                    ScrollViewReader { proxy in
                        ScrollView(showsIndicators: false) {
                            LazyVStack(alignment: isAppleStyle ? .center : .leading, spacing: isAppleStyle ? 36 : 24) {
                                Color.clear.frame(height: geometry.size.height * 0.4)
                                
                                ForEach(Array(manager.parsedLyrics.enumerated()), id: \.offset) { index, lyric in
                                    let effectiveActiveIndex = max(0, manager.currentLyricIndex)
                                    let isActive = index == effectiveActiveIndex
                                    let isPast = index < effectiveActiveIndex
                                    let dist = abs(index - effectiveActiveIndex)
                                    
                                    let lyricView: some View = {
                                        if manager.isKaraokeMode, let words = lyric.words, isActive {
                                            let spaceWidth = (" " as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: isAppleStyle ? 28 : 22, weight: .heavy)]).width
                                            return AnyView(
                                                FlowLayout(spacing: spaceWidth, alignment: isAppleStyle ? .center : .leading) {
                                                    ForEach(Array(words.enumerated()), id: \.offset) { wIndex, word in
                                                        let nextTimestamp = (wIndex + 1 < words.count) ? words[wIndex + 1].timestamp : (index + 1 < manager.parsedLyrics.count ? manager.parsedLyrics[index + 1].timestamp : word.timestamp + 1.0)
                                                        let duration = max(nextTimestamp - word.timestamp, 0.1)
                                                        KaraokeWordView(word: word.text, startTime: word.timestamp, duration: duration, playbackProgress: manager.playbackProgress, style: manager.karaokeMode)
                                                    }
                                                }
                                            )
                                        } else {
                                            return AnyView(Text(lyric.text))
                                        }
                                    }()
                                    
                                    lyricView
                                        .font(.system(size: isAppleStyle ? 28 : 22, weight: isActive || (!isAppleStyle && isPast) ? .heavy : .bold, design: .rounded))
                                        .foregroundColor(isActive || (!isAppleStyle && isPast) ? .white : Color(white: 1.0, opacity: isAppleStyle ? 0.6 : 0.5))
                                        .multilineTextAlignment(isAppleStyle ? .center : .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(.horizontal, 24)
                                        .scaleEffect(isAppleStyle ? (isActive ? 1.05 : (dist == 1 ? 0.95 : 1.0)) : 1.0)
                                        .opacity(isAppleStyle ? (isActive ? 1.0 : (isUserScrolling ? 0.7 : (dist == 1 ? 0.5 : (dist == 2 ? 0.35 : 0.25)))) : 1.0)
                                        .blur(radius: isAppleStyle && !isActive && !isUserScrolling ? CGFloat(min(dist, 4)) * 0.8 : 0)
                                        .frame(maxWidth: .infinity, alignment: isAppleStyle ? .center : .leading)
                                        .id(index)
                                        .onTapGesture {
                                            manager.seek(to: lyric.timestamp)
                                            isUserScrolling = false
                                            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                                                proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.4))
                                            }
                                        }
                                }
                                
                                Color.clear.frame(height: geometry.size.height / 2)
                            }
                            .padding(.horizontal)
                        }
                        .simultaneousGesture(
                            DragGesture().onChanged { value in
                                isUserScrolling = true
                                lastInteractionTime = Date()
                            }
                        )
                        .onChange(of: manager.currentLyricIndex) { oldValue, newValue in
                            if isUserScrolling && Date().timeIntervalSince(lastInteractionTime) > 3.0 {
                                isUserScrolling = false
                            }
                            
                            if !isUserScrolling {
                                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                                    proxy.scrollTo(newValue, anchor: UnitPoint(x: 0.5, y: 0.4))
                                }
                            }
                        }

                    }
                }
                
                // Bottom controls: Play/pause left, Settings pill centered, collapse toggle (animates to center)
                ZStack(alignment: .bottom) {
                    // The collapsible controls (play button + settings pill) — always rendered, toggled via opacity
                    HStack(alignment: .center) {
                        // Play/pause - enclosed in circular glass with specular border
                        Button(action: {
                            manager.togglePlay()
                        }) {
                            Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                                .environment(\.colorScheme, .dark)
                                .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
                                .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
                        }
                        .buttonStyle(BouncyButtonStyle())
                        
                        Spacer()
                        
                        // Settings pill - centered with high specular highlight border
                        HStack(spacing: 20) {
                            Button(action: {
                                isAppleStyle.toggle()
                            }) {
                                Image(systemName: "quote.bubble.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(isAppleStyle ? .white : Color.appTextSecondary)
                            }
                            
                            Toggle("", isOn: $showCenteredAlbum)
                                .labelsHidden()
                                .toggleStyle(IOS26ToggleStyle())
                            
                            Button(action: {
                                manager.karaokeMode = (manager.karaokeMode + 1) % 3
                            }) {
                                Image(systemName: "mic.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(manager.karaokeMode == 2 ? Color.appAccent : (manager.karaokeMode == 1 ? Color(hex: "#FFB347") : .white))
                                    .opacity(manager.karaokeMode > 0 ? 1.0 : 0.5)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .environment(\.colorScheme, .dark)
                        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
                        
                        Spacer()
                        
                        // Balancing spacer to keep the settings pill centered against the play button
                        Color.clear.frame(width: 44, height: 44)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .offset(y: showBottomControls ? 0 : 80)
                    .opacity(showBottomControls ? 1 : 0)
                    .allowsHitTesting(showBottomControls)
                    
                    // Collapse/expand chevron — slides to center when collapsed, right-aligned when expanded
                    HStack {
                        if showBottomControls {
                            Spacer()
                        }
                        
                        Button(action: {
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                                showBottomControls.toggle()
                            }
                        }) {
                            Image(systemName: showBottomControls ? "chevron.right" : "chevron.left")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white.opacity(showBottomControls ? 0.6 : 0.85))
                                .frame(width: 44, height: 44)
                                .background(.ultraThinMaterial, in: Circle())
                                .environment(\.colorScheme, .dark)
                                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                                .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
                        }
                        .buttonStyle(BouncyButtonStyle())
                        
                        if !showBottomControls {
                            Spacer()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
            }
        }
        .background(
            LyricsBackgroundView(track: manager.currentTrack, isAppleStyle: isAppleStyle, showCenteredAlbum: showCenteredAlbum).equatable()
        )
        .gesture(
            DragGesture().onEnded { value in
                if value.translation.height > 100 {
                    withAnimation(.easeOut(duration: 0.5)) {
                        isPresented = false
                    }
                }
            }
        )
    }
}

struct LyricsBackgroundView: View, Equatable {
    let track: Track?
    let isAppleStyle: Bool
    let showCenteredAlbum: Bool
    
    var body: some View {
        ZStack {
            if let track = track {
                let isDrake = (track.artist.lowercased().contains("drake") || track.title.localizedCaseInsensitiveContains("Which One") || track.title.localizedCaseInsensitiveContains("Whisper My Name")) && !track.title.localizedCaseInsensitiveContains("first person shooter")
                let showBlur = isAppleStyle || isDrake
                
                if showCenteredAlbum {
                    let isDark = (track.getUIImage()?.averageBrightness ?? 1.0) < 0.3
                    Color.black
                    
                    // Slightly lighter (+0.04) as requested
                    let imageOpacity = isDark ? 0.59 : 0.44
                    
                    if let image = track.getCoverImage() {
                        image.resizable()
                            .scaledToFit()
                            .opacity(imageOpacity)
                    } else if let url = track.coverURL {
                        AsyncImage(url: URL(string: url)) { phase in
                            if let img = phase.image {
                                img.resizable()
                                    .scaledToFit()
                                    .opacity(imageOpacity)
                            } else { Color.black }
                        }
                    }
                } else if showBlur {
                    Color.black
                    
                    if let image = track.getCoverImage() {
                        image.resizable().scaledToFill().blur(radius: 40, opaque: true).drawingGroup().overlay(Color.black.opacity(0.55))
                    } else if let url = track.coverURL {
                        AsyncImage(url: URL(string: url)) { phase in
                            if let img = phase.image {
                                img.resizable().scaledToFill().blur(radius: 40, opaque: true).drawingGroup().overlay(Color.black.opacity(0.55))
                            } else { Color.black }
                        }
                    }
                } else {
                    Color.black
                }
            } else {
                Color.black
            }
        }
        .clipped()
        .ignoresSafeArea()
    }
    
    static func == (lhs: LyricsBackgroundView, rhs: LyricsBackgroundView) -> Bool {
        return lhs.track?.id == rhs.track?.id &&
               lhs.isAppleStyle == rhs.isAppleStyle &&
               lhs.showCenteredAlbum == rhs.showCenteredAlbum
    }
}

struct IOS26ToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Capsule()
            .fill(configuration.isOn ? Color.appAccent : Color.gray.opacity(0.3))
            .frame(width: 54, height: 32)
            .overlay(
                Capsule()
                    .fill(Color.white)
                    .frame(width: 26, height: 24)
                    .offset(x: configuration.isOn ? 11 : -11)
                    .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isOn)
            .onTapGesture {
                configuration.isOn.toggle()
            }
    }
}

struct KaraokeWordView: View {
    let word: String
    let startTime: Double
    let duration: Double
    let playbackProgress: Double
    let style: Int
    
    private var ratio: Double {
        let isPast = playbackProgress >= startTime + duration
        let isFuture = playbackProgress < startTime
        
        if style == 1 {
            return playbackProgress >= startTime ? 1.0 : 0.0
        } else {
            let rawRatio = (playbackProgress - startTime) / duration
            return isPast ? 1.0 : (isFuture ? 0.0 : rawRatio)
        }
    }
    
    var body: some View {
        Text(word)
            .foregroundColor(Color(white: 1.0, opacity: 0.6))
            .overlay(
                Text(word)
                    .foregroundColor(.white)
                    .shadow(color: style == 2 ? Color.appAccent.opacity(0.5) : Color.clear, radius: 6, x: 0, y: 0)
                    .mask(
                        GeometryReader { geo in
                            Rectangle()
                                .frame(width: geo.size.width * CGFloat(ratio))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .animation(style == 2 ? .linear(duration: 0.1) : nil, value: ratio)
                        }
                    )
            )
            .animation(.linear(duration: 0.1), value: ratio)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var alignment: HorizontalAlignment = .center
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (UIScreen.main.bounds.width - 48)
        let result = FlowResult(in: width, subviews: subviews, spacing: spacing, alignment: alignment)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing, alignment: alignment)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var points: [CGPoint] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat, alignment: HorizontalAlignment) {
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0
            var rowStartIdx = 0
            
            for (index, subview) in subviews.enumerated() {
                let size = subview.sizeThatFits(.unspecified)
                if currentX + size.width > maxWidth && currentX > 0 {
                    if alignment == .center {
                        let offset = (maxWidth - (currentX - spacing)) / 2
                        for i in rowStartIdx..<index {
                            points[i].x += max(0, offset)
                        }
                    }
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                    rowStartIdx = index
                }
                points.append(CGPoint(x: currentX, y: currentY))
                currentX += size.width + spacing
                lineHeight = max(lineHeight, size.height)
            }
            if currentX > 0 && alignment == .center {
                let offset = (maxWidth - (currentX - spacing)) / 2
                for i in rowStartIdx..<subviews.count {
                    points[i].x += max(0, offset)
                }
            }
            size = CGSize(width: maxWidth, height: currentY + lineHeight)
        }
    }
}
