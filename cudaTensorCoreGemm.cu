/*
 * Copyright 1993-2017 NVIDIA Corporation.  All rights reserved.
 *
 * Please refer to the NVIDIA end user license agreement (EULA) associated
 * with this source code for terms and conditions that govern your use of
 * this software. Any use, reproduction, disclosure, or distribution of
 * this software and related documentation outside the terms of the EULA
 * is strictly prohibited.
 *
 */

// CUDA sample demonstrating a GEMM computation using the Warp Matrix Multiply
// and Accumulate API introduced in CUDA 9.

// In this program, the compute_gemm kernel computes the result of a matrix multiplication
// and addition: D = alpha * A * B + beta * C. The dimensions of both C and D matrices
// are M_GLOBAL x N_GLOBAL. The A matrix is M_GLOBAL x K_GLOBAL (row-major), the B matrix
// is K_GLOBAL x N_GLOBAL (column-major).
// In that kernel, each CTA computes one 128 x 128 tile of the resulting matrix
// per iteration. When the tile is computed, the CTA stores it to the global memory
// and begins a new iteration, selecting a new 128 x 128 tile to compute.
// Each CTA consists of eight warps. For the 128 x 128 tile, each warp computes eight
// 16 x 16 subtiles, organized in a 2 x 4 two-dimensional array.
// Warps compute the 16 x 16 subtiles using nvcuda::wmma::mma_sync operations by
// moving through the K_GLOBAL dimension of the A and B matrices and accumulating
// the intermediate result in the local thread state.

// There are a number of simple optimizations used in the algorithm:
// - The CTA copies the 128 x 128 tile of the C matrix from the global memory to
//   shared memory. After that is done, each warp loads the C matrix fragments from
//   shared memory, thus avoiding a random global memory access.
// - On each internal iteration, the CTA copies a portion of the A and B matrices from
//   global memory to shared memory. After that, all warps in the CTA reuse the A and B
//   data from shared memory, thus reducing the number of data copies from global memory.
// - The portions of the A and B matrices are stored in shared memory with an additional
//   padding (skew) to reduce the number of shared memory access bank conflicts.
//   (See a detailed explanation near the SKEW_HALF macro definition.)
// - When the CTA finishes computing the tiles of the resulting matrix, each warp stores
//   its subtiles to shared memory. The CTA then copies the shared memory contents to
//   global memory, again avoiding redundant random global memory accesses.
// - Note that the CTA tile size is chosen to maximize the GPU register utilization,
//   but carefully enough to avoid local memory use.

#include <assert.h>
#include <stdio.h>
#include <cuda.h>
#include <mma.h>
#include <random>
#include <bitset>

// helper functions and utilities to work with CUDA
#include <helper_functions.h>
#include <helper_cuda.h>

// Externally configurable parameters.

#ifndef CPU_DEBUG
// Set this to 1 to verify the correctness of the GPU-computed matrix.
#define CPU_DEBUG 0
#endif

#ifndef SHARED_MEMORY_LIMIT_64K
// Set this to 0 to use more than 64 Kb of shared memory to cache data, to
// improve the performance of the computations on GPU.
// Note that you need a GPU that can have more than 64 Kb of shared memory
// per multiprocessor.
#define SHARED_MEMORY_LIMIT_64K 1
#endif

// GPU configuration.

#define WARP_SIZE 32

// MMA matrix tile dimensions.

#define M 16
#define N 16
#define K 16

#define WMMA_M 16
#define WMMA_N 16
#define WMMA_K 16


#define TILING_SIZE 16

// GEMM configuration.

#define M_TILES 256
#define N_TILES 256
#define K_TILES 256

#define M_GLOBAL (M * M_TILES)
#define N_GLOBAL (N * N_TILES)
#define K_GLOBAL (K * K_TILES)

#define C_LAYOUT wmma::mem_row_major

// Implementation constants.

#define WARPS_PER_BLOCK 8
#define THREADS_PER_BLOCK (WARP_SIZE * WARPS_PER_BLOCK)

