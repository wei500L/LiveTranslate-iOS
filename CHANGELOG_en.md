# Changelog

## 2026-09-07 (round 22)

On-device offline translation model support: default offline translation (Hy-MT2), an optional battery-saver model (MiLMMT), a standalone image-understanding model (Gemma 4 E2B), and an Apple system-translation fallback.

- **Offline translation (default)**: Hy-MT2-1.8B Q4_K_M (~1.13 GB, Apache-2.0) translates Russian → Simplified Chinese entirely on-device via llama.cpp — fully usable with no network; the classroom pipeline no longer enters the offline pause state while a local provider is selected. Enabled by default for new users; existing users with a configured cloud API keep cloud.
- **Battery-saver mode**: MiLMMT-46-1B-v1.0 Q4_K_M (~806 MB, gemma license) as a selectable translation provider in Settings.
- **Image understanding**: Gemma 4 E2B it (~2.59 GB, Apache-2.0, LiteRT-LM runtime) takes over classroom-photo analysis and visual Q&A once downloaded (local implementation of the same service protocol); loads only for the duration of a request and is released right after — never co-resident with the translation model beyond one request.
- **System-translation fallback**: when the local model fails to load or infer, that single request degrades to Apple Translation (programmatic sessions require iOS 26+; older systems fail honestly, never silently).
- **Model management**: all three models ride the existing manifest + measured-SHA256 + resumable-download + pause/delete/re-verify distribution system (new 翻译模型管理 screen); disk-space preflight; model files never committed to Git and never bundled into the initial app.
- **Session safety**: a classroom session pins the selected translation model until the session ends (switch/delete only afterwards); the stop path drains in-flight translations before unpinning; the Russian original is always persisted before translation, so no failure can lose a transcript.
- **Switching semantics**: at most one translation model resident at any time; switching fully unloads the old model first; classroom records are unaffected by provider switches.
- **Runtimes**: llama.cpp (pinned commit `465e49b9` — includes the STQ kernel Hy-MT2 requires — Metal-accelerated) and LiteRT-LM (pinned commit) are both fetched/built by scripts and never committed; CI gained fetch steps for both frameworks.
- **Tests**: new unit tests (byte-exact prompt contracts, a manifest-decode regression, provider defaults/migration, fallback chain, session pinning) and model-gated integration tests (real Russian→Chinese inference, both models load/switch/release, missing-model semantics — auto-skip when models are absent).
- **Measured results**: on the simulator, Hy-MT2 genuinely translates Russian→Chinese ("Сегодня мы изучаем производные сложных функций." → "今天我们学习复合函数的导数。", 5.5 s incl. load) and MiLMMT (1.6 s); cross-checked byte-identical prompts against the official llama.cpp CLI; all existing unit + integration suites pass (one environmental GoServerE2E flake passed on rerun). Simulator caveats: llama.cpp Metal yields all-zero logits on the simulator (forced CPU there; devices unaffected); the Gemma LiteRT runtime's simulator slice is a non-functional stub — **image understanding still needs on-device verification**.
- Docs: new `docs/OFFLINE_MODELS.md`; README, ARCHITECTURE, PRIVACY, MODEL_DISTRIBUTION and THIRD_PARTY_NOTICES updated (license detail, including a manual-review note for MiLMMT's gemma terms).

## 2026-09-07 (round 21)

Per-field Russian form filling with a field-translation assistant: `form-draft.json` sidecar, field-ask linkage, two-phase translation. iOS `efac1ef`, Go unchanged.

## 2026-09-06 (round 20)

Continuous-listening interpreter: pause gate, errand-capture sheet, document templates. iOS ci/round20-continuous-interpreter.
