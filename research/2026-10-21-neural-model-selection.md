# Neural model selection in runtime 310.9.16

Verified 2026-10-21. This is research evidence, not a game modification or a claim of universal compatibility.

## Verified locally

The installed P.T. PC Port runtime at `C:/Users/<user>/AppData/Local/Programs/P.T. PC Port/data/dlss5-native/310.9.16/nvngx_dlssnr.dll` hashes to SHA-256 `2BC19BC09A7B89DD44F73E2AC0108FCC586E2154BDD0830F242F4F040E28789F`. Its install manifest identifies version 310.9.16 and the same hash.

The existing `data/pt.log` identifies RTX 4090, driver 616.92, and this runtime hash. It records successful feature-18 creation and evaluation with small and large networks at the same dimensions: 3413x1440 (small at 132.598/132.599 seconds, large at 177.620/177.623), and 5120x2160 (large at 345.376/345.379, small at 359.546/359.548). These are historical log observations, not a new benchmark. `data/pt.ini` currently contains `neural_model = small`, separate from `neural_quality = ultra`. The log identifies a compatibility companion and external sm_89 GPU code; this does not establish stock runtime support on RTX 40 without that layer.

## Primary-source findings

P.T. source inspected at commit `91f97f7c22e975767da41e9c977fd7a5e85a7102`:

- [UI labels and help](https://github.com/LoreanXavier/pt-pc/blob/91f97f7c22e975767da41e9c977fd7a5e85a7102/src/game/ui/pc_settings.cpp#L392): "New model (small)" and "Old model (large)". Help describes the small model as faster and the large model as reconstructing finer detail; model and quality are independent. This corroborates the user's visual observation but is not an independent image-quality measurement.
- [Configuration](https://github.com/LoreanXavier/pt-pc/blob/91f97f7c22e975767da41e9c977fd7a5e85a7102/src/engine/platform/settings.cpp#L139): `upscaling.neural_model` accepts `small` or `large`, with invalid input falling back to `small`. Serialization documents no automatic model downgrade.
- [D3D12 creation and model switching](https://github.com/LoreanXavier/pt-pc/blob/91f97f7c22e975767da41e9c977fd7a5e85a7102/src/engine/render/d3d12/backend/d3d12_neural.cpp#L254): sets unsigned `DLSSNR.Hint.Render.Preset` before creating feature 18. The initial creation uses `0x80000000` for small and `1` for large. The initial companion fallback instead sets `0x80000000` for small and `0x80000001` for large. `PT_NR_PRESET` overrides only that fallback block. Subsequent preparation resets parameters and uses the first pair, even when the companion is already loaded. Do not flatten these paths into a universal numeric mapping.
- In that backend, a changed `neural_small_model` calls `Prepare`, which waits for idle, releases the existing feature, resets parameters, and creates a replacement. The switch is a creation-time control, not merely an evaluate-time style change.

[NVIDIA's October 13 announcement](https://www.nvidia.com/en-us/geforce/news/dlss-5-faster-ai-model-hogwarts-legacy-rtx-spark-laptops/) independently describes an October model with a 24% smaller parameter footprint, roughly 118 million parameters, half the GPU overhead and 20% lower 4K VRAM use, with comparable visual fidelity. Those are vendor claims for its supported context, not measured results on this RTX 4090. The article does not establish this DLL's internal model count or document the preset mapping above.

Conclusion: two selectable model paths in this runtime are corroborated by source and successful local evaluations. Calling them old/large and new/small follows P.T.'s labels. Exactly two total embedded networks, binary identity of the old network with 310.8, measured speedup, and a universal detail penalty have not been established by binary analysis or controlled comparisons.

## Applying selection to other games

The concrete integration point is the unsigned `DLSSNR.Hint.Render.Preset` NGX parameter before feature-18 creation. A caller or an NGX proxy that controls that parameter is a candidate for exposing model selection. It should treat runtime version, preset acceptance and model identity as things to verify per integration; changing the DLL alone does not explicitly select a model. P.T.'s `neural_model` key and `PT_NR_PRESET` environment variable are application-specific, not demonstrated global NVIDIA controls.

[Cost Scaler source at efe2ed6a2536c64b74ffa431df42d223a58e9761](https://github.com/xenmods/DLSSNR-Cost-Scaler/blob/efe2ed6a2536c64b74ffa431df42d223a58e9761/proxy_main.cpp#L1002) forwards the incoming feature ID and parameter pointer to the real D3D12 create export. Its [complete INI at that revision](https://github.com/xenmods/DLSSNR-Cost-Scaler/blob/efe2ed6a2536c64b74ffa431df42d223a58e9761/nvngx_dlssnr.ini) exposes scale and style controls but no model/preset override; `proxy_main.cpp` contains no preset handling. It is therefore a possible place to implement a creation-time override, not a current ready-made selector. Other add-ons and Remix were not audited for current model controls in this investigation.

A future game-specific experiment should preserve a known-good runtime and configuration, capture the actual creation preset, compare small and large at equal resolution and tuning, recreate all affected cached features when the model changes, and measure neural GPU time plus matched images. Unsupported presets or failed creation must retain the known-good route rather than silently claiming that a model was selected. No other game was modified or tested here.