#if SHARED_MEMORY_LIMIT_64K
// With only 64 Kb shared memory available, we can fit two 8-tile chunks of
// the A and B matrix data, that are 16 * 16 * 8 * 8 * 2 = 32 Kb each
// (i.e. two 8x8 arrays of tiles of 16x16 half-typed elements per CTA).
// But we cannot account the 8 Kb total skew overhead, without which the performance
// would be severely impacted. So we choose to reduce the chunk size in half,
// i.e. the amount of A and B matrix data we cache in shared memory.
// Accordingly, this doubles the number of outer iterations across the global K
// dimension, which only slightly impacts the performance.
#define CHUNK_K 4
#else
#define CHUNK_K 8
#endif

#define CHUNK_LINE_BYTES (CHUNK_K * K * sizeof(half))
#define WARP_COPY_BYTES (WARP_SIZE * sizeof(int4))
#define CHUNK_COPY_LINES_PER_WARP (WARP_COPY_BYTES / CHUNK_LINE_BYTES)
#define CHUNK_COPY_LINE_LANES (WARP_SIZE / CHUNK_COPY_LINES_PER_WARP)

#define BLOCK_ROW_WARPS 2
#define BLOCK_COL_WARPS 4

#define WARP_ROW_TILES 4
#define WARP_COL_TILES 2

#define BLOCK_ROW_TILES (WARP_ROW_TILES * BLOCK_ROW_WARPS)
#define BLOCK_COL_TILES (WARP_COL_TILES * BLOCK_COL_WARPS)

#define GLOBAL_MEM_STRIDE N_GLOBAL

#define SHMEM_STRIDE (N * BLOCK_ROW_TILES)
#define SHMEM_OFFSET (N * WARP_ROW_TILES)

// The macro below is used to shift rows of the A matrix and columns of the B matrix
// in shared memory to minimize possible bank conflicts.
// Before performing the nvcuda::wmma::mma_sync operation, the warp must load the matrix
// data using the nvcuda::wmma::load_matrix_sync operation. Although the memory access pattern
// is not specified for that function, each lane in the warp can read one or multiple matrix
// elements from different matrix rows or columns.
// For shared memory, such access can result in bank conflicts if different rows / columns
// of the matrix map to the same bank. By shifting each row and column by a few bytes, we
// make sure that they map to different banks, thus reducing the number of possible bank
// conflicts.
// The number of 16 two-byte "half" elements is chosen as the minimum possible shift because
// we must keep each row and column 256-bit aligned, as required by nvcuda::wmma::load_matrix_sync.
#define SKEW_HALF 16

#define checkKernelErrors(expr) do {                                                        \
    expr;                                                                                   \
                                                                                            \
    cudaError_t __err = cudaGetLastError();                                                 \
    if (__err != cudaSuccess) {                                                             \
        printf("Line %d: '%s' failed: %s\n", __LINE__, # expr, cudaGetErrorString(__err));  \
        abort();                                                                            \
    }                                                                                       \
} while(0)

using namespace nvcuda;

__host__ void init_host_matrices(half *a, half *b, float *c, 
    half *a_new, half *b_new, 
    int* A_sparse_info, int* A_tsize_info,
    int* B_sparse_info, int* B_tsize_info)
{

    std::default_random_engine generator;
    std::bernoulli_distribution distribution(0.5);

    int A_count=0, B_count=0;  // count number of trues

    std::vector<bool> A_zero_info(M_GLOBAL * K_GLOBAL);
    std::vector<bool> B_zero_info(M_GLOBAL * K_GLOBAL);




    for (int i = 0; i < M_GLOBAL; i++) {
        for (int j = 0; j < K_GLOBAL; j++) {
            if (distribution(generator)) {
                a[i*K_GLOBAL+j] = (half)(rand() % 3);
                A_zero_info[i*K_GLOBAL+j] = true;
                A_count++;
            } else {
                A_zero_info[i*K_GLOBAL+j] = false;
                a[i*K_GLOBAL+j] = 0;
            }
        }
    }

    int a_new_count=0, b_new_count=0;  // count number of trues

    int count_info = 0;
    for (int i = 0; i < M_GLOBAL / TILING_SIZE; i++) {
        for (int j = 0; j < K_GLOBAL / TILING_SIZE; j++) {
            int sparse_info[8] = {0, };
            for (int ii = 0; ii < TILING_SIZE; ii++) {
                for (int jj = 0; jj < TILING_SIZE; jj++) {
                    if (A_zero_info[(i*TILING_SIZE + ii) *K_GLOBAL +(j*TILING_SIZE + jj)]) {
                        a_new[a_new_count++] = a[(i*TILING_SIZE + ii) *K_GLOBAL +(j*TILING_SIZE + jj)];
                        sparse_info[ii/2] |= 1 << ((ii%2) * 16 + jj);
                        count_info++;
                    }
                }
            }
            for(int k = 0; k < 8; ++k) {
                A_sparse_info[(i*K_GLOBAL/TILING_SIZE+j)*8 + k] = sparse_info[k];
            }
            A_tsize_info[i*K_GLOBAL/TILING_SIZE+j] = count_info;
        }
    }

    count_info = 0;
    for (int i = 0; i < M_GLOBAL / TILING_SIZE; i++) {
        for (int j = 0; j < K_GLOBAL / TILING_SIZE; j++) {
            int sparse_info[8] = {0, };
            for (int ii = 0; ii < TILING_SIZE; ii++) {
                for (int jj = 0; jj < TILING_SIZE; jj++) {
                    if (B_zero_info[(i*TILING_SIZE + ii) *K_GLOBAL +(j*TILING_SIZE + jj)]) {
                        b_new[b_new_count++] = a[(i*TILING_SIZE + ii) *K_GLOBAL +(j*TILING_SIZE + jj)];
                        sparse_info[ii/2] |= 1 << ((ii%2) * 16 + jj);
                        count_info++;
                    }
                }
            }
            for(int k = 0; k < 8; ++k) {
                B_sparse_info[(i*K_GLOBAL/TILING_SIZE+j)*8 + k] = sparse_info[k];
            }
            B_tsize_info[i*K_GLOBAL/TILING_SIZE+j] = count_info;
        }
    }

    std::cout << "A non-zero value is " << A_count << " while B non-zero is " << B_count << std::endl;

    for (int t = 0; t < M_GLOBAL * N_GLOBAL; t++) {
        c[t] =  (float)(rand() % 3);
    }
}

__global__ void compute_gemm(const half *A, const half *B, const float *C, float *D, float alpha, float beta)
{
    extern __shared__ half shmem[][CHUNK_K * K + SKEW_HALF];

    // Warp and lane identification.
    const unsigned int warpId = threadIdx.x / WARP_SIZE;
    const unsigned int laneId = threadIdx.x % WARP_SIZE;

    // Offset in shared memory from which the B matrix is stored.
    const size_t shmem_idx_b_off = BLOCK_COL_TILES * M;

    // This pointer is used to access the C and D matrix tiles this warp computes.
    float *shmem_warp_tile_ptr = (float*)&shmem[0][0] + (warpId/2) * SHMEM_STRIDE * K * 2 + (warpId%2) * SHMEM_OFFSET;

    // This pointer is used to stream the C and D matrices block-wide tile to and from shared memory.
    float *shmem_warp_stream_ptr = (float*)&shmem[0][0] + warpId * SHMEM_STRIDE * K;

    // Adjust the beta scaler, as it'll be multiplied by alpha at the end of
    // each tile computation. Technically this is not generally correct (may result
    // in a loss of precision). Zero still needs to be specially handled though.
    beta /= alpha;

    // Each CTA slides along the 128 x 128 tiles from the top left corner of the matrix to the
    // right and down, and selects the next tile to compute. Once there's no such tile,
    // all warps in this CTA exit.
    for(unsigned int block_pos = blockIdx.x;; block_pos += gridDim.x) {
        const unsigned int block_tile_i = ((block_pos * BLOCK_ROW_TILES) / N_TILES) * (BLOCK_COL_TILES);
        const unsigned int block_tile_j = (block_pos * BLOCK_COL_TILES) % N_TILES;

        // Stop when there are no more D matrix tiles to compute in this CTA.
        if (block_tile_i >= M_TILES) {
            break;
        }

        // This warp's pointer to the C matrix data to copy memory from to shared memory.
        const size_t gmem_idx = (block_tile_i + warpId) * M * GLOBAL_MEM_STRIDE + block_tile_j * N;
        const float *src_gmem_warp_stream_ptr = &C[gmem_idx];

        // Stream multiple C tiles to shared memory.
#pragma unroll
        for (int i = 0; i < K; i++) {
            typedef int4 copy_t;

            *((copy_t *)(shmem_warp_stream_ptr + SHMEM_STRIDE * i) + laneId) = 
                *((copy_t *)(src_gmem_warp_stream_ptr + GLOBAL_MEM_STRIDE * i) + laneId);
        }

        __syncthreads();



        // #define CHUNK_LINE_BYTES (CHUNK_K * K * sizeof(half)) 128
        // #define WARP_COPY_BYTES (WARP_SIZE * sizeof(int4)) 32*16
        // #define CHUNK_COPY_LINES_PER_WARP (WARP_COPY_BYTES / CHUNK_LINE_BYTES) 4
        // #define CHUNK_COPY_LINE_LANES (WARP_SIZE / CHUNK_COPY_LINES_PER_WARP) 8

        // These fragments will accumulate the result of A and B matrix fragment multiplications
        // along the K_GLOBAL dimension.
        wmma::fragment<wmma::accumulator, M, N, K, float> c[WARP_COL_TILES][WARP_ROW_TILES];

        // Load the C matrix tiles into fragments from shared memory.
#pragma unroll
        for (int i = 0; i < WARP_COL_TILES; i++) {
#pragma unroll
            for (int j = 0; j < WARP_ROW_TILES; j++) {
                const float *tile_ptr = shmem_warp_tile_ptr + i * SHMEM_STRIDE * K + j * N;

                wmma::load_matrix_sync(c[i][j], tile_ptr, SHMEM_STRIDE, C_LAYOUT);
            }
        }

        __syncthreads();

        // Scale the C matrix.
#pragma unroll
       for (int i = 0; i < WARP_COL_TILES; i++) {
#pragma unroll
            for (int j = 0; j < WARP_ROW_TILES; j++) {
#pragma unroll
                for (int t = 0; t < c[i][j].num_elements; t++) {
                    c[i][j].x[t] *= beta;
                }
            }
        }

        // Select what warp copies what matrix to shared memory.
        // Warps 0-3 copy the A matrix, warps 4-7 copy the B matrix.
        const half *warp_ptr = (warpId < 4) ? (&A[block_tile_i * M * K_GLOBAL] + M * K_GLOBAL * (warpId % 4) * 2) :
                                              (&B[block_tile_j * N * K_GLOBAL] + N * K_GLOBAL * (warpId % 4) * 2);

        // Go through the global K dimension by a fixed step at a time.
#pragma unroll
        for (int tile_k = 0; tile_k < K_TILES; tile_k += CHUNK_K) {
            // Copy slices of the A and B matrices to shared memory.
            // The first half of the warps in the CTA copy the A matrix, the rest copy the B matrix.
            size_t shmem_idx = warpId < (WARPS_PER_BLOCK/2) ? (M * (warpId % (WARPS_PER_BLOCK/2)) * 2) : 
                                                              (N * (warpId % (WARPS_PER_BLOCK/2)) * 2 + shmem_idx_b_off);

            // First half of the warp copies the first row / column of the matrix,
            // the second half of the warp copies the next.
            int4 *lane_ptr = (int4*)(warp_ptr + tile_k * K + (laneId / CHUNK_COPY_LINE_LANES) * K_GLOBAL) + (laneId % CHUNK_COPY_LINE_LANES);

            // Shift the second half of the warp to the next row / column in the shared memory.
            shmem_idx += laneId / CHUNK_COPY_LINE_LANES;

#pragma unroll
            for(int i = 0; i < ((WARP_SIZE/2) / CHUNK_COPY_LINES_PER_WARP) * 2; i++) {
                // Copy 16 bytes at once in each lane.
                *((int4*)&shmem[shmem_idx][0] + (laneId % CHUNK_COPY_LINE_LANES)) = *lane_ptr;

                // Advance the global memory pointer and the shared memory index.
                lane_ptr = (int4*)((half*)lane_ptr + K_GLOBAL * CHUNK_COPY_LINES_PER_WARP);
                shmem_idx += CHUNK_COPY_LINES_PER_WARP;
            }

            __syncthreads();

            // Compute a grid of C matrix tiles in each warp.
#pragma unroll
            for (int k_step = 0; k_step < CHUNK_K; k_step++) {
                wmma::fragment<wmma::matrix_a, M, N, K, half, wmma::row_major> a[WARP_COL_TILES];
                wmma::fragment<wmma::matrix_b, M, N, K, half, wmma::col_major> b[WARP_ROW_TILES];

#pragma unroll
                for (int i = 0; i < WARP_COL_TILES; i++) {
                    size_t shmem_idx_a = (warpId/2) * M * 2 + (i * M);
                    const half *tile_ptr = &shmem[shmem_idx_a][k_step * K];

                    wmma::load_matrix_sync(a[i], tile_ptr, K * CHUNK_K + SKEW_HALF);

#pragma unroll
                    for (int j = 0; j < WARP_ROW_TILES; j++) {
                        if (i == 0) {
                            // Load the B matrix fragment once, because it is going to be reused
                            // against the other A matrix fragments.
                            size_t shmem_idx_b = shmem_idx_b_off + (WARP_ROW_TILES * N) * (warpId%2) + (j * N);
                            const half *tile_ptr = &shmem[shmem_idx_b][k_step * K];

                            wmma::load_matrix_sync(b[j], tile_ptr, K * CHUNK_K + SKEW_HALF);
                        }

                        wmma::mma_sync(c[i][j], a[i], b[j], c[i][j]);
                    }
                }
            }

            __syncthreads();
        }

        // Store the D fragments to shared memory.
#pragma unroll
        for (int i = 0; i < WARP_COL_TILES; i++) {
#pragma unroll
            for (int j = 0; j < WARP_ROW_TILES; j++) {
#pragma unroll
                // Uniform, point-wise transformations of ALL fragment elements by ALL threads in the
                // warp are well-defined even though element indices within fragment storage are not defined.
                for (int t = 0; t < c[i][j].num_elements; t++)
                    c[i][j].x[t] *= alpha;

                float *tile_ptr = shmem_warp_tile_ptr + i * SHMEM_STRIDE * K + j * N;

                wmma::store_matrix_sync(tile_ptr, c[i][j], SHMEM_STRIDE, C_LAYOUT);
            }
        }

        __syncthreads();

        // Now that shared memory contains all the D tiles, stream them to global memory.
        float *dst_gmem_warp_stream_ptr = &D[gmem_idx];

#pragma unroll
        for (int i = 0; i < K; i++) {
            *((int4*)(dst_gmem_warp_stream_ptr + GLOBAL_MEM_STRIDE * i) + laneId) =
                *((int4*)(shmem_warp_stream_ptr + SHMEM_STRIDE * i) + laneId);
        }

        __syncthreads();
    }
}


#include "code.cu"

// Performs an MxNxK GEMM (C=alpha*A*B + beta*C) assuming:
//  1) Matrices are packed in memory.
//  2) M, N and K are multiples of 16. 
//  3) Neither A nor B are transposed.
// Note: This is a less performant version of the compute_gemm kernel. It is designed for
//       demonstration purposes only to show the CUDA WMMA API use without relying on
//       availability of the shared memory.
__global__ void simple_wmma_gemm(half *a, half *b, float *c, float *d, int m_ld, int n_ld, int k_ld, float alpha, float beta)
{
   // Leading dimensions. Packed with no transpositions.
   int lda = m_ld;
   int ldb = k_ld;
   int ldc = n_ld;

   // Tile using a 2D grid
   int warpM = (blockIdx.x * blockDim.x + threadIdx.x) / warpSize;
   int warpN = (blockIdx.y * blockDim.y + threadIdx.y);
 
   // Declare the fragments
   wmma::fragment<wmma::matrix_a, WMMA_M, WMMA_N, WMMA_K, half, wmma::row_major> a_frag;
   wmma::fragment<wmma::matrix_b, WMMA_M, WMMA_N, WMMA_K, half, wmma::col_major> b_frag;
   wmma::fragment<wmma::accumulator, WMMA_M, WMMA_N, WMMA_K, float> acc_frag;
   wmma::fragment<wmma::accumulator, WMMA_M, WMMA_N, WMMA_K, float> c_frag;

   wmma::fill_fragment(acc_frag, 0.0f);

   // Loop over k
   for (int i = 0; i < k_ld; i += WMMA_K) {
      int aCol = i; 
      int aRow = warpM * WMMA_M;

      int bCol = i;
      int bRow = warpN * WMMA_N;

      // Bounds checking
      if (aRow < m_ld && aCol < k_ld && bRow < k_ld && bCol < n_ld) {
         // Load the inputs
         wmma::load_matrix_sync(a_frag, a + aCol + aRow * lda, lda);
         wmma::load_matrix_sync(b_frag, b + bCol + bRow * ldb, ldb);
 
         // Perform the matrix multiplication
         wmma::mma_sync(acc_frag, a_frag, b_frag, acc_frag);

      }
   }

   // Load in the current value of c, scale it by beta, and add this our result scaled by alpha
   int cCol = warpN * WMMA_N;
   int cRow = warpM * WMMA_M;

   if (cRow < m_ld && cCol < n_ld) {
      wmma::load_matrix_sync(c_frag, c + cCol + cRow * ldc, ldc, wmma::mem_row_major);

      for(int i=0; i < c_frag.num_elements; i++) {
         c_frag.x[i] = alpha * acc_frag.x[i] + beta * c_frag.x[i];
      }

      // Store the output
      wmma::store_matrix_sync(d + cCol + cRow * ldc, c_frag, ldc, wmma::mem_row_major);
   }
}

