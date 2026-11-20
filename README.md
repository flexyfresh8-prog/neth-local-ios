# Neth Local

Neth Local runs GGUF models on the iPad with llama.cpp. It downloads the HauhauCS Qwen3.5 4B Uncensored Q4_K_M checkpoint and an optional vision projector from Hugging Face. Both downloads are pinned to a specific revision and checked by SHA-256 before installation. The app supports local inference and shared text inference with a paired Windows computer.

## Build

Run **Build Neth Local apps** in GitHub Actions. Download **NethLocal-iPad** for the IPAs and **NethLocal-Windows** for the standalone Windows companion. For a local iPad build on macOS with Xcode, CMake, and Python 3.12 or newer, run `bash scripts/build-ipa.sh`. The IPAs are written to `out/`.

Both IPA filenames include the app version. For Impactor choose `NethLocal-v<version>-Impactor.ipa`, select **Signing → Apple ID**, leave the custom **Entitlements** field empty, and click **Install**. The app executable carries the Increased Memory Limit and Extended Virtual Addressing requests for Impactor to discover. Apple's provisioning profile determines which capabilities the signed app receives. The build also includes an unsigned package and the entitlement plist for other signing workflows. Both packages target ARM64 on iPadOS 18 and later. [Apple’s Increased Memory Limit documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit)

## Run a model

1. Open **Models** and download **Qwen3.5 4B Uncensored**. The download is 2.71 GB.
2. Close **Models** and send a message. **Settings → Inference** offers context requests from 512 to 131,072 tokens. Select Automatic, Q4, Q8 or F16 cache precision. The header reports the active window, cache and backend after the engine allocates memory.
3. To attach a photo, download **Qwen vision projector** (676 MB) and use the photo button next to the message field. Photo inference needs more memory than text chat. Text and still images are supported.

Use **Import GGUF** to add other decoder models with a llama.cpp-supported architecture and chat template. [Qwen checkpoint and license](https://huggingface.co/HauhauCS/Qwen3.5-4B-Uncensored-HauhauCS-Aggressive)

## Share Qwen with Windows

1. Run **NethLocal-Windows-v3.6.1.exe** on Windows 11 x64 and choose **Download model**. Download the bundled Qwen3.5 4B in the iPad app as well.
2. In the Windows companion, open **Mobile Hotspot settings**. Set **Share over** to **Wi-Fi** and **Network band** to **5 GHz**. Turn on Mobile Hotspot, then choose **Start server**. The companion checks the selected band and listens on the hotspot adapter.
3. Join the Windows hotspot on the iPad. In Neth Local, open **Models & context → Compute device → Pair Windows device**. Scan the QR code from the Windows app or paste its pairing code, then allow Local Network access. The Windows computer appears by name in the device list.
4. Select the Windows computer and send a text prompt. **Layers on Windows** controls how many of the first 32 Qwen layers run on the laptop CPU. The iPad runs the remaining layers and samples the response. Check the composer for the measured token rate and use **This iPad** for a local comparison.

Both devices read their own copy of the same model. The shared link carries token IDs and intermediate activations over TLS. The iPad verifies the certificate from the pairing code. Treat the QR code and the copied pairing code as credentials. Shared mode supports text and up to 32K context. Local mode supports photos and prompt checkpoints. The Windows companion uses an AVX2-capable x64 CPU. Single-reply speed depends on the two devices and network latency.

## Search, copy and history

Enable **Web** for the next message to send a search query to DuckDuckGo, with Bing RSS as a fallback. The app passes compact snippets to the model and shows clickable sources below its reply. The app sends the current query to the search provider. The history database and photos are stored on the iPad. A shared reply sends the text context as token IDs to the paired laptop.

Use **Copy** on a code block or **Copy reply** for the full answer. The sidebar saves conversations on disk, and **Search chats** can jump to earlier messages. The engine can recall matching excerpts from earlier in the current conversation.

Model weights use file-backed memory mapping. The database stores transcripts and incremental excerpts of older turns. **Compact older chat turns** adds a short digest to the prompt. The active attention cache uses device memory.

**Models & context → Prompt checkpoints** controls prompt reuse for text chats with the bundled Qwen model. **RAM + storage** keeps the matching prefix warm during chat, tool planning and continuation. When switching chats or leaving the app, it can save a checkpoint of at least 1,024 prompt tokens. Checkpoints must match the model, runtime configuration and prompt tokens. The app rebuilds the prompt when the checkpoint is missing or incompatible. The device can reclaim these cache files, and deleting a chat also deletes its checkpoints.

Use **Save checkpoint and unload model** to test a restore. After generating in a long chat, unload, then continue the reply or ask a follow-up. The settings show whether that pass used **Storage**, **RAM** or **Rebuilt**, how many tokens it reused, the prefill time, and the time to first token after loading the model. Compare with **RAM only** or **Rebuild every pass**. **Clear saved checkpoints** frees storage used by this cache.

## Quattro and effort

Enable **Quattro** in the main composer. It can choose tools for calculations, text and data transforms, dates, conversions, and search. The catalog distinguishes general actions from specific unit conversions. Choose an entry in **Quattro tools** to put an editable command in the composer. Use **Web** to send the current query to the search provider.

Use the **Effort** menu to choose Quick, Balanced, Deep or Max. The bar shows the current phase and step. If a reply hits a token or context limit, the app can continue from a bounded trailing excerpt. Tap **Continue** to resume a saved reply after stopping or reaching the effort limit.

Tap **Files** and describe a file or project, or type `/file Notes.pdf Summarize the topic ...`. Quattro plans the files, saves them inside the conversation and creates a ZIP for multi-file projects. Open file cards for a preview or use Share to save them to Files. **Save as file** on an existing answer also supports Markdown, text and PDF.
