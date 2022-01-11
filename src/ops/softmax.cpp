/* Copyright 2017 Stanford, NVIDIA
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <hip/hip_runtime.h>
#include "flexflow/ops/softmax.h"
#include "flexflow/utils/hip_helper.h"
#include "flexflow/utils/hash_utils.h"

namespace FlexFlow {
// declare Legion names
using Legion::Context;
using Legion::Runtime;
using Legion::Domain;
using Legion::Task;
using Legion::Rect;
using Legion::PhysicalRegion;
using Legion::coord_t;

SoftmaxMeta::SoftmaxMeta(FFHandler handler,
                         const Softmax* softmax,
                         const Domain& input_domain)
: OpMeta(handler)
{
  checkCUDNN(miopenCreateTensorDescriptor(&inputTensor));
  checkCUDNN(cudnnSetTensorDescriptorFromDomain(inputTensor, input_domain));
  dim = softmax->dim;
  profiling = softmax->profiling;
  std::strcpy(op_name, softmax->name);
}

/*
  regions[0]: input
  regions[1]: output
 */
OpMeta* Softmax::init_task(const Task *task,
                           const std::vector<PhysicalRegion> &regions,
                           Context ctx, Runtime *runtime)
{
  assert(regions.size() == 2);
  assert(task->regions.size() == 2);
  const Softmax* softmax = (Softmax*) task->args;
  FFHandler handle = *((const FFHandler*) task->local_args);
  Domain input_domain = runtime->get_index_space_domain(
    ctx, task->regions[0].region.get_index_space());
  Domain output_domain = runtime->get_index_space_domain(
    ctx, task->regions[1].region.get_index_space());
  assert(input_domain == output_domain);
  int ndims = input_domain.get_dim();
  Domain domain;
  for (int i = 0; i < ndims-1; i++)
    assert(!softmax->outputs[0]->dims[i].is_replica_dim);
  // Only the outter-most dim can be a replica_dim
  if (softmax->outputs[0]->dims[ndims-1].is_replica_dim) {
    int replica_degree = softmax->outputs[0]->dims[ndims-1].size;
    domain.dim = ndims-1;
    for (int i = 0; i < ndims-1; i++) {
      domain.rect_data[i] = input_domain.rect_data[i];
      domain.rect_data[i+ndims-1] = input_domain.rect_data[i+ndims];
    }
    domain.rect_data[2*ndims-3] = (domain.rect_data[2*ndims-3]+1)*replica_degree-1;
    assert(domain.get_volume() == input_domain.get_volume());
  } else {
    domain = input_domain;
  }
  SoftmaxMeta* m = new SoftmaxMeta(handle, softmax, domain);
  //checkCUDNN(hipdnnCreateTensorDescriptor(&m->outputTensor));
  return m;
}

/* static */
void Softmax::forward_kernel(SoftmaxMeta const *m,
                             float const *input_ptr,
                             float *output_ptr,
                             hipStream_t stream)
{
  checkCUDNN(miopenSetStream(m->handle.dnn, stream));

  float alpha = 1.0f, beta = 0.0f;
  checkCUDNN(miopenSoftmaxForward_V2(m->handle.dnn,
                                 &alpha, m->inputTensor, input_ptr,
                                 &beta, m->inputTensor, output_ptr,
                                 MIOPEN_SOFTMAX_ACCURATE,
                                 MIOPEN_SOFTMAX_MODE_CHANNEL));
}

void Softmax::forward_task(const Task *task,
                           const std::vector<PhysicalRegion> &regions,
                           Context ctx, Runtime *runtime)
{
  Domain in_domain = runtime->get_index_space_domain(
      ctx, task->regions[0].region.get_index_space());
  switch (in_domain.get_dim()) {
#define DIMFUNC(DIM) \
    case DIM: \
      return forward_task_with_dim<DIM>(task, regions, ctx, runtime);
    LEGION_FOREACH_N(DIMFUNC)
#undef DIMFUNC
    default:
      assert(false);
  }
}

/*
  regions[0](I): input
  regions[1](O): output
*/
template<int NDIM>
__host__
void Softmax::forward_task_with_dim(
    const Task *task,
    const std::vector<PhysicalRegion> &regions,
    Context ctx, Runtime *runtime)
{
  assert(regions.size() == 2);
  assert(task->regions.size() == 2);
  //const Softmax* softmax = (Softmax*) task->args;
  const SoftmaxMeta* m = *((SoftmaxMeta**) task->local_args);
  TensorAccessorR<float, NDIM> acc_input(
      regions[0], task->regions[0], FID_DATA, ctx, runtime);
  TensorAccessorW<float, NDIM> acc_output(
      regions[1], task->regions[1], FID_DATA, ctx, runtime,
      false/*readOutput*/);

  hipStream_t stream;
  checkCUDA(get_legion_stream(&stream));

  hipEvent_t t_start, t_end;
  if (m->profiling) {
    hipEventCreate(&t_start);
    hipEventCreate(&t_end);
    hipEventRecord(t_start, stream);
  }
  forward_kernel(m, acc_input.ptr, acc_output.ptr, stream);
  if (m->profiling) {
    hipEventRecord(t_end, stream);
    checkCUDA(hipEventSynchronize(t_end));
    print_tensor<float>(acc_input.ptr, acc_input.rect.volume(), "[Softmax:forward:input]");
    print_tensor<float>(acc_output.ptr, acc_output.rect.volume(), "[Softmax:forward:output]");
    float elapsed = 0;
    checkCUDA(hipEventElapsedTime(&elapsed, t_start, t_end));
    hipEventDestroy(t_start);
    hipEventDestroy(t_end);
    log_measure.debug("%s [Softmax] forward time = %.2fms\n", m->op_name, elapsed);
  }
}

