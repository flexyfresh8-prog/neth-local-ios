# Neth Local

Neth Local runs GGUF models on the iPad with llama.cpp. It downloads the HauhauCS Qwen3.5 4B Uncensored Q4_K_M checkpoint and an optional vision projector from Hugging Face. Both downloads are pinned to a specific revision and checked by SHA-256 before installation. Chat and photo inference run on-device.

## Build

Run **Build iPad IPAs** in GitHub Actions and download the **NethLocal-iPad** artifact. For a local build on macOS with Xcode and the iPhoneOS SDK, run `bash scripts/build-ipa.sh`. The same files are written to `out/`.

For Impactor choose `NethLocal-Impactor.ipa`, select **Signing → Apple ID**, leave the custom **Entitlements** field empty, and click **Install**. The app executable carries the Increased Memory Limit and Extended Virtual Addressing requests for Impactor to discover. Apple's provisioning profile determines which capabilities the signed app receives. The build also includes an unsigned package and the entitlement plist for other signing workflows. Both packages target ARM64 on iPadOS 18 and later. [Apple’s Increased Memory Limit documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit)

## Run a model

1. Open **Models** and download **Qwen3.5 4B Uncensored**. The download is 2.71 GB.
2. Close **Models** and send a message. The default context is 4K, with settings from 512 tokens to 16K. Qwen can use a Q8 attention cache for larger windows. Available memory can reduce the active window, which the chat header shows along with the compute backend.
3. To attach a photo, download **Qwen vision projector** (676 MB) and use the photo button next to the message field. Photo inference needs more memory than text chat. Text and still images are supported.

Use **Import GGUF** to add other decoder models with a llama.cpp-supported architecture and chat template. [Qwen checkpoint and license](https://huggingface.co/HauhauCS/Qwen3.5-4B-Uncensored-HauhauCS-Aggressive)

## Search, copy and history

Enable **Web** for the next message to send a search query to DuckDuckGo, with Bing RSS as a fallback. The app passes compact snippets to the local model and shows clickable sources below its reply. The app sends the current query to the search provider. Chat history and photos stay with local inference.

Use **Copy** on a code block or **Copy reply** for the full answer. The sidebar saves conversations on disk, and **Search chats** can jump to earlier messages. The engine can recall matching excerpts from earlier in the current conversation.

Model weights use file-backed memory mapping. The database stores and searches older turns. The active context and attention cache still use device memory.
