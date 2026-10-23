import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// The trained landmark matcher, run from raw numbers.
///
/// The app bundles no inference runtime - no ONNX, no TFLite, no MediaPipe
/// Tasks library beyond the landmarker plugin - so the encoder the training
/// script produced is read straight out of `video_embed.f32.bin` and evaluated
/// here. That keeps the on-device answer identical to the number `verify_video_match.py`
/// scored the corpus with, which is the only reason the accept margin means
/// anything on a phone.
///
/// The layout is fixed by `training/video/export_deployable.py`: one flat
/// little-endian float32 blob, tensors in manifest order, row-major, and a
/// linear layer stored as `weight[output][input]` so a dot product walks one
/// contiguous row.
class LandmarkEncoder {
  LandmarkEncoder._({
    required this.window,
    required this.featuresPerFrame,
    required this.embedDim,
    required this.hiddenDim,
    required Float32List values,
    required Map<String, _Tensor> tensors,
  })  : _values = values,
        _tensors = tensors;

  /// Loads the exported blob and the manifest that describes it.
  ///
  /// Every shape the reader needs comes from the manifest, and the float count
  /// has to come out exact: a truncated or extended blob means the training
  /// script reordered its parameters, and reading past a tensor boundary would
  /// otherwise produce an embedding that is silently wrong.
  factory LandmarkEncoder.fromJsonAndBytes(Map<String, dynamic> manifest, ByteData bytes) {
    final described = manifest['weights'] as List<dynamic>;
    final tensors = <String, _Tensor>{};
    var offset = 0;
    for (final entry in described) {
      final shape = (entry as Map<String, dynamic>)['shape'] as List<dynamic>;
      final rows = shape.isEmpty ? 1 : (shape[0] as num).toInt();
      final columns = shape.length < 2 ? 1 : (shape[1] as num).toInt();
      final name = entry['name'] as String;
      if (entry['dtype'] != 'float32') {
        throw FormatException('unsupported weight dtype for $name: ${entry['dtype']}');
      }
      tensors[name] = _Tensor(name, rows, columns, offset);
      offset += rows * columns;
    }
    final declared = manifest['float_count'] as num;
    if (declared.toInt() != offset) {
      throw FormatException('the manifest describes $offset floats but declares $declared');
    }
    if (bytes.lengthInBytes != offset * 4) {
      throw FormatException(
        'the weight blob holds ${bytes.lengthInBytes ~/ 4} floats, the manifest needs $offset',
      );
    }
    final values = Float32List(offset);
    for (var index = 0; index < offset; index++) {
      values[index] = bytes.getFloat32(index * 4, Endian.little);
    }
    return LandmarkEncoder._(
      window: manifest['window'] as int,
      featuresPerFrame: manifest['features_per_frame'] as int,
      embedDim: manifest['embed_dim'] as int,
      hiddenDim: manifest['hidden_dim'] as int,
      values: values,
      tensors: tensors,
    );
  }

  static LandmarkEncoder parse(String manifestJson, ByteData bytes) {
    return LandmarkEncoder.fromJsonAndBytes(jsonDecode(manifestJson) as Map<String, dynamic>, bytes);
  }

  final int window;
  final int featuresPerFrame;
  final int embedDim;
  final int hiddenDim;
  final Float32List _values;
  final Map<String, _Tensor> _tensors;

  /// Encodes one `window`-frame feature block into a unit-length vector.
  ///
  /// [mask] marks the rows that carry a real tracked frame; padding rows are
  /// zeroed before the recurrent pass and excluded from the attention weights,
  /// exactly as `TrackEmbedder.forward` does during training.
  Float32List embed(Float32List features, Float32List mask) {
    final frames = _linear(_tensors['frame.0.weight']!, _tensors['frame.0.bias']!, features, window);
    for (var row = 0; row < window; row++) {
      if (mask[row] <= 0.5) {
        for (var column = 0; column < hiddenDim; column++) {
          frames[row * hiddenDim + column] = 0.0;
        }
      }
    }
    final joined = Float32List(window * hiddenDim * 2);
    _gru(frames, joined, reversed: false);
    _gru(frames, joined, reversed: true);

    final attendWeight = _tensors['attend.weight']!;
    final attendBias = _tensors['attend.bias']!;
    final scores = Float32List(window);
    var highest = double.negativeInfinity;
    for (var row = 0; row < window; row++) {
      final start = row * hiddenDim * 2;
      var score = _values[attendBias.offset];
      for (var column = 0; column < hiddenDim * 2; column++) {
        score += _values[attendWeight.offset + column] * joined[start + column];
      }
      scores[row] = mask[row] > 0.5 ? score : -1e4;
      if (scores[row] > highest) highest = scores[row];
    }
    var total = 0.0;
    for (var row = 0; row < window; row++) {
      scores[row] = math.exp(scores[row] - highest);
      total += scores[row];
    }
    final pooled = Float32List(hiddenDim * 2);
    for (var row = 0; row < window; row++) {
      final weight = scores[row] / total;
      final start = row * hiddenDim * 2;
      for (var column = 0; column < hiddenDim * 2; column++) {
        pooled[column] += joined[start + column] * weight;
      }
    }
    final head = _linear(_tensors['head.weight']!, _tensors['head.bias']!, pooled, 1, activate: false);
    var norm = 0.0;
    for (final value in head) {
      norm += value * value;
    }
    norm = math.sqrt(norm);
    if (norm > 0.0) {
      for (var column = 0; column < embedDim; column++) {
        head[column] /= norm;
      }
    }
    return head;
  }

