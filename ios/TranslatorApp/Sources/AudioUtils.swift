import Accelerate

func convertToMono(_ audio: [Float]) -> [Float] {
    let monoCount = audio.count / 2
    guard monoCount > 0 else { return [] }
    var result = [Float](repeating: 0, count: monoCount)
    for i in 0..<monoCount {
        result[i] = (audio[i * 2] + audio[i * 2 + 1]) / 2.0
    }
    return result
}

func resample(_ audio: [Float], from sourceRate: Int, to targetRate: Int) -> [Float] {
    let ratio = Float(targetRate) / Float(sourceRate)
    let targetCount = Int(Float(audio.count) * ratio)
    guard targetCount < audio.count else { return audio }

    var result = [Float](repeating: 0, count: targetCount)
    for i in 0..<targetCount {
        let srcIndex = Float(i) / ratio
        let idx = Int(srcIndex)
        let frac = srcIndex - Float(idx)
        if idx + 1 < audio.count {
            result[i] = audio[idx] * (1 - frac) + audio[idx + 1] * frac
        } else if idx < audio.count {
            result[i] = audio[idx]
        }
    }
    return result
}
