/* Copyright 2019 Stanford
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

#include "initializer.h"
#include "accessor.h"
#include "model.h"
#include "cuda_helper.h"
#include <curand.h>
#include <random>
#include <ctime>

void UniformInitializer::init_task(const Task* task,
                                   const std::vector<PhysicalRegion>& regions,
                                   Context ctx, Runtime* runtime)
{

  assert(regions.size() == task->regions.size());
  UniformInitializer* initializer = (UniformInitializer*) task->args;
  curandGenerator_t gen;
  curandCreateGenerator(&gen, CURAND_RNG_PSEUDO_DEFAULT);
  cudaStream_t stream;
  checkCUDA(get_legion_stream(&stream));
  curandSetStream(gen, stream);
  //fprintf(stderr, "seed = %d\n", initializer->seed);



  for (size_t i = 0; i < regions.size(); i++) {
    Domain domain = runtime->get_index_space_domain(
        ctx, task->regions[i].region.get_index_space());
    float* w;
    switch (domain.get_dim()) {
      case 0:
      {
        // Do not support 0-dim parameters
        assert(false);
        break;
      }
#define DIMFUNC(DIM) \
      case DIM: \
      { \
        TensorAccessorW<float, DIM> accW( \
            regions[i], task->regions[i], FID_DATA, ctx, runtime, false/*readOutput*/); \
        w = accW.ptr; \
        break; \
      }
      LEGION_FOREACH_N(DIMFUNC)
#undef DIMFUNC
      default:
      {
         assert(false);
         break;
      }
    }
    curandSetPseudoRandomGeneratorSeed(gen, initializer->seed);
    checkCUDA(curandGenerateUniform(gen, w, domain.get_volume()));
    scale_kernel<<<GET_BLOCKS(domain.get_volume()), CUDA_NUM_THREADS, 0, stream>>>(
        w, domain.get_volume(), initializer->min_val, initializer->max_val);
  }
  checkCUDA(cudaDeviceSynchronize());
  curandDestroyGenerator(gen);
}

void GlorotUniform::init_task(const Task* task,
                              const std::vector<PhysicalRegion>& regions,
                              Context ctx, Runtime* runtime)
{
  assert(regions.size() == 1);
  assert(task->regions.size() == 1);
  Domain domain = runtime->get_index_space_domain(
      ctx, task->regions[0].region.get_index_space());
  float* w;
  float scale = 0;
  switch (domain.get_dim()) {
    case 2:
    {
      TensorAccessorW<float, 2> accW(regions[0], task->regions[0],
          FID_DATA, ctx, runtime, false/*readOutput*/);
      w = accW.ptr;
      int outputDim = accW.rect.hi[1] - accW.rect.lo[1] + 1;
      int inputDim = accW.rect.hi[0] - accW.rect.lo[0] + 1;
      scale = sqrt(6.0 / (inputDim + outputDim));
      break;
    }
    case 3:
    {
      TensorAccessorW<float, 3> accW(regions[0], task->regions[0],
          FID_DATA, ctx, runtime, false/*readOutput*/);
      w = accW.ptr;
      // reference: tensorflow code for computing fan_in/fan_out
      // https://github.com/tensorflow/tensorflow/blob/r2.0/tensorflow/python/ops/init_ops.py#L1415-L1439
      int num_dim = domain.get_dim();
      coord_t receptive_field_size = 1;
      for (int i = 0; i < num_dim - 2; i++)
        receptive_field_size *= (accW.rect.hi[i] - accW.rect.lo[i] + 1);
      coord_t c_in = accW.rect.hi[num_dim-2] - accW.rect.lo[num_dim-2] + 1;
      coord_t c_out = accW.rect.hi[num_dim-1] - accW.rect.lo[num_dim-1] + 1;
      coord_t fan_in = c_in * receptive_field_size;
      coord_t fan_out = c_out * receptive_field_size;
      scale = sqrt(6.0 / (fan_in + fan_out));
      break;
    }
    case 4:
    {
      TensorAccessorW<float, 4> accW(regions[0], task->regions[0],
          FID_DATA, ctx, runtime, false/*readOutput*/);
      w = accW.ptr;
      // reference: tensorflow code for computing fan_in/fan_out
      // https://github.com/tensorflow/tensorflow/blob/r2.0/tensorflow/python/ops/init_ops.py#L1415-L1439
      int num_dim = domain.get_dim();
      coord_t receptive_field_size = 1;
      for (int i = 0; i < num_dim - 2; i++)
        receptive_field_size *= (accW.rect.hi[i] - accW.rect.lo[i] + 1);
      coord_t c_in = accW.rect.hi[num_dim-2] - accW.rect.lo[num_dim-2] + 1;
      coord_t c_out = accW.rect.hi[num_dim-1] - accW.rect.lo[num_dim-1] + 1;
      coord_t fan_in = c_in * receptive_field_size;
      coord_t fan_out = c_out * receptive_field_size;
      scale = sqrt(6.0 / (fan_in + fan_out));
      break;
    }
    default:
      assert(false);
  }
  curandGenerator_t gen;
  curandCreateGenerator(&gen, CURAND_RNG_PSEUDO_DEFAULT);
  cudaStream_t stream;
  checkCUDA(get_legion_stream(&stream));
  checkCURAND(curandSetStream(gen, stream));

  GlorotUniform* initializer = (GlorotUniform*) task->args;
  curandSetPseudoRandomGeneratorSeed(gen, initializer->seed);
  fprintf(stderr, "seed = %d scale = %.4lf\n", initializer->seed, scale);
  checkCUDA(curandGenerateUniform(gen, w, domain.get_volume()));
  scale_kernel<<<GET_BLOCKS(domain.get_volume()), CUDA_NUM_THREADS, 0, stream>>>(
      w, domain.get_volume(), -scale, scale);
  checkCUDA(cudaDeviceSynchronize());
  curandDestroyGenerator(gen);
}


