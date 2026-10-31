# Model and labels

One model, used by every classifier in the demo (channel path and FFI path), so
the only thing that differs between runs is the bridge.

| | |
| --- | --- |
| Model | MobileNet V1, width 1.0, 224x224, float32 (not quantized) |
| File | `mobilenet_v1_1.0_224.tflite` (16.9 MB) |
| Source | https://storage.googleapis.com/download.tensorflow.org/models/mobilenet_v1_2018_08_02/mobilenet_v1_1.0_224.tgz (file `./mobilenet_v1_1.0_224.tflite` inside the archive) |
| Model page | https://github.com/tensorflow/models/blob/master/research/slim/nets/mobilenet_v1.md |
| Licence | Apache License 2.0 (the `tensorflow/models` repository, folder `research`: https://github.com/tensorflow/models/blob/master/LICENSE) |
| Accuracy | 70.9% top-1, 89.9% top-5 on ImageNet (ILSVRC 2012), as stated on the model page |
| Labels | `labels.txt`, 1001 lines, index 0 is `background` |
| Labels source | `labels_mobilenet_quant_v1_224.txt` from https://storage.googleapis.com/download.tensorflow.org/models/tflite/mobilenet_v1_1.0_224_quant_and_labels.zip (the same 1001-class order the float model uses) |

SHA-256:

```text
d95b3c5ea86750cef882fa867ca357dfe4d265d0b80b67e83277a0bda310cfbb  mobilenet_v1_1.0_224.tflite
536feacc519de3d418de26b2effb4d75694a8c4c0063e36499a46fa8061e2da9  labels.txt
```

## Input and output

- Input: `float32`, shape `[1, 224, 224, 3]`, RGB, row-major, values in
  `[-1, 1]` (`pixel / 127.5 - 1`). That is 602,112 bytes, the payload size used
  in the round-trip suite.
- Output: `float32`, shape `[1, 1001]`, softmax probabilities. The label for
  index `i` is line `i` of `labels.txt` (zero-based).
- Preprocessing used by all three implementations (Kotlin, Dart, C): bilinear
  resize from the RGBA frame to 224x224 with the half-pixel rule
  `src = (dst + 0.5) * scale - 0.5`, clamped to the frame; alpha is dropped.

## Why float

The talk's preprocess step produces floats in `[-1, 1]`, and both paths hand the
model that same tensor. A quantized (uint8) MobileNet is 4.3 MB but would need a
conversion step on each path, which is one more thing to keep identical.

## Fetching again

`scripts/fetch-models.sh` is the place for this. By hand:

```sh
curl -LO https://storage.googleapis.com/download.tensorflow.org/models/mobilenet_v1_2018_08_02/mobilenet_v1_1.0_224.tgz
tar xzf mobilenet_v1_1.0_224.tgz ./mobilenet_v1_1.0_224.tflite
curl -LO https://storage.googleapis.com/download.tensorflow.org/models/tflite/mobilenet_v1_1.0_224_quant_and_labels.zip
unzip mobilenet_v1_1.0_224_quant_and_labels.zip labels_mobilenet_quant_v1_224.txt
mv labels_mobilenet_quaknt_v1_224.txt labels.txt
shasum -a 256 mobilenet_v1_1.0_224.tflite labels.txt   # compare with the table above
```
