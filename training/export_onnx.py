#!/usr/bin/env python3
"""Export a trained gloss seq2seq checkpoint to ONNX and int8.

Usage:
  python3 training/export_onnx.py --run training/runs/gloss_rnn \
      --out training/export

Verifies fp32/int8 outputs against the PyTorch greedy decoder on the
held-out test split before reporting sizes.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from train import (  # noqa: E402
    GlossSeq2Seq,
    Vocab,
    load_rows,
    tokenize_source,
)

MAX_SRC = 24


def vocab_from_itos(itos: list[str]) -> Vocab:
    vocab = Vocab([])
    vocab.itos = itos
    vocab.stoi = {t: i for i, t in enumerate(itos)}
    return vocab


class MatMulOutput(torch.nn.Module):
    """Linear as MatMul+Add so dynamic quantization does not rewrite Gemm.

    onnxruntime's int8 quantizer turns each of the 32 unrolled Gemm nodes into
    DynamicQuantizeMatMul, which fails with a dimension mismatch on this graph.
    """

    def __init__(self, linear: torch.nn.Linear) -> None:
        super().__init__()
        self.weight = linear.weight
        self.bias = linear.bias

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return torch.matmul(x, self.weight.t()) + self.bias


class ExportModel(torch.nn.Module):
    def __init__(self, model: GlossSeq2Seq) -> None:
        super().__init__()
        self.model = model
        self.model.decoder.out = MatMulOutput(self.model.decoder.out)

    def forward(self, src: torch.Tensor, src_len: torch.Tensor) -> torch.Tensor:
        return self.model.greedy(src, src_len)


def encode_batch(
    rows: list[dict], src_vocab: Vocab, idxs: list[int]
) -> tuple[torch.Tensor, torch.Tensor, list[dict]]:
    batch = [rows[i] for i in idxs]
    encoded = [
        src_vocab.encode(tokenize_source(row["x"], row["system"]))[:MAX_SRC]
        for row in batch
    ]
    length = torch.tensor([len(e) for e in encoded], dtype=torch.long)
    src = torch.full((len(batch), int(length.max())), 0, dtype=torch.long)
    for i, tokens in enumerate(encoded):
        src[i, : len(tokens)] = torch.tensor(tokens)
    return src, length, batch


def quantize_weights_int8(src_path: Path, dst_path: Path) -> None:
    """Symmetric int8 weight-only quantization.

    onnxruntime's dynamic quantizer also quantizes activations per tensor,
    which collapses this model (outliers in the decoder concat wipe out the
    signal). Rounding only the weights keeps greedy output at torch parity
    while cutting the file to roughly a third.
    """
    import numpy as np
    import onnx
    from onnx import TensorProto, helper, numpy_helper

    model = onnx.load(str(src_path))
    graph = model.graph
    inits = {init.name: init for init in graph.initializer}

    def trans_b(node: onnx.NodeProto) -> int:
        for attr in node.attribute:
            if attr.name == "transB":
                return int(attr.i)
        return 0

    # initializer name -> output-channel axis (None = per-tensor)
    targets: dict[str, int | None] = {}
    for node in graph.node:
        if node.op_type == "MatMul" and len(node.input) > 1:
            targets.setdefault(node.input[1], 1)
        elif node.op_type == "Gemm" and len(node.input) > 1:
            targets.setdefault(node.input[1], 0 if trans_b(node) else 1)
        elif node.op_type == "Gather" and node.input:
            targets.setdefault(node.input[0], 0)
        elif node.op_type == "GRU":
            for index in (1, 2):
                if len(node.input) > index:
                    targets.setdefault(node.input[index], None)

    mapping: dict[str, str] = {}
    quantized_nodes = []
    for name, axis in targets.items():
        init = inits.get(name)
        if init is None or init.data_type != TensorProto.FLOAT:
            continue
        weight = numpy_helper.to_array(init).astype(np.float32)
        if weight.ndim < 2:
            continue
        if axis is None:
            scale = np.array(
                max(float(np.abs(weight).max()) / 127.0, 1e-8),
                dtype=np.float32,
            )
            divisor = scale
        else:
            reduce_axes = tuple(i for i in range(weight.ndim) if i != axis)
            scale = np.maximum(
                np.abs(weight).max(axis=reduce_axes) / 127.0, 1e-8
            ).astype(np.float32)
            shape = [1] * weight.ndim
            shape[axis] = -1
            divisor = scale.reshape(shape)
        quantized = np.clip(np.round(weight / divisor), -127, 127).astype(np.int8)
        q_name = f"{name}_int8"
        s_name = f"{name}_scale"
        dq_name = f"{name}_dequant"
        graph.initializer.append(numpy_helper.from_array(quantized, q_name))
        graph.initializer.append(numpy_helper.from_array(scale, s_name))
        attrs = {"axis": axis} if axis is not None else {}
        quantized_nodes.append(
            helper.make_node(
                "DequantizeLinear", [q_name, s_name], [dq_name],
                name=dq_name, **attrs,
            )
        )
        mapping[name] = dq_name

    for node in graph.node:
        for index, value in enumerate(node.input):
            if value in mapping:
                node.input[index] = mapping[value]

    kept = [init for init in graph.initializer if init.name not in mapping]
    del graph.initializer[:]
    graph.initializer.extend(kept)
    for node in reversed(quantized_nodes):
        graph.node.insert(0, node)

    onnx.checker.check_model(model)
    onnx.save(model, str(dst_path))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run", default="training/runs/gloss_rnn_v4")
    parser.add_argument("--data", default="training/data")
    parser.add_argument("--out", default="training/export")
    parser.add_argument("--samples", type=int, default=512)
    args = parser.parse_args()

    run_dir = Path(args.run)
    meta = json.loads((run_dir / "vocab.json").read_text(encoding="utf-8"))
    config = meta["config"]
    src_vocab = vocab_from_itos(meta["src_itos"])
    tgt_vocab = vocab_from_itos(meta["tgt_itos"])

    model = GlossSeq2Seq(
        len(src_vocab),
        len(tgt_vocab),
        emb=config["emb"],
        enc_hidden=config["enc_hidden"],
        dec_hidden=config["dec_hidden"],
        dropout=0.0,
    )
    checkpoint = torch.load(run_dir / "best.pt", map_location="cpu")
    model.load_state_dict(checkpoint["model"])
    model.eval()

    test_rows = load_rows(Path(args.data) / "test.jsonl")
    count = min(args.samples, len(test_rows))
    idxs = [i * len(test_rows) // count for i in range(count)]
    src, src_len, batch = encode_batch(test_rows, src_vocab, idxs)

    with torch.no_grad():
        reference = model.greedy(src, src_len)

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    fp32_path = out_dir / "gloss_seq2seq.onnx"
    int8_path = out_dir / "gloss_seq2seq.int8.onnx"

    torch.onnx.export(
        ExportModel(model).eval(),
        (src[:1], src_len[:1]),
        str(fp32_path),
        input_names=["src", "src_len"],
        output_names=["gloss_ids"],
        dynamic_axes={
            "src": {0: "batch", 1: "seq"},
            "src_len": {0: "batch"},
            "gloss_ids": {0: "batch"},
        },
        opset_version=17,
        dynamo=False,
    )

    quantize_weights_int8(fp32_path, int8_path)

    import numpy as np
    import onnxruntime as ort

    def run_session(path: Path) -> list[list[int]]:
        session = ort.InferenceSession(
            str(path), providers=["CPUExecutionProvider"]
        )
        outputs = []
        for start in range(0, len(idxs), 64):
            stop = min(start + 64, len(idxs))
            feed = {
                "src": src[start:stop].numpy().astype(np.int64),
                "src_len": src_len[start:stop].numpy().astype(np.int64),
            }
            outputs.extend(session.run(None, feed)[0].tolist())
        return outputs

    fp32_out = run_session(fp32_path)
    int8_out = run_session(int8_path)
    reference_list = reference.tolist()

    single_session = ort.InferenceSession(
        str(fp32_path), providers=["CPUExecutionProvider"]
    )
    single_out = single_session.run(
        None,
        {
            "src": src[:1].numpy().astype(np.int64),
            "src_len": src_len[:1].numpy().astype(np.int64),
        },
    )[0].tolist()

    def strip(ids: list[int]) -> list[int]:
        result = []
        for value in ids:
            if value == 3:  # EOS
                break
            result.append(value)
        return result

    torch_matches = sum(
        strip(a) == strip(b) for a, b in zip(reference_list, fp32_out)
    )
    int8_matches = sum(
        strip(a) == strip(b) for a, b in zip(reference_list, int8_out)
    )
    single_match = strip(single_out[0]) == strip(reference_list[0])
    exact_reference = 0
    for ids, row in zip(reference_list, batch):
        ref = [tgt_vocab.stoi.get(t, 1) for t in row["y"].split()]
        exact_reference += strip(ids) == ref

    print(f"test samples: {len(batch)}")
    print(f"onnx fp32 == torch greedy: {torch_matches}/{len(batch)}")
    print(f"onnx int8 == torch greedy: {int8_matches}/{len(batch)}")
    print(f"onnx fp32 batch=1 == torch greedy: {single_match}")
    print(f"torch greedy exact match: {exact_reference}/{len(batch)} "
          f"({exact_reference / max(1, len(batch)):.3f})")
    for path in (fp32_path, int8_path):
        print(f"{path}: {path.stat().st_size / 1e6:.2f} MB")


if __name__ == "__main__":
    main()