/* static */
void Softmax::backward_kernel(float *input_grad_ptr,
                              float const *output_grad_ptr,
                              size_t num_elements,
                              hipStream_t stream)
{
  checkCUDA(hipMemcpyAsync(input_grad_ptr, output_grad_ptr,
                            num_elements * sizeof(float),
                            hipMemcpyDeviceToDevice, stream));
}

void Softmax::backward_task(const Task *task,
                            const std::vector<PhysicalRegion> &regions,
                            Context ctx, Runtime *runtime)
{
  Domain in_domain = runtime->get_index_space_domain(
      ctx, task->regions[0].region.get_index_space());
  switch (in_domain.get_dim()) {
#define DIMFUNC(DIM) \
    case DIM: \
      return backward_task_with_dim<DIM>(task, regions, ctx, runtime);
    LEGION_FOREACH_N(DIMFUNC)
#undef DIMFUNC
    default:
      assert(false);
  }
}

/*
  regions[0](I/O): input_grad
  regions[1](I): output_grad
*/
// Note that the backward task of softmax is actually a no op (i.e., input_grad = output_grad)
// since the upstream cross_entropy_loss function computes performs softmax_cross_entropy_loss
// to avoid intermediate zeros
template<int NDIM>
__host__
void Softmax::backward_task_with_dim(
    const Task *task,
    const std::vector<PhysicalRegion> &regions,
    Context ctx, Runtime *runtime)
{
  assert(regions.size() == 2);
  assert(task->regions.size() == 2);
  //const Softmax* softmax = (Softmax*) task->args;
  const SoftmaxMeta* m = *((SoftmaxMeta**) task->local_args);
  TensorAccessorW<float, NDIM> acc_input_grad(
      regions[0], task->regions[0], FID_DATA, ctx, runtime,
      true/*readOutput*/);
  TensorAccessorR<float, NDIM> acc_output_grad(
      regions[1], task->regions[1], FID_DATA, ctx, runtime);
  // make sure the image indices match!
  assert(acc_input_grad.rect == acc_output_grad.rect);

  hipStream_t stream;
  checkCUDA(get_legion_stream(&stream));

  hipEvent_t t_start, t_end;
  if (m->profiling) {
    hipEventCreate(&t_start);
    hipEventCreate(&t_end);
    hipEventRecord(t_start, stream);
  }
  backward_kernel(acc_input_grad.ptr, acc_output_grad.ptr, acc_input_grad.rect.volume(), stream);
  if (m->profiling) {
    hipEventRecord(t_end, stream);
    checkCUDA(hipEventSynchronize(t_end));
    print_tensor<float>(acc_output_grad.ptr, acc_output_grad.rect.volume(), "[Softmax:backward:output_grad]");
    print_tensor<float>(acc_input_grad.ptr, acc_input_grad.rect.volume(), "[Softmax:backward:input_grad]");
    float elapsed = 0;
    checkCUDA(hipEventElapsedTime(&elapsed, t_start, t_end));
    hipEventDestroy(t_start);
    hipEventDestroy(t_end);
    log_measure.debug("Softmax backward time = %.2fms\n", elapsed);
  }
}

bool Softmax::measure_operator_cost(Simulator* sim,
                                    const ParallelConfig& pc,
                                    CostMetrics& cost_metrics) const
{
  ParallelTensorBase sub_output, sub_input;
  if (!outputs[0]->get_output_sub_tensor(pc, sub_output, op_type)) {
    return false;
  }
  if (!inputs[0]->get_input_sub_tensor(pc, sub_input, op_type)) {
    return false;
  }

  SoftmaxMeta *m = new SoftmaxMeta(sim->handler, this, sub_output.get_domain());

  sim->free_all();
  float *input_ptr = (float *)sim->allocate(sub_input.get_volume(), DT_FLOAT);
  assert (input_ptr != NULL);
  float *output_ptr = (float *)sim->allocate(sub_output.get_volume(), DT_FLOAT);
  assert (output_ptr != NULL);

  hipStream_t stream;
  checkCUDA(get_legion_stream(&stream));
  std::function<void()> forward, backward;
  forward = [&] {
    forward_kernel(m, input_ptr, output_ptr, stream);
  };
  if (sim->computationMode == COMP_MODE_TRAINING) {
    float* input_grad_ptr = (float*)sim->allocate(sub_input.get_volume(), DT_FLOAT);
    assert(input_grad_ptr != NULL);
    float *output_grad_ptr = (float *)sim->allocate(sub_output.get_volume(), DT_FLOAT);
    assert (output_grad_ptr != NULL);
    backward = [&] {
      backward_kernel(input_grad_ptr, output_grad_ptr, sub_output.get_volume(), stream);
    };
  }

  inner_measure_operator_cost(sim, forward, backward, cost_metrics);

  if (sim->computationMode == COMP_MODE_TRAINING) {
    log_measure.debug("[Measure Softmax] name(%s) num_elements(%zu) forward_time(%.4lf) backward_time(%.4lf)\n",
        name, sub_output.get_volume(),
        cost_metrics.forward_time,
        cost_metrics.backward_time);
  } else {
    log_measure.debug("[Measure Softmax] name(%s) num_elements(%zu) forward_time(%.4lf)\n",
        name, sub_output.get_volume(),
        cost_metrics.forward_time);
  }
  // Free softmaxmeta
  delete m;
  return true;
}

}; // namespace FlexFlow