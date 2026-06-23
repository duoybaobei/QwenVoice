// Vocello addition (not upstream): a thin re-export surface so the macOS app can
// use the on-device text-LLM stack (Qwen3-1.7B-4bit story generation) without
// declaring mlx-swift-lm a second time at the project level. The mlx-swift-lm
// pin stays single-sourced in this package's Package.swift (exact 2.30.6, kept
// in lockstep with mlx-swift 0.30.6 per AGENTS.md).
//
// Importing `MLXAudioLLM` from the app yields the full MLXLLM + MLXLMCommon API
// surface (LLMModelFactory, ModelContainer, ChatSession, GenerateParameters, …).
@_exported import MLXLLM
@_exported import MLXLMCommon