void NormInitializer::init_task(const Task* task,
                                const std::vector<PhysicalRegion>& regions,
                                Context ctx, Runtime* runtime)
{
  assert(regions.size() == 1);
  assert(task->regions.size() == 1);
  Domain domain = runtime->get_index_space_domain(
      ctx, task->regions[0].region.get_index_space());
  float* w;
  switch (domain.get_dim()) {
#define DIMFUNC(DIM) \
      case DIM: \
      { \
        TensorAccessorW<float, DIM> accW( \
            regions[0], task->regions[0], FID_DATA, ctx, runtime, false/*readOutput*/); \
        w = accW.ptr; \
        break; \
      }
      LEGION_FOREACH_N(DIMFUNC)
#undef DIMFUNC
    default:
      assert(false);
  }
  curandGenerator_t gen;
  curandCreateGenerator(&gen, CURAND_RNG_PSEUDO_DEFAULT);

  cudaStream_t stream;
  checkCUDA(get_legion_stream(&stream));
  checkCURAND(curandSetStream(gen, stream));

  NormInitializer* initializer = (NormInitializer*) task->args;
  //fprintf(stderr, "seed = %d\n", initializer->seed);
  curandSetPseudoRandomGeneratorSeed(gen, initializer->seed);
  //fprintf(stderr, "domain.volume() = %zu mean(%.4lf) var(%.4lf)\n",
  //    domain.get_volume(), initializer->mean, initializer->stddev);
  // FIXME: it seems curand has an internal bug with volume < 4
  // double check this later
  if (domain.get_volume() < 4) {
    std::default_random_engine generator;
    std::normal_distribution<float> distribution(
        initializer->mean, initializer->stddev);
    float* w_dram = (float*) malloc(domain.get_volume() * sizeof(float));
    for (size_t i = 0; i < domain.get_volume(); i++)
      w_dram[i] = distribution(generator);
    checkCUDA(cudaMemcpy(w, w_dram, sizeof(float) * domain.get_volume(),
                         cudaMemcpyHostToDevice));
    checkCUDA(cudaDeviceSynchronize());
    free(w_dram);
  } else {
    checkCURAND(curandGenerateNormal(gen, w, domain.get_volume(),
        initializer->mean, initializer->stddev));
    checkCUDA(cudaDeviceSynchronize());
  }
  curandDestroyGenerator(gen);
}

void ZeroInitializer::init_task(const Task* task,
                                const std::vector<PhysicalRegion>& regions,
                                Context ctx, Runtime* runtime)
{
  ZeroInitMeta* meta = (ZeroInitMeta*) task->args;
  assert(meta->num_regions == regions.size());
  assert(regions.size() == task->regions.size());
  cudaStream_t stream;
  checkCUDA(get_legion_stream(&stream));
  for (size_t i = 0; i < regions.size(); i++) {
    Domain domain = runtime->get_index_space_domain(
        ctx, task->regions[i].region.get_index_space());
    if (meta->data_types[i] == DT_FLOAT) {
      float* w = helperGetTensorPointerWO<float>(
          regions[i], task->regions[i], FID_DATA, ctx, runtime);
      assign_kernel<float><<<GET_BLOCKS(domain.get_volume()), CUDA_NUM_THREADS, 0, stream>>>(
          w, domain.get_volume(), 0.0f);
    } else if (meta->data_types[i] == DT_INT32) {
      int32_t* w = helperGetTensorPointerWO<int32_t>(
          regions[i], task->regions[i], FID_DATA, ctx, runtime);
      assign_kernel<int32_t><<<GET_BLOCKS(domain.get_volume()), CUDA_NUM_THREADS, 0, stream>>>(
          w, domain.get_volume(), 0);
    } else if (meta->data_types[i] == DT_INT64) {
      int64_t* w = helperGetTensorPointerWO<int64_t>(
          regions[i], task->regions[i], FID_DATA, ctx, runtime);
      assign_kernel<int64_t><<<GET_BLOCKS(domain.get_volume()), CUDA_NUM_THREADS, 0, stream>>>(
          w, domain.get_volume(), 0);
    } else {
      assert(false && "Unsupported data type in Zero Initializer");
    }
  }
  checkCUDA(cudaDeviceSynchronize());
}

void ConstantInitializer::init_task(const Task* task,
                                    const std::vector<PhysicalRegion>& regions,
                                    Context ctx, Runtime* runtime)
{
  ConstantInitializer* initializer = (ConstantInitializer*) task->args;
  assert(regions.size() == task->regions.size());
  cudaStream_t stream;
  checkCUDA(get_legion_stream(&stream));
  for (size_t i = 0; i < regions.size(); i++) {
    Domain domain = runtime->get_index_space_domain(
        ctx, task->regions[i].region.get_index_space());
    float* w;
    switch (domain.get_dim()) {
#define DIMFUNC(DIM) \
      case DIM: \
      { \
        TensorAccessorW<float, DIM> accW( \
            regions[i], task->regions[i], FID_DATA, ctx, runtime, false/*readOutput*/); \
        w = accW.ptr; \
        break; \
      }
      LEGION_FOREACH_N(DIMFUNC)
#undef DIMFUNC
      default:
      {
         assert(false);
         break;
      }
    }
    assign_kernel<<<GET_BLOCKS(domain.get_volume()), CUDA_NUM_THREADS, 0, stream>>>(
        w, domain.get_volume(), initializer->value);
  }
  checkCUDA(cudaDeviceSynchronize());
}