  /// y = gelu(x W^T + b) for a batch of rows laid end to end in [input].
  ///
  /// The head is the same shape of layer without the activation, so the caller
  /// asks for the linear part alone.
  Float32List _linear(
    _Tensor weight,
    _Tensor bias,
    Float32List input,
    int rows, {
    bool activate = true,
  }) {
    final outputs = bias.size;
    final inputs = weight.columns;
    final out = Float32List(rows * outputs);
    for (var row = 0; row < rows; row++) {
      final source = row * inputs;
      for (var column = 0; column < outputs; column++) {
        var acc = _values[bias.offset + column];
        final start = weight.offset + column * inputs;
        for (var i = 0; i < inputs; i++) {
          acc += _values[start + i] * input[source + i];
        }
        out[row * outputs + column] = activate ? _gelu(acc) : acc;
      }
    }
    return out;
  }

  /// One direction of the bidirectional GRU, written into its half of [output].
  ///
  /// Gate order is PyTorch's: reset, update, candidate. The candidate sees the
  /// recurrent half *after* the reset gate, which is the one detail a hand
  /// rewrite of a GRU gets wrong, and getting it wrong moves every embedding.
  void _gru(Float32List input, Float32List output, {required bool reversed}) {
    final suffix = reversed ? '_reverse' : '';
    final wIh = _tensors['temporal.weight_ih_l0$suffix']!;
    final wHh = _tensors['temporal.weight_hh_l0$suffix']!;
    final bIh = _tensors['temporal.bias_ih_l0$suffix']!;
    final bHh = _tensors['temporal.bias_hh_l0$suffix']!;
    final gates = hiddenDim;
    final fromInput = Float32List(gates * 3);
    final fromState = Float32List(gates * 3);
    final state = Float32List(gates);
    final offset = reversed ? gates : 0;
    for (var step = 0; step < window; step++) {
      final row = reversed ? window - 1 - step : step;
      final source = row * gates;
      for (var gate = 0; gate < gates * 3; gate++) {
        var acc = _values[bIh.offset + gate];
        final start = wIh.offset + gate * gates;
        for (var column = 0; column < gates; column++) {
          acc += _values[start + column] * input[source + column];
        }
        fromInput[gate] = acc;
        var recurrent = _values[bHh.offset + gate];
        final from = wHh.offset + gate * gates;
        for (var column = 0; column < gates; column++) {
          recurrent += _values[from + column] * state[column];
        }
        fromState[gate] = recurrent;
      }
      for (var column = 0; column < gates; column++) {
        final reset = 1.0 / (1.0 + math.exp(-(fromInput[column] + fromState[column])));
        final update = 1.0 /
            (1.0 + math.exp(-(fromInput[gates + column] + fromState[gates + column])));
        final candidate =
            _tanh(fromInput[2 * gates + column] + reset * fromState[2 * gates + column]);
        state[column] = (1.0 - update) * candidate + update * state[column];
      }
      final written = row * gates * 2;
      for (var column = 0; column < gates; column++) {
        output[written + offset + column] = state[column];
      }
    }
  }
}

/// tanh without a dependency: `dart:math` does not carry it.
///
/// The exp(-2|x|) form is stable at both ends, where the naive ratio of
/// exponentials overflows.
double _tanh(double x) {
  if (x >= 0.0) {
    final decay = math.exp(-2.0 * x);
    return (1.0 - decay) / (1.0 + decay);
  }
  final growth = math.exp(2.0 * x);
  return (growth - 1.0) / (growth + 1.0);
}

/// torch's default GELU: `0.5 * x * (1 + erf(x / sqrt(2)))`.
///
/// `dart:math` has no erf, so this is the Abramowitz-Stegun 7.1.26 rational
/// form, whose error is below 1.5e-7 - far inside the 1e-4 the golden test
/// allows, and much closer to the trained model than the tanh approximation
/// torch can also be asked for.
double _gelu(double x) {
  if (x == 0.0) return 0.0;
  final z = x.abs() / math.sqrt(2.0);
  final t = 1.0 / (1.0 + 0.3275911 * z);
  final polynomial = t *
      (0.254829592 +
          t *
              (-0.284496736 +
                  t * (1.421413741 + t * (-1.453152027 + t * 1.061405429))));
  final erf = 1.0 - polynomial * math.exp(-z * z);
  final signed = x > 0.0 ? erf : -erf;
  return 0.5 * x * (1.0 + signed);
}

class _Tensor {
  const _Tensor(this.name, this.rows, this.columns, this.offset);

  final String name;
  final int rows;
  final int columns;
  final int offset;

  int get size => rows * columns;
}
