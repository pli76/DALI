// Copyright (c) 2020, NVIDIA CORPORATION. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <gtest/gtest.h>
#include <random>
#include <vector>
#include "dali/test/tensor_test_utils.h"
#include "dali/test/test_tensors.h"
#include "dali/kernels/reduce/reduce_all_gpu_impl.cuh"
#include "dali/kernels/reduce/reduce_all_kernel_gpu.h"
#include "dali/kernels/scratch.h"
#include "dali/kernels/alloc.h"
#include "dali/core/util.h"
#include "dali/core/span.h"
#include "dali/core/cuda_event.h"

namespace dali {
namespace kernels {

template <typename Out, typename Reduction, typename T>
Out RefReduce(span<T> in, const Reduction &R) {
  switch (in.size()) {
    case 0:
      return R.template neutral<Out>();
    case 1:
      return in[0];
    default: {
      if (in.size() <= 128) {
        double acc = R.template neutral<Out>();
        for (auto &x : in)
          R(acc, x);
        return acc;
      }
      int m = in.size() / 2;
      int n = in.size() - m;
      Out out = RefReduce<Out>(make_span(in.data(), m), R);
      R(out, RefReduce<Out>(make_span(in.data() + m, n), R));
      return out;
    }
  }
}

using ReductionTestTypes = ::testing::Types<reductions::sum, reductions::min, reductions::max>;

inline bool IsAccurate(const reductions::min &) { return true; }
inline bool IsAccurate(const reductions::max &) { return true; }
template <typename Reduction>
inline bool IsAccurate(const Reduction &) { return false; }

template <typename Reduction>
class ReduceAllGPUTest : public ::testing::Test {
 public:
  void TestReduceAll();
  void TestReduceBatched();
  void TestReduceAllKernel(int min_size, int max_size);

  template <typename T>
  inline auto ref_reduce(span<T> in) const {
    return RefReduce<double>(in, R);
  }