__host__ void matMultiplyOnHost(half *A, half *B, float *C,
                                float alpha, float beta,
                                int numARows, int numAColumns,
                                int numBRows, int numBColumns,
                                int numCRows, int numCColumns)
{
    for (int i = 0; i < numCRows; i++) {
        for (int j = 0; j < numCColumns; j++) {
            float temp = 0.0;

            for (int k = 0; k < numAColumns; k++) {
                temp += (float)A[i * numAColumns + k] * (float)B[j * numBRows + k];
            }

            C[i*numCColumns + j] = temp * alpha + beta * C[i * numCColumns + j];
        }
    }
}

int main(int argc, char **argv)
{
    printf("Initializing...\n");

    int dev = findCudaDevice(argc, (const char **)argv);

    cudaDeviceProp deviceProp;
    checkCudaErrors(cudaGetDeviceProperties(&deviceProp, dev));

    // Tensor cores require a GPU of Volta (SM7X) architecture or higher.
    if (deviceProp.major < 7) {
        printf("cudaTensorCoreGemm requires requires SM 7.0 or higher to use Tensor Cores.  Exiting...\n");
        exit(EXIT_WAIVED);
    }

    printf("M: %d (%d x %d)\n", M_GLOBAL, M, M_TILES);
    printf("N: %d (%d x %d)\n", N_GLOBAL, N, N_TILES);
    printf("K: %d (%d x %d)\n", K_GLOBAL, K, K_TILES);

    half *A_h = NULL;
    half *B_h = NULL;
    float *C_h = NULL;

    half *A_new_h = NULL;
    half *B_new_h = NULL;

#if CPU_DEBUG
    float *result_hD = NULL;
    float *result_host = NULL;
#endif

    A_h = (half*) malloc(sizeof(half) * M_GLOBAL * K_GLOBAL);
    B_h = (half*) malloc(sizeof(half) * K_GLOBAL * N_GLOBAL);
    A_new_h = (half*) malloc(sizeof(half) * M_GLOBAL * K_GLOBAL);
    B_new_h = (half*) malloc(sizeof(half) * K_GLOBAL * N_GLOBAL);
    C_h = (float*) malloc(sizeof(float) * M_GLOBAL * N_GLOBAL);

    int* A_sparse_info_h = (int*)malloc(sizeof(int) * M_GLOBAL * K_GLOBAL / 32);
    int* A_tsize_info_h = (int*)malloc(sizeof(int) * M_GLOBAL * K_GLOBAL / (16*16));
    int* B_sparse_info_h = (int*)malloc(sizeof(int) * M_GLOBAL * K_GLOBAL / 32);
    int* B_tsize_info_h = (int*)malloc(sizeof(int) * M_GLOBAL * K_GLOBAL / (16*16));


#if CPU_DEBUG
    result_hD   = (float*) malloc(sizeof(float) * M_GLOBAL * N_GLOBAL);
    result_host = (float*) malloc(sizeof(float) * M_GLOBAL * N_GLOBAL);
#endif

    half *A = NULL;
    half *B = NULL;
    half *A_new = NULL;
    half *B_new = NULL;
    int *A_sparse_info = NULL;
    int *A_tsize_info = NULL;
    int *B_sparse_info = NULL;
    int *B_tsize_info = NULL;
    float *C = NULL;
    float *D = NULL;

    checkCudaErrors(cudaMalloc((void**)&A, sizeof(half) * M_GLOBAL * K_GLOBAL));
    checkCudaErrors(cudaMalloc((void**)&B, sizeof(half) * N_GLOBAL * K_GLOBAL));
    checkCudaErrors(cudaMalloc((void**)&A_new, sizeof(half) * M_GLOBAL * K_GLOBAL));
    checkCudaErrors(cudaMalloc((void**)&B_new, sizeof(half) * N_GLOBAL * K_GLOBAL));
    checkCudaErrors(cudaMalloc((void**)&A_sparse_info, sizeof(int) * M_GLOBAL * K_GLOBAL / 32));
    checkCudaErrors(cudaMalloc((void**)&A_tsize_info, sizeof(int) * N_GLOBAL * K_GLOBAL / (16*16)));
    checkCudaErrors(cudaMalloc((void**)&B_sparse_info, sizeof(int) * M_GLOBAL * K_GLOBAL / 32));
    checkCudaErrors(cudaMalloc((void**)&B_tsize_info, sizeof(int) * N_GLOBAL * K_GLOBAL / (16*16)));

    checkCudaErrors(cudaMalloc((void**)&C, sizeof(float) * M_GLOBAL * N_GLOBAL));
    checkCudaErrors(cudaMalloc((void**)&D, sizeof(float) * M_GLOBAL * N_GLOBAL));

    assert(((unsigned long long)A) % 128 == 0);
    assert(((unsigned long long)B) % 128 == 0);
    assert(((unsigned long long)C) % 128 == 0);
    assert(((unsigned long long)D) % 128 == 0);

    init_host_matrices(A_h, B_h, C_h, A_new_h, B_new_h, A_sparse_info_h, A_tsize_info_h, B_sparse_info_h, B_tsize_info_h);


    

    printf("Preparing data for GPU...\n");

    checkCudaErrors(cudaMemcpy(A, A_h, sizeof(half) * M_GLOBAL * K_GLOBAL, cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy(B, B_h, sizeof(half) * N_GLOBAL * K_GLOBAL, cudaMemcpyHostToDevice));

    checkCudaErrors(cudaMemcpy(A_new, A_new_h, sizeof(half) * M_GLOBAL * K_GLOBAL, cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy(B_new, B_new_h, sizeof(half) * N_GLOBAL * K_GLOBAL, cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy(A_sparse_info, A_sparse_info_h, sizeof(int) * M_GLOBAL * K_GLOBAL / 32, cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy(A_tsize_info, A_tsize_info_h, sizeof(int) * N_GLOBAL * K_GLOBAL / (16*16), cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy(B_sparse_info, B_sparse_info_h, sizeof(int) * M_GLOBAL * K_GLOBAL / 32, cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemcpy(B_tsize_info, B_tsize_info_h, sizeof(int) * N_GLOBAL * K_GLOBAL / (16*16), cudaMemcpyHostToDevice));


    checkCudaErrors(cudaMemcpy(C, C_h, sizeof(float) * M_GLOBAL * N_GLOBAL, cudaMemcpyHostToDevice));
    checkCudaErrors(cudaMemset(D, 0, sizeof(float) * M_GLOBAL * N_GLOBAL));

    enum {
        // Compute the right amount of shared memory to request.
        // We need shared memory to hold per-CTA C and D matrix tiles, and to cache per-CTA chunks
        // of the A and B matrices. Therefore, the right amount to request is the maximum of those
        // two numbers.
        SHMEM_SZ = MAX(sizeof(half) * (BLOCK_COL_TILES * M) * (CHUNK_K * K + SKEW_HALF) * 2,
                       M * (BLOCK_ROW_WARPS * WARP_ROW_TILES) * N * (BLOCK_COL_WARPS * WARP_COL_TILES) * sizeof(float))
    };

    printf("Required shared memory size: %lu Kb\n", SHMEM_SZ / 1024UL);

    const float alpha = 1.1f;
    const float beta = 1.2f;

    cudaEvent_t start, stop;

    checkCudaErrors(cudaEventCreate(&start));    
    checkCudaErrors(cudaEventCreate(&stop));
    checkCudaErrors(cudaEventRecord(start));

    // If enough shared memory available on the GPU use high performant kernel
    if (deviceProp.sharedMemPerMultiprocessor >= SHMEM_SZ)
    {
        printf("Computing... using high performance kernel compute_gemm \n");

        checkCudaErrors(cudaFuncSetAttribute(compute_gemm, cudaFuncAttributeMaxDynamicSharedMemorySize, SHMEM_SZ));
        checkKernelErrors((compute_gemm<<<deviceProp.multiProcessorCount, THREADS_PER_BLOCK, SHMEM_SZ>>>(A, B, C, D, alpha, beta)));
#if CPU_DEBUG
        checkCudaErrors(cudaMemcpy(result_hD, D, sizeof(float)*M_GLOBAL*N_GLOBAL, cudaMemcpyDeviceToHost));
#endif
    }
    else
    {
        dim3 gridDim;
        dim3 blockDim;
     
        // blockDim.x must be a multple of warpSize
        // 128x4 means we have 16 warps and a block computes a 64x64 output tile
        blockDim.x = 128;
        blockDim.y = 4;

        gridDim.x = (M_GLOBAL + (WMMA_M * blockDim.x / 32 - 1)) / (WMMA_M * blockDim.x / 32);
        gridDim.y = (N_GLOBAL + WMMA_N * blockDim.y - 1) / (WMMA_N * blockDim.y);

        printf("Computing... using simple_wmma_gemm kernel\n");
        simple_wmma_gemm<<<gridDim, blockDim>>>(A, B, C, D, M_GLOBAL, N_GLOBAL, K_GLOBAL, alpha, beta);
#if CPU_DEBUG
        checkCudaErrors(cudaMemcpy(result_hD, D, sizeof(float) * M_GLOBAL * N_GLOBAL, cudaMemcpyDeviceToHost));
#endif
    }

    checkCudaErrors(cudaEventRecord(stop));
    checkCudaErrors(cudaEventSynchronize(stop));

#if CPU_DEBUG
    printf("Verifying correctness of the computations...\n");

    memcpy(result_host, C_h, sizeof(float) * M_GLOBAL * N_GLOBAL);

    matMultiplyOnHost(A_h, B_h, result_host,
                      alpha, beta,
                      M_GLOBAL, K_GLOBAL,
                      K_GLOBAL, N_GLOBAL,
                      M_GLOBAL, N_GLOBAL);

    for (int i = 0; i < N_GLOBAL * M_GLOBAL; i++) {
        if (fabs(result_hD[i] - result_host[i]) > 0.1f)
            printf("mismatch i=%d result_hD=%f result_host=%f\n", i, result_hD[i], result_host[i]);
    }
    free(result_hD);
    free(result_host);
#endif

    float milliseconds = 0;

    checkCudaErrors(cudaEventElapsedTime(&milliseconds, start, stop));

    printf("Time: %f ms\n", milliseconds);
    printf("TFLOPS: %.2f\n", (((double)M_GLOBAL * N_GLOBAL * K_GLOBAL * 2)/(milliseconds/1000.)) / 1e12);

    free(A_h);
    free(B_h);
    free(C_h);
    checkCudaErrors(cudaFree((void*)A));
    checkCudaErrors(cudaFree((void*)B));
    checkCudaErrors(cudaFree((void*)C));
    checkCudaErrors(cudaFree((void*)D));

    return 0;
}
