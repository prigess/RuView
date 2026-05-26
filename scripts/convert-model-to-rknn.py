#!/usr/bin/env python3
"""
Convert ONNX models to RKNN format for Orange Pi 5 Pro NPU acceleration.

This script runs on x86 (Mac/Linux) - the resulting .rknn files are deployed to Orange Pi.

Usage:
    pip install rknn-toolkit2
    python convert-model-to-rknn.py --input model.onnx --output model.rknn

Requirements:
    - x86_64 machine (Mac Intel or Linux)
    - Python 3.8-3.10
    - rknn-toolkit2: pip install rknn-toolkit2
"""

import argparse
import os
import sys
import numpy as np

def create_calibration_data(shape, num_samples=100, output_dir="/tmp/calib"):
    """Create calibration data for quantization."""
    os.makedirs(output_dir, exist_ok=True)

    paths = []
    for i in range(num_samples):
        data = np.random.randn(*shape).astype(np.float32)
        path = os.path.join(output_dir, f"sample_{i:03d}.npy")
        np.save(path, data)
        paths.append(path)

    # Write calibration list
    list_path = os.path.join(output_dir, "calibration_list.txt")
    with open(list_path, "w") as f:
        for p in paths:
            f.write(p + "\n")

    return list_path

def convert_onnx_to_rknn(input_path, output_path, quantize=True, input_shape=None):
    """Convert ONNX model to RKNN format for RK3588."""
    try:
        from rknn.api import RKNN
    except ImportError:
        print("ERROR: rknn-toolkit2 not installed")
        print("Install with: pip install rknn-toolkit2")
        print("Note: Only works on x86_64 (Intel Mac or Linux)")
        sys.exit(1)

    print(f"Converting: {input_path}")
    print(f"Output: {output_path}")
    print(f"Quantization: {quantize}")

    rknn = RKNN(verbose=True)

    # Load ONNX model
    print("\n[1/4] Loading ONNX model...")
    ret = rknn.load_onnx(model=input_path)
    if ret != 0:
        print(f"ERROR: Failed to load ONNX model (code={ret})")
        return False

    # Configure for RK3588
    print("\n[2/4] Configuring for RK3588...")
    config_args = {
        "target_platform": "rk3588",
        "optimization_level": 3,
    }

    if quantize:
        config_args["quantized_dtype"] = "asymmetric_quantized-8"
        config_args["quantized_algorithm"] = "normal"

    rknn.config(**config_args)

    # Build model
    print("\n[3/4] Building RKNN model...")
    build_args = {"do_quantization": quantize}

    if quantize and input_shape:
        # Create calibration data
        calib_path = create_calibration_data(input_shape)
        build_args["dataset"] = calib_path
        print(f"Using calibration data: {calib_path}")

    ret = rknn.build(**build_args)
    if ret != 0:
        print(f"ERROR: Failed to build model (code={ret})")
        return False

    # Export
    print("\n[4/4] Exporting RKNN model...")
    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)
    ret = rknn.export_rknn(output_path)
    if ret != 0:
        print(f"ERROR: Failed to export model (code={ret})")
        return False

    rknn.release()

    # Print stats
    size_mb = os.path.getsize(output_path) / (1024 * 1024)
    print(f"\nSUCCESS: {output_path} ({size_mb:.2f} MB)")
    print("\nDeploy to Orange Pi:")
    print(f"  scp {output_path} root@<orangepi>:/opt/ruview/models/")
    print(f"  ssh root@<orangepi> 'systemctl restart ruview-sensing'")

    return True

def create_sample_model(output_path):
    """Create a sample CSI presence detection model."""
    try:
        import onnx
        from onnx import helper, TensorProto, numpy_helper
    except ImportError:
        print("ERROR: onnx not installed. Install with: pip install onnx")
        return None

    print("Creating sample CSI presence model...")

    # Input: [1, 56] CSI amplitudes from 56 subcarriers
    X = helper.make_tensor_value_info("input", TensorProto.FLOAT, [1, 56])

    # Simple 2-layer network: 56 -> 32 -> 3 (absent/still/moving)
    W1 = numpy_helper.from_array(np.random.randn(56, 32).astype(np.float32) * 0.1, "W1")
    B1 = numpy_helper.from_array(np.zeros(32).astype(np.float32), "B1")
    W2 = numpy_helper.from_array(np.random.randn(32, 3).astype(np.float32) * 0.1, "W2")
    B2 = numpy_helper.from_array(np.zeros(3).astype(np.float32), "B2")

    nodes = [
        helper.make_node("MatMul", ["input", "W1"], ["mm1"]),
        helper.make_node("Add", ["mm1", "B1"], ["h1"]),
        helper.make_node("Relu", ["h1"], ["h1_relu"]),
        helper.make_node("MatMul", ["h1_relu", "W2"], ["mm2"]),
        helper.make_node("Add", ["mm2", "B2"], ["logits"]),
        helper.make_node("Softmax", ["logits"], ["output"], axis=1),
    ]

    Y = helper.make_tensor_value_info("output", TensorProto.FLOAT, [1, 3])

    graph = helper.make_graph(nodes, "ruview_presence", [X], [Y], [W1, B1, W2, B2])
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 13)])

    onnx.save(model, output_path)
    print(f"Created: {output_path}")
    return output_path

def main():
    parser = argparse.ArgumentParser(description="Convert ONNX to RKNN for RK3588 NPU")
    parser.add_argument("--input", "-i", help="Input ONNX model path")
    parser.add_argument("--output", "-o", help="Output RKNN model path")
    parser.add_argument("--no-quantize", action="store_true", help="Disable INT8 quantization")
    parser.add_argument("--input-shape", help="Input shape for calibration (e.g., '1,56')")
    parser.add_argument("--create-sample", action="store_true", help="Create sample model")

    args = parser.parse_args()

    if args.create_sample:
        sample_onnx = "/tmp/ruview_presence_sample.onnx"
        create_sample_model(sample_onnx)
        args.input = sample_onnx
        args.output = args.output or "/tmp/ruview_presence_sample.rknn"

    if not args.input:
        parser.print_help()
        print("\nExamples:")
        print("  # Convert existing model")
        print("  python convert-model-to-rknn.py -i model.onnx -o model.rknn")
        print("")
        print("  # Create and convert sample model")
        print("  python convert-model-to-rknn.py --create-sample -o ruview_presence.rknn")
        return

    if not args.output:
        args.output = args.input.replace(".onnx", ".rknn")

    input_shape = None
    if args.input_shape:
        input_shape = tuple(int(x) for x in args.input_shape.split(","))

    success = convert_onnx_to_rknn(
        args.input,
        args.output,
        quantize=not args.no_quantize,
        input_shape=input_shape
    )

    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