  Reduction R;
};

TYPED_TEST_SUITE(ReduceAllGPUTest, ReductionTestTypes);

template <typename Reduction>
void ReduceAllGPUTest<Reduction>::TestReduceAll() {
  std::mt19937_64 rng(1234);
  std::uniform_real_distribution<float> dist(0, 1);

  int n_in = 1<<23;  // 8M numbers
  dim3 block(32, 32);
  int nblock = 1024;
  int n_out0 = std::min<int>(div_ceil(n_in, nblock), 1024);
  int n_out = n_out0 + 1;
  auto in_data = memory::alloc_unique<float>(AllocType::GPU, n_in);
  auto out_data = memory::alloc_unique<float>(AllocType::GPU, n_out);
  std::vector<float> in_cpu(n_in), out_cpu(n_out);
  for (auto &x : in_cpu)
    x = dist(rng);
  double ref_value = ref_reduce(make_cspan(in_cpu));

  cudaMemcpy(in_data.get(), in_cpu.data(), n_in * sizeof(*in_data), cudaMemcpyHostToDevice);

  dim3 grid = n_out0;
  ReduceAllKernel<<<1, block>>>(out_data.get(), in_data.get(), n_in);
  cudaDeviceSynchronize();
  auto start = CUDAEvent::CreateWithFlags(0);
  auto end =   CUDAEvent::CreateWithFlags(0);
  cudaEventRecord(start);
  ReduceAllKernel<<<grid, block>>>(out_data.get() + 1, in_data.get(), n_in, R);
  ReduceAllKernel<<<1, block>>>(out_data.get(), out_data.get() + 1, n_out0, R);
  cudaEventRecord(end);
  cudaMemcpy(out_cpu.data(), out_data.get(), n_out * sizeof(*out_data), cudaMemcpyDeviceToHost);
  cudaDeviceSynchronize();
  float t = 0;
  cudaEventElapsedTime(&t, start, end);
  double out_value = out_cpu[0];
  double out_partial = ref_reduce(make_cspan(&out_cpu[1], n_out0));
  if (IsAccurate(R)) {
    EXPECT_EQ(out_value, ref_value);
    EXPECT_EQ(out_partial, ref_value);
  } else {
    double eps = ref_value * 1e-7 + 1e-7;
    EXPECT_NEAR(out_value, ref_value, eps);
    EXPECT_NEAR(out_partial, ref_value, eps);
  }

  t /= 1000;  // convert to seconds
  std::cout << n_in * sizeof(*in_data) / t * 1e-9 << " GB/s" << std::endl;
}

TYPED_TEST(ReduceAllGPUTest, ReduceAllKernel) {
  this->TestReduceAll();
}


template <typename Reduction>
void ReduceAllGPUTest<Reduction>::TestReduceBatched() {
  std::mt19937_64 rng(1234);
  std::uniform_real_distribution<float> dist(0, 1);
  std::uniform_int_distribution<int> size_dist(10000, 1000000);

  int64_t n_in = 0;
  int samples = 35;
  std::vector<int64_t> sizes(samples);
  for (auto &size : sizes) {
    size = size_dist(rng);
    n_in += size;
  }

  dim3 block(32, 32);
  int n_out_per_sample = 32;
  int n_out0 = samples * n_out_per_sample;
  int n_out = n_out0 + samples;
  dim3 grid(n_out_per_sample, samples);
  auto in_data = memory::alloc_unique<float>(AllocType::GPU, n_in);
  auto out_data = memory::alloc_unique<float>(AllocType::GPU, n_out);
  std::vector<float> in_cpu(n_in), out_cpu(n_out);
  for (auto &x : in_cpu)
    x = dist(rng);

  auto gpu_dev_ptrs = memory::alloc_unique<const float*>(AllocType::GPU, samples);
  auto gpu_sizes = memory::alloc_unique<int64_t>(AllocType::GPU, samples);
  vector<const float *> host_ptrs(samples);
  vector<const float *> cpu_dev_ptrs(samples);
  int64_t offset = 0;
  for (int i = 0; i < samples; i++) {
    host_ptrs[i] = in_cpu.data() + offset;
    cpu_dev_ptrs[i] = in_data.get() + offset;
    offset += sizes[i];
  }

  // data
  cudaMemcpy(in_data.get(), in_cpu.data(), n_in * sizeof(*in_data), cudaMemcpyHostToDevice);
  // pointers to sample data
  cudaMemcpy(gpu_dev_ptrs.get(), cpu_dev_ptrs.data(), samples * sizeof(*gpu_dev_ptrs),
             cudaMemcpyHostToDevice);
  // sample sizes
  cudaMemcpy(gpu_sizes.get(), sizes.data(), samples * sizeof(*gpu_sizes), cudaMemcpyHostToDevice);

  // warm-up
  ReduceAllBatchedKernel<<<1, block>>>(out_data.get(), gpu_dev_ptrs.get(), gpu_sizes.get(), R);
  cudaDeviceSynchronize();
  auto start = CUDAEvent::CreateWithFlags(0);
  auto end =   CUDAEvent::CreateWithFlags(0);
  cudaEventRecord(start);
  ReduceAllBatchedKernel<<<grid, block>>>(out_data.get() + samples,
                                          gpu_dev_ptrs.get(), gpu_sizes.get(), R);

  dim3 grid2(1, samples);
  ReduceAllBlockwiseKernel<<<grid2, block>>>(out_data.get(),
                                             out_data.get() + samples, n_out_per_sample,
                                             R);
  cudaEventRecord(end);
  cudaMemcpy(out_cpu.data(), out_data.get(), n_out * sizeof(*out_data), cudaMemcpyDeviceToHost);
  cudaDeviceSynchronize();
  float t = 0;
  cudaEventElapsedTime(&t, start, end);

  offset = 0;
  for (int i = 0; i < samples; i++) {
    double ref_value = ref_reduce(make_cspan(host_ptrs[i], sizes[i]));
    double out_value = out_cpu[i];
    auto partial_values = make_cspan(&out_cpu[samples + i * n_out_per_sample], n_out_per_sample);
    double out_partial = ref_reduce(partial_values);
    if (IsAccurate(R)) {
      EXPECT_EQ(out_value, ref_value);
      EXPECT_EQ(out_partial, ref_value);
    } else {
      double eps = ref_value * 1e-7 + 1e-7;
      EXPECT_NEAR(out_value, ref_value, eps);
      EXPECT_NEAR(out_partial, ref_value, eps);
    }
    offset += sizes[i];
  }

  t /= 1000;  // convert to seconds
  std::cout << n_in * sizeof(*in_data) / t * 1e-9 << " GB/s" << std::endl;
}

TYPED_TEST(ReduceAllGPUTest, ReduceAllBatchedKernel) {
  this->TestReduceBatched();
}

template <typename Reduction>
void ReduceAllGPUTest<Reduction>::TestReduceAllKernel(int min_size, int max_size) {
  using Out = double;
  using In = float;

  std::mt19937_64 rng(1234);
  std::uniform_int_distribution<int> size_dist(min_size, max_size);

  int nsamples = 35;
  constexpr int ndim = 1;
  TensorListShape<ndim> data_shape(nsamples, ndim);
  int64_t total_size = 0;
  for (int i = 0; i < nsamples; i++) {
    auto size = size_dist(rng);
    data_shape.set_tensor_shape(i, {size});
    total_size += size;
  }

  TestTensorList<In, ndim> in;
  in.reshape(data_shape);
  UniformRandomFill(in.cpu(), rng, 0.0, 1.0);

  kernels::reduce::ReduceAllGPU<Out, In, ndim, Reduction> kernel;

  auto out_shape = TensorListShape<1>::make_uniform(nsamples, TensorShape<1>{1});
  TestTensorList<Out, 1> out;
  out.reshape(out_shape.to_static<1>());

  auto in_view_gpu = in.gpu();
  auto out_view_gpu = out.gpu();

  KernelContext ctx;
  ctx.gpu.stream = 0;

  auto req = kernel.Setup(ctx, in_view_gpu);

  ScratchpadAllocator sa;
  sa.Reserve(req.scratch_sizes);
  auto scratchpad = sa.GetScratchpad();
  ctx.scratchpad = &scratchpad;

  ASSERT_EQ(req.output_shapes[0], out_shape);

  kernel.Run(ctx, out_view_gpu, in_view_gpu);

  cudaDeviceSynchronize();

  auto in_view_cpu = in.cpu();
  auto out_view_cpu = out.cpu();
  for (int i = 0; i < nsamples; i++) {
    double ref_value = ref_reduce(make_cspan(in_view_cpu[i].data, volume(in_view_cpu[i].shape)));
    double out_value = out_view_cpu[i].data[0];
    if (IsAccurate(R)) {
      EXPECT_EQ(out_value, ref_value);
    } else {
      double eps = ref_value * 1e-7 + 1e-7;
      EXPECT_NEAR(out_value, ref_value, eps);
    }
  }
}

TYPED_TEST(ReduceAllGPUTest, ReduceAllKernelGPU) {
  // big inputs
  this->TestReduceAllKernel(10000, 1000000);
  // small inputs
  this->TestReduceAllKernel(128, 2048);
}

}  // namespace kernels
}  // namespace dali
