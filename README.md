# Neth Local

Neth Local runs GGUF models on the iPad with llama.cpp. It downloads the HauhauCS Qwen3.5 4B Uncensored Q4_K_M checkpoint and an optional vision projector from Hugging Face. Both downloads are pinned to a specific revision and checked by SHA-256 before installation. Chat and photo inference run on-device.

## Build

Run **Build unsigned iPad IPA** in GitHub Actions. Download and extract the **NethLocal-iPad-unsigned** artifact. For a local build on macOS with Xcode and the iPhoneOS SDK, run `bash scripts/build-ipa.sh`. The script writes the same files to `out/`.

The IPA contains an ARM64 iPad app for iPadOS 18 or later. Sign the app and its embedded framework before installing. The build artifact includes `NethLocal.entitlements` beside the IPA and in the app bundle. Pass that file to a signer that can request the Increased Memory Limit and Extended Virtual Addressing capabilities. The signed app’s provisioning and iPadOS determine whether those capabilities take effect. [Apple’s Increased Memory Limit documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit)

## Run a model

1. Open **Models** and download **Qwen3.5 4B Uncensored**. The download is 2.71 GB.
2. Close **Models** and send a message. The default 1,024-token context uses Metal when the iPad reports enough memory for offload and falls back to memory-mapped CPU inference. **Models** also offers 512-token and 2,048-token contexts, a **CPU only** switch, and **Thinking mode**.
3. To attach a photo, download **Qwen vision projector** (676 MB) and use the photo button next to the message field. Photo inference needs more memory than text chat. Text and still images are supported.

Use **Import GGUF** to add other decoder models with a llama.cpp-supported architecture and chat template. [Qwen checkpoint and license](https://huggingface.co/HauhauCS/Qwen3.5-4B-Uncensored-HauhauCS-Aggressive)
