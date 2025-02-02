/*
 * Copyright (C) by Argonne National Laboratory
 *     See COPYRIGHT in top-level directory
 */

#include <mpi.h>
#include <stdio.h>
#include <assert.h>

#define CHECK_RESULT(i, result, expected, msg) \
    do { \
        if (result != expected) { \
            printf("%s: i = %d, expect %d, got %d\n", msg, i, expected, result); \
            errs++; \
        } \
    } while (0)

int main(void)
{
    int errs = 0;

    cudaStream_t stream;
    cudaStreamCreate(&stream);

    int mpi_errno;
    int rank, size;
    MPI_Init(NULL, NULL);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    int expected_sum = size * (size - 1) / 2;

    MPI_Info info;
    MPI_Info_create(&info);
    MPI_Info_set(info, "type", "cudaStream_t");
    MPIX_Info_set_hex(info, "value", &stream, sizeof(stream));

    MPIX_Stream mpi_stream;
    MPIX_Stream_create(info, &mpi_stream);

    MPI_Info_free(&info);

    MPI_Comm stream_comm;
    MPIX_Stream_comm_create(MPI_COMM_WORLD, mpi_stream, &stream_comm);

#define N 10    
    /* TEST 1 - MPI_INT */
    int buf[N];
    void *d_buf, *d_result_buf;
    cudaMalloc(&d_buf, sizeof(buf));
    cudaMalloc(&d_result_buf, sizeof(buf));

    for (int i = 0; i < N; i++) {
        buf[i] = rank;
    }

    cudaMemcpyAsync(d_buf, buf, sizeof(buf), cudaMemcpyHostToDevice, stream);
    mpi_errno = MPIX_Allreduce_enqueue(d_buf, d_result_buf, N, MPI_INT, MPI_SUM, stream_comm);
    assert(mpi_errno == MPI_SUCCESS);
    cudaMemcpyAsync(buf, d_result_buf, sizeof(buf), cudaMemcpyDeviceToHost, stream);
    cudaStreamSynchronize(stream);

    cudaFree(d_buf);
    cudaFree(d_result_buf);

    for (int i = 0; i < N; i++) {
        CHECK_RESULT(i, buf[i], expected_sum, "TEST 1");
    }

    /* TEST 2 - MPI_SHORT_INT (typically non-contig) */
    struct {
        short a;
        int b;
    } buf2[N];
    cudaMalloc(&d_buf, sizeof(buf2));
    cudaMalloc(&d_result_buf, sizeof(buf2));

    for(int i = 0; i < N; i++) {
        /* MINLOC result should be {0, i % size} */
        if (i % size == rank) {
            buf2[i].a = 0;
        } else {
            buf2[i].a = rank + 1;
        }
        buf2[i].b = rank;
    }

    cudaMemcpyAsync(d_buf, buf2, sizeof(buf2), cudaMemcpyHostToDevice, stream);
    mpi_errno = MPIX_Allreduce_enqueue(d_buf, d_result_buf, N, MPI_SHORT_INT, MPI_MINLOC, stream_comm);
    assert(mpi_errno == MPI_SUCCESS);
    cudaMemcpyAsync(buf2, d_result_buf, sizeof(buf2), cudaMemcpyDeviceToHost, stream);
    cudaStreamSynchronize(stream);

    for (int i = 0; i < N; i++) {
        CHECK_RESULT(i, buf2[i].a, 0, "TEST 2");
        CHECK_RESULT(i, buf2[i].b, i % size, "TEST 2");
    }

    /* clean up */
    MPI_Comm_free(&stream_comm);
    MPIX_Stream_free(&mpi_stream);

    cudaStreamDestroy(stream);

    int tot_errs;
    MPI_Reduce(&errs, &tot_errs, 1, MPI_INT, MPI_SUM, 0, MPI_COMM_WORLD);
    if (rank == 0) {
        if (tot_errs == 0) {
            printf("No Errors\n");
        } else {
            printf("%d Errors\n", tot_errs);
        }
    }

    MPI_Finalize();
    return errs;
}
