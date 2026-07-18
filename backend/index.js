const express = require('express');
const cors = require('cors');
const { exec } = require('child_process');
const axios = require('axios');

const app = express();
app.use(cors());

// Mutex / Queue for yt-dlp to prevent OOM
class AsyncQueue {
    constructor() {
        this.queue = [];
        this.isProcessing = false;
    }

    async enqueue(task) {
        return new Promise((resolve, reject) => {
            this.queue.push(async () => {
                try {
                    const result = await task();
                    resolve(result);
                } catch (err) {
                    reject(err);
                }
            });
            this.process();
        });
    }

    async process() {
        if (this.isProcessing || this.queue.length === 0) return;
        this.isProcessing = true;
        const task = this.queue.shift();
        try {
            await task();
        } finally {
            this.isProcessing = false;
            this.process();
        }
    }
}

const ytQueue = new AsyncQueue();

// Helper to run yt-dlp
function runYtDlp(query) {
    return new Promise((resolve, reject) => {
        // We use %()s to get artist, title, thumbnail, and the final line is the URL due to --get-url
        const command = `yt-dlp "ytmsearch1:${query}" -f "bestaudio[ext=m4a]/bestaudio" --get-url --print "%(artist)s|%(title)s|%(thumbnail)s" --no-warnings --force-ipv4`;
        
        exec(command, (error, stdout, stderr) => {
            if (error) {
                return reject(error);
            }
            
            // Expected stdout:
            // Artist|Title|Thumbnail_URL
            // Audio_URL
            const lines = stdout.trim().split('\n').filter(l => l.trim().length > 0);
            if (lines.length < 2) {
                return reject(new Error('Failed to parse yt-dlp output'));
            }
            
            const metadataLine = lines[lines.length - 2];
            const audioUrl = lines[lines.length - 1];
            const parts = metadataLine.split('|');
            
            resolve({
                artist: parts[0] || 'Unknown Artist',
                title: parts[1] || 'Unknown Title',
                thumbnail: parts[2] || '',
                audioUrl: audioUrl
            });
        });
    });
}

// Fetch iTunes Artwork
async function getITunesArtwork(artist, title) {
    try {
        const term = encodeURIComponent(`${artist} ${title}`);
        const response = await axios.get(`https://itunes.apple.com/search?term=${term}&entity=song&limit=1`);
        if (response.data.results && response.data.results.length > 0) {
            let coverUrl = response.data.results[0].artworkUrl100;
            // Upgrade to 1000x1000 square
            if (coverUrl) {
                return coverUrl.replace('100x100bb', '1000x1000bb');
            }
        }
    } catch (e) {
        console.error('iTunes fetch error:', e.message);
    }
    return null;
}

// Fetch Synced Lyrics from LRCLIB
async function getLRCLIBLyrics(artist, title) {
    try {
        const response = await axios.get(`https://lrclib.net/api/search`, {
            params: { track_name: title, artist_name: artist }
        });
        if (response.data && response.data.length > 0) {
            // Find first one with synced lyrics
            const match = response.data.find(t => t.syncedLyrics);
            if (match) {
                return match.syncedLyrics;
            }
        }
    } catch (e) {
        console.error('LRCLIB fetch error:', e.message);
    }
    return "";
}

app.get('/api/track/load', async (req, res) => {
    const { query } = req.query;
    if (!query) return res.status(400).json({ error: 'Missing query parameter' });

    try {
        // Enqueue extraction to prevent OOM
        const ytData = await ytQueue.enqueue(() => runYtDlp(query));
        
        // Parallel enrichment
        const [itunesArt, syncedLyrics] = await Promise.all([
            getITunesArtwork(ytData.artist, ytData.title),
            getLRCLIBLyrics(ytData.artist, ytData.title)
        ]);

        const finalCover = itunesArt || ytData.thumbnail;

        // Note: the audioUrl is often bound to IP/Session, so passing it back 
        // to iOS might work, but proxy streaming is more robust.
        // We will return a proxy URL pointing to our own stream endpoint.
        // We URL-encode the real audioUrl so the client can pass it back.
        const proxyStreamUrl = `/api/track/stream?url=${encodeURIComponent(ytData.audioUrl)}`;

        res.json({
            artist: ytData.artist,
            title: ytData.title,
            coverUrl: finalCover,
            audioUrl: ytData.audioUrl, // Direct URL
            proxyUrl: proxyStreamUrl,  // Proxy URL
            lyrics: syncedLyrics
        });

    } catch (error) {
        console.error('Load Error:', error);
        res.status(500).json({ error: 'Failed to extract track' });
    }
});

// Proxy streaming endpoint - prevents Cloudflare Tunnels from breaking AVPlayer range requests
app.get('/api/track/stream', async (req, res) => {
    const targetUrl = req.query.url;
    if (!targetUrl) return res.status(400).send('Missing url');

    try {
        const range = req.headers.range;
        const headers = {};
        if (range) {
            headers['Range'] = range;
        }

        const response = await axios({
            method: 'GET',
            url: targetUrl,
            headers: headers,
            responseType: 'stream',
            validateStatus: status => status >= 200 && status < 400
        });

        // Explicitly set headers to pass safely through Cloudflare Tunnel
        res.setHeader('Accept-Ranges', 'bytes');
        if (response.headers['content-type']) {
            res.setHeader('Content-Type', response.headers['content-type']);
        }
        if (response.headers['content-length']) {
            res.setHeader('Content-Length', response.headers['content-length']);
        }
        if (response.headers['content-range']) {
            res.setHeader('Content-Range', response.headers['content-range']);
        }
        
        // Proxy status code (200 or 206)
        res.status(response.status);
        response.data.pipe(res);

    } catch (error) {
        console.error('Stream proxy error:', error.message);
        res.status(500).send('Proxy error');
    }
});

app.get('/api/search', async (req, res) => {
    const { q } = req.query;
    if (!q) return res.json([]);
    try {
        const term = encodeURIComponent(q);
        const response = await axios.get(`https://itunes.apple.com/search?term=${term}&entity=song&limit=15`);
        if (response.data.results) {
            const results = response.data.results.map(item => ({
                id: item.trackId,
                title: item.trackName,
                artist: item.artistName,
                coverUrl: item.artworkUrl100 ? item.artworkUrl100.replace('100x100bb', '1000x1000bb') : null
            }));
            res.json(results);
        } else {
            res.json([]);
        }
    } catch (e) {
        console.error('Search error:', e.message);
        res.status(500).json({ error: 'Search failed' });
    }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
    console.log(`Music100 proxy backend listening on port ${PORT}`);
});
