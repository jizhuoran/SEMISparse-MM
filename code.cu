
__global__ void semi_sparse(const half *A, const half *B, const float *C, float *D, 
    const half *A_new, const half *B_new, 
    const int *A_sparse_info, const int *A_tsize_info, 
    const int *B_sparse_info, const int *B_tsize_info, 
    float alpha, float beta)
{
    extern __shared__ half shmem[][CHUNK_K * K + SKEW_HALF];

////////////SJ/////////////////
    half temp_store[64] = {.0}; //only use 32 regs
////////////SJ/////////////////


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

////////////SJ/////////////////
        const int *warp_sparse_ptr = (warpId < 4) ? (&A[block_tile_i * (K_GLOBAL/4)] + (K_GLOBAL/4) * (warpId % 4) * 2) :
            (&B[block_tile_j * (K_GLOBAL/4)] + (K_GLOBAL/4) * (warpId % 4) * 2);
        const int *warp_size_ptr = (warpId < 4) ? (&A[block_tile_i * (K_GLOBAL/16)] + (K_GLOBAL/16) * (warpId % 4) * 2) :
            (&B[block_tile_j * (K_GLOBAL/16)] + (K_GLOBAL/16) * (warpId % 4) * 2);
////////////SJ/////////////////


        
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

////////////SJ/////////////////
            // Copy 16 bytes at once in each lane.

            int sparse_info1 = warp_sparse_ptr[laneId];
            int sparse_info2 = warp_sparse_ptr[laneId + (K_GLOBAL/4)];
            
            int each_size1 = 0;
            int each_size2 = 0;
            if (laneId < 8) {
                each_size1 = warp_sparse_ptr[laneId];
                each_size2 = warp_sparse_ptr[laneId + (K_GLOBAL/16)];
            }


            for(int i = 0; i < 64; i++) {
                // Copy 16 bytes at once in each lane.
                temp_store[i] = *lane_ptr+each_size1;
                // Advance the global memory pointer and the shared memory index.
                lane_ptr = (int4*)((half*)lane_ptr + 32);
                shmem_idx += CHUNK_COPY_LINES_PER_WARP;
            }

            for(int i = 0; i < sparse_info1; ++i) {
                bool ac = (sparse_info1[i] >> laneId) & 0x1;
                if(ac) {
                    *((half*)&shmem[shmem_idx][0] + laneId) = temp_store[i];
                }
            }

            for(int i = 0; i < SIZE2; i++) {
                // Copy 16 bytes at once in each lane.

                *((half*)&shmem[shmem_idx][0] + laneId) = *lane_ptr+each_size2;
                // Advance the global memory pointer and the shared memory index.
                lane_ptr = (int4*)((half*)lane_ptr + 32);
                shmem_idx += CHUNK_COPY_LINES_PER_WARP;
            }

            for(int i = 0; i < sparse_info1; ++i) {
                bool ac = (sparse_info1[i] >> laneId) & 0x1;
                if(ac) {
                    *((half*)&shmem[shmem_idx][0] + laneId) = temp_store[i];
                }
            }

////////////SJ/////////////////



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