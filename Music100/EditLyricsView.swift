import SwiftUI

struct EditLyricsView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var manager: AudioPlayerManager
    let track: Track
    
    @State private var selectedType = "enhanced.lrc"
    @State private var lrcContent = ""
    @State private var enhancedLrcContent = ""
    @State private var showSaveAlert = false
    
    let types = ["lrc", "enhanced.lrc"]
    
    var body: some View {
        NavigationStack {
            VStack {
                Picker("Lyrics Type", selection: $selectedType) {
                    Text("Standard (.lrc)").tag("lrc")
                    Text("Enhanced (.enhanced.lrc)").tag("enhanced.lrc")
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()
                
                TextEditor(text: Binding(
                    get: { selectedType == "lrc" ? lrcContent : enhancedLrcContent },
                    set: { newValue in
                        if selectedType == "lrc" {
                            lrcContent = newValue
                        } else {
                            enhancedLrcContent = newValue
                        }
                    }
                ))
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .background(Color(.systemBackground).opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal)
            }
            .navigationTitle("Edit Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        saveLyrics()
                        showSaveAlert = true
                    }
                    .fontWeight(.bold)
                }
                
                ToolbarItem(placement: .bottomBar) {
                    if selectedType == "lrc" {
                        Button(action: {
                            enhancedLrcContent = LRCParser.synthesizeWordTimestamps(from: lrcContent)
                            selectedType = "enhanced.lrc"
                        }) {
                            Label("Sync to Enhanced", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                }
            }
            .alert("Saved", isPresented: $showSaveAlert) {
                Button("OK", role: .cancel) {
                    dismiss()
                }
            } message: {
                Text("Lyrics have been updated.")
            }
            .onAppear {
                loadLyrics()
            }
        }
        .preferredColorScheme(.dark)
    }
    
    private func loadLyrics() {
        if let lrc = manager.getRawLyrics(for: track, type: "lrc") {
            lrcContent = lrc
        }
        if let enhanced = manager.getRawLyrics(for: track, type: "enhanced.lrc") {
            enhancedLrcContent = enhanced
        }
    }
    
    private func saveLyrics() {
        manager.saveRawLyrics(for: track, type: "lrc", content: lrcContent)
        manager.saveRawLyrics(for: track, type: "enhanced.lrc", content: enhancedLrcContent)
    }
}
