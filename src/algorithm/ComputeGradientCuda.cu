#include "ComputeGradientCuda.hpp"
#include <iostream>
#include <memory>

#include <cuda_runtime.h>
#include <device_launch_parameters.h>

#include <thrust/device_vector.h>
#include <thrust/device_ptr.h>


__global__ void gradient(float *input, size_t x_num, size_t y_num, size_t z_num, float *grad, size_t x_num_ds, size_t y_num_ds, float hx, float hy, float hz) {
    int xi = ((blockIdx.x * blockDim.x) + threadIdx.x) * 2;
    int yi = ((blockIdx.y * blockDim.y) + threadIdx.y) * 2;
    int zi = ((blockIdx.z * blockDim.z) + threadIdx.z) * 2;
    if (xi >= x_num || yi >= y_num || zi >= z_num) return;

    const size_t xnumynum = x_num * y_num;

    float temp[4][4][4];

    for (int z = 0; z < 4; ++z)
        for (int x = 0; x < 4; ++x)
            for(int y = 0; y < 4; ++y) {
                int xc = xi + x - 1; if (xc < 0) xc = 0; else if (xc >= x_num) xc = x_num - 1;
                int yc = yi + y - 1; if (yc < 0) yc = 0; else if (yc >= y_num) yc = y_num - 1;
                int zc = zi + z - 1; if (zc < 0) zc = 0; else if (zc >= z_num) zc = z_num - 1;
                temp[z][x][y] = *(input + zc * xnumynum + xc * y_num + yc);
            }
    float maxGrad = 0;
    for (int z = 1; z <= 2; ++z)
        for (int x = 1; x <= 2; ++x)
            for(int y = 1; y <= 2; ++y) {
                float xd = (temp[z][x-1][y] - temp[z][x+1][y]) / (2 * hx); xd = xd * xd;
                float yd = (temp[z-1][x][y] - temp[z+1][x][y]) / (2 * hy); yd = yd * yd;
                float zd = (temp[z][x][y-1] - temp[z][x][y+1]) / (2 * hz); zd = zd * zd;
                float gm = __fsqrt_rn(xd + yd + zd);
                if (gm > maxGrad)  maxGrad = gm;
            }

    const size_t idx = zi/2 * x_num_ds * y_num_ds + xi/2 * y_num_ds + yi/2;
    grad[idx] = maxGrad;
}

void cudaDownsampledGradient(const MeshData<float> &input, MeshData<float> &grad, const float hx, const float hy,const float hz) {
    APRTimer timer;
    timer.verbose_flag=true;

    timer.start_timer("cuda: memory alloc + data transfer to device");
    size_t inputSize = input.mesh.size() * sizeof(float);
    float *cudaInput;
    cudaMalloc(&cudaInput, inputSize);
    cudaMemcpy(cudaInput, input.mesh.get(), inputSize, cudaMemcpyHostToDevice);

    size_t gradSize = grad.mesh.size() * sizeof(float);
    float *cudaGrad;
    cudaMalloc(&cudaGrad, gradSize);
    timer.stop_timer();

    timer.start_timer("cuda: calculations on device");
    dim3 threadsPerBlock(4, 4, 4);
    dim3 numBlocks((input.x_num + threadsPerBlock.x - 1)/threadsPerBlock.x,
                   (input.y_num + threadsPerBlock.y - 1)/threadsPerBlock.y,
                   (input.z_num + threadsPerBlock.z - 1)/threadsPerBlock.z);
    std::cout << "Number of blocks  (x/y/z):  " << numBlocks.x << "/" << numBlocks.y << "/" << numBlocks.z << std::endl;
    std::cout << "Number of threads (x/y/z): " << threadsPerBlock.x << "/" << threadsPerBlock.y << "/" << threadsPerBlock.z << std::endl;

    gradient<<<numBlocks,threadsPerBlock>>>(cudaInput, input.x_num, input.y_num, input.z_num, cudaGrad, grad.x_num, grad.y_num, hx, hy, hz);
    cudaDeviceSynchronize();
    timer.stop_timer();

    timer.start_timer("cuda: transfer data from device and freeing memory");
    cudaError_t err = cudaGetLastError();
    if (err != cudaSuccess)printf("Error: %s\n", cudaGetErrorString(err));
    cudaMemcpy((void*)input.mesh.get(), cudaInput, inputSize, cudaMemcpyDeviceToHost);
    cudaFree(cudaInput);
    cudaMemcpy((void*)grad.mesh.get(), cudaGrad, gradSize, cudaMemcpyDeviceToHost);
    cudaFree(cudaGrad);
    timer.stop_timer();
}

/////////////////////////////////////////////////////////////////////


float impulse_resp(float k,float rho,float omg){
    //  Impulse Response Function
    return (pow(rho,(std::abs(k)))*sin((std::abs(k) + 1)*omg)) / sin(omg);
}

float impulse_resp_back(float k,float rho,float omg,float gamma,float c0){
    //  Impulse Response Function (nominator eq. 4.8, denominator from eq. 4.7)
    return c0*pow(rho,std::abs(k))*(cos(omg*std::abs(k)) + gamma*sin(omg*std::abs(k)))*(1.0/(pow((1 - 2.0*rho*cos(omg) + pow(rho,2)),2)));
}


typedef struct {
    std::vector<float> bc1_vec;
    std::vector<float> bc2_vec;
    std::vector<float> bc3_vec;
    std::vector<float> bc4_vec;
    size_t k0;
    float b1;
    float b2;
    float norm_factor;
} BsplineParams;

template <typename T>
BsplineParams prepareBsplineStuff(MeshData<T> & image, float lambda, float tol) {
    float xi = 1 - 96*lambda + 24*lambda*sqrt(3 + 144*lambda); // eq 4.6
    float rho = (24*lambda - 1 - sqrt(xi))/(24*lambda)*sqrt((1/xi)*(48*lambda + 24*lambda*sqrt(3 + 144*lambda))); // eq 4.5
    float omg = atan(sqrt((1/xi)*(144*lambda - 1))); // eq 4.6

    float c0 = (1+ pow(rho,2))/(1-pow(rho,2)) * (1 - 2*rho*cos(omg) + pow(rho,2))/(1 + 2*rho*cos(omg) + pow(rho,2)); // eq 4.8
    float gamma = (1-pow(rho,2))/(1+pow(rho,2)) * (1/tan(omg)); // eq 4.8

    const float b1 = 2*rho*cos(omg);
    const float b2 = -pow(rho,2.0);

    const size_t z_num = image.z_num;
    const size_t xxx = ceil(std::abs(log(tol)/log(rho)));
    const size_t k0 = std::max( std::min(xxx, z_num), (size_t)2);

    const float norm_factor = pow((1 - 2.0*rho*cos(omg) + pow(rho,2)),2);

    //////////////////////////////////////////////////////////////
    //
    //  Setting up boundary conditions
    //
    //////////////////////////////////////////////////////////////

    // for boundaries
    std::cout << "k0=" << k0 << std::endl;
    std::vector<float> impulse_resp_vec_f(k0+3);  //forward
    for (size_t k = 0; k < (k0+3); ++k) {
        impulse_resp_vec_f[k] = impulse_resp(k,rho,omg);
    }

    std::vector<float> impulse_resp_vec_b(k0+3);  //backward
    for (size_t k = 0; k < (k0+3); ++k) {
        impulse_resp_vec_b[k] = impulse_resp_back(k,rho,omg,gamma,c0);
    }

    std::vector<float> bc1_vec(k0, 0);  //forward
    //y(1) init
    bc1_vec[1] = impulse_resp_vec_f[0];
    for (size_t k = 0; k < k0; ++k) {
        bc1_vec[k] += impulse_resp_vec_f[k+1];
    }

    std::vector<float> bc2_vec(k0, 0);  //backward
    //y(0) init
    for (size_t k = 0; k < k0; ++k) {
        bc2_vec[k] = impulse_resp_vec_f[k];
    }

    std::vector<float> bc3_vec(k0, 0);  //forward
    //y(N-1) init
    bc3_vec[0] = impulse_resp_vec_b[1];
    for (size_t k = 0; k < (k0-1); ++k) {
        bc3_vec[k+1] += impulse_resp_vec_b[k] + impulse_resp_vec_b[k+2];
    }

    std::vector<float> bc4_vec(k0, 0);  //backward
    //y(N) init
    bc4_vec[0] = impulse_resp_vec_b[0];
    for (size_t k = 1; k < k0; ++k) {
        bc4_vec[k] += 2*impulse_resp_vec_b[k];
    }

    return BsplineParams {
            bc1_vec,
            bc2_vec,
            bc3_vec,
            bc4_vec,
            k0,
            b1,
            b2,
            norm_factor
    };
}

// ========== First naive version following CPU code ===============
//__global__ void bsplineY(float *image, size_t x_num, size_t y_num, size_t z_num, float *bc1_vec, float *bc2_vec, float *bc3_vec, float *bc4_vec, size_t k0, float b1, float b2, float norm_factor) {
//    int xi = ((blockIdx.x * blockDim.x) + threadIdx.x);
//    int zi = ((blockIdx.z * blockDim.z) + threadIdx.z);
//
//    //forwards direction
//    const size_t zPlaneOffset = zi * x_num * y_num;
//    const size_t yColOffset = xi * y_num;
//    size_t yCol = zPlaneOffset + yColOffset;
//
//    float temp1 = 0;
//    float temp2 = 0;
//    float temp3 = 0;
//    float temp4 = 0;
//
//    for (size_t k = 0; k < k0; ++k) {
//        temp1 += bc1_vec[k]*image[yCol + k];
//        temp2 += bc2_vec[k]*image[yCol + k];
//        temp3 += bc3_vec[k]*image[yCol + y_num - 1 - k];
//        temp4 += bc4_vec[k]*image[yCol + y_num - 1 - k];
//    }
//
//    //initialize the sequence
//    image[yCol + 0] = temp2;
//    image[yCol + 1] = temp1;
//
//    // middle values
//    for (auto it = (image + yCol + 2); it !=  (image+yCol + y_num); ++it) {
//        float  temp = temp1*b1 + temp2*b2 + *it;
//        *it = temp;
//        temp2 = temp1;
//        temp1 = temp;
//    }
//
//    // finish sequence
//    image[yCol + y_num - 2] = temp3;
//    image[yCol + y_num - 1] = temp4;
//
//    // -------------- part 2
//    temp2 = image[yCol + y_num - 1];
//    temp1 = image[yCol + y_num - 2];
//    image[yCol + y_num - 1]*=norm_factor;
//    image[yCol + y_num - 2]*=norm_factor;
//
//    for (auto it = (image + yCol + y_num-3); it !=  (image + yCol - 1); --it) {
//        float temp = temp1*b1 + temp2*b2 + *it;
//        *it = temp*norm_factor;
//        temp2 = temp1;
//        temp1 = temp;
//    }
//}

extern __shared__ float sharedMem[];
template<typename T>
__global__ void bsplineYdirBoundary(T *image, size_t x_num, size_t y_num, size_t z_num, float *bc1_vec,
                                    float *bc2_vec, float *bc3_vec, float *bc4_vec, size_t k0, float b1, float b2,
                                    float norm_factor, float *boundary) {
    const int xi = (blockIdx.x * blockDim.x) + threadIdx.x;
    const int xw = (blockIdx.x * blockDim.x);

    const int numOfWorkers = blockDim.x;
    const int currentWorkerId = threadIdx.x;
    const size_t workersOffset = xw * y_num;

    float *bc1_vec2 = &sharedMem[0];
    float *bc2_vec2 = &bc1_vec2[k0];
    T *cache = (T*)&bc2_vec2[k0];

    for (int xOfWorker = 0; xOfWorker < numOfWorkers && xOfWorker + xw < x_num * z_num; ++xOfWorker) {
        size_t currWorkerOffset = xOfWorker * y_num;
        for (int i = currentWorkerId; i < k0; i += numOfWorkers) {
            cache[xOfWorker * k0 + i] = image[workersOffset + currWorkerOffset + i];
            if (xOfWorker == 0) {
                bc1_vec2[i] = bc1_vec[i];
                bc2_vec2[i] = bc2_vec[i];
            }
        }
    }
    __syncthreads();

    //forwards direction
    if (xi < x_num * z_num) {
        float temp1 = 0;
        float temp2 = 0;
        for (size_t k = 0; k < k0; ++k) {
            temp1 += bc1_vec2[k] * cache[currentWorkerId * k0 + k];
            temp2 += bc2_vec2[k] * cache[currentWorkerId * k0 + k];
        }
        boundary[xi*4 + 0] = temp2;
        boundary[xi*4 + 1] = temp1;

        //initialize the sequence
        cache[currentWorkerId * k0 + 0] = temp2;
        cache[currentWorkerId * k0 + 1] = temp1;
    }

    for (int xOfWorker = 0; xOfWorker < numOfWorkers && xOfWorker + xw < x_num * z_num; ++xOfWorker) {
        size_t currWorkerOffset = xOfWorker * y_num;
        for (int i = currentWorkerId; i < 2; i += numOfWorkers) {
            image[workersOffset + currWorkerOffset + i] = cache[xOfWorker * k0 + i];
        }
    }

    // ----------------- second end
    __syncthreads();

    for (int xOfWorker = 0; xOfWorker < numOfWorkers && xOfWorker + xw < x_num * z_num; ++xOfWorker) {
        size_t currWorkerOffset = xOfWorker * y_num;
        for (int i = currentWorkerId; i < k0; i += numOfWorkers) {
            cache[xOfWorker * k0 + i] = image[workersOffset + currWorkerOffset + y_num - 1 - i];
            if (xOfWorker == 0) {
                bc1_vec2[i] = bc3_vec[i];
                bc2_vec2[i] = bc4_vec[i];
            }
        }
    }
    __syncthreads();

    //forwards direction
    if (xi < x_num * z_num) {
        float temp3 = 0;
        float temp4 = 0;
        for (size_t k = 0; k < k0; ++k) {
            temp3 += bc1_vec2[k] * cache[currentWorkerId * k0 + k];
            temp4 += bc2_vec2[k] * cache[currentWorkerId * k0 + k];
        }
        boundary[xi*4 + 2] = temp3;
        boundary[xi*4 + 3] = temp4;

        //initialize the sequence
        cache[currentWorkerId * k0 + 1] = temp3;
        cache[currentWorkerId * k0 + 0] = temp4;
    }

    for (int xOfWorker = 0; xOfWorker < numOfWorkers && xOfWorker + xw < x_num * z_num; ++xOfWorker) {
        size_t currWorkerOffset = xOfWorker * y_num;
        for (int i = currentWorkerId; i < 2; i += numOfWorkers) {
            image[workersOffset + currWorkerOffset + y_num -1 - i] = cache[xOfWorker * k0 + i];
        }
    }

}

constexpr int blockWidth = 32;
constexpr int numOfThreads = 64;
extern __shared__ char sharedMemProcess[];
template<typename T>
__global__ void bsplineYdirProcess(T *image, const size_t x_num, const size_t y_num, const size_t z_num, size_t k0,
                                   const float b1, const float b2, const float norm_factor, float *boundary) {
    const int numOfWorkers = blockDim.x;
    const int currentWorkerId = threadIdx.x;
    const int xzOffset = blockIdx.x * blockDim.x;
    const int64_t maxXZoffset = x_num * z_num;
    const int64_t workersOffset = xzOffset * y_num;

    T (*cache)[blockWidth + 1] = (T (*)[blockWidth + 1]) &sharedMemProcess[0];

    float temp1, temp2;
    for (int yBlockBegin = 0; yBlockBegin < y_num - 2; yBlockBegin += blockWidth) {

        // Read from global mem to cache
        for (int i = currentWorkerId; i < blockWidth * numOfWorkers; i += numOfWorkers) {
            int offs = i % blockWidth;
            int work = i / blockWidth;
            if (offs + yBlockBegin < (y_num - 2) && work + xzOffset < maxXZoffset) {
                cache[work][offs] = image[workersOffset + y_num * work + offs + yBlockBegin];
            }
        }
        __syncthreads();

        // Do operations
        if (xzOffset + currentWorkerId < maxXZoffset) {
            if (yBlockBegin == 0) {
                temp2 = boundary[(xzOffset + currentWorkerId) * 4 + 0];
                temp1 = boundary[(xzOffset + currentWorkerId) * 4 + 1];
            }
            for (size_t k = yBlockBegin == 0 ? 2 : 0; k < blockWidth && k + yBlockBegin < y_num - 2; ++k) {
                float  temp = temp1*b1 + temp2*b2 + cache[currentWorkerId][k];
                cache[currentWorkerId][k] = temp;
                temp2 = temp1;
                temp1 = temp;
            }
        }
        __syncthreads();

        // Write from cache to global mem
        for (int i = currentWorkerId; i < blockWidth * numOfWorkers; i += numOfWorkers) {
            int offs = i % blockWidth;
            int work = i / blockWidth;
            if (offs + yBlockBegin < (y_num - 2) && work + xzOffset < maxXZoffset) {
                image[workersOffset + y_num * work + offs + yBlockBegin] = cache[work][offs];
            }
        }
        __syncthreads();
    }

    for (int yBlockBegin = y_num - 1; yBlockBegin >= 0; yBlockBegin -= blockWidth) {

        // Read from global mem to cache
        for (int i = currentWorkerId; i < blockWidth * numOfWorkers; i += numOfWorkers) {
            int offs = i % blockWidth;
            int work = i / blockWidth;
            if (yBlockBegin - offs >= 0 && work + xzOffset < maxXZoffset) {
                cache[work][offs] = image[workersOffset + y_num * work - offs + yBlockBegin];
            }
        }
        __syncthreads();

        // Do operations
        if (xzOffset + currentWorkerId < maxXZoffset) {
            if (yBlockBegin == y_num - 1) {
                temp2 = boundary[(xzOffset + currentWorkerId) * 4 + 3];
                temp1 = boundary[(xzOffset + currentWorkerId) * 4 + 2];
                cache[currentWorkerId][0] *= norm_factor;
                cache[currentWorkerId][1] *= norm_factor;
            }
            for (int64_t k = yBlockBegin == y_num - 1 ? 2 : 0; k < blockWidth && yBlockBegin - k >= 0; ++k) {
                float  temp = temp1*b1 + temp2*b2 + cache[currentWorkerId][k];
                cache[currentWorkerId][k] = temp * norm_factor;
                temp2 = temp1;
                temp1 = temp;
            }
        }
        __syncthreads();

        // Write from cache to global mem
        for (int i = currentWorkerId; i < blockWidth * numOfWorkers; i += numOfWorkers) {
            int offs = i % blockWidth;
            int work = i / blockWidth;
            if (yBlockBegin - offs >= 0 && work + xzOffset < maxXZoffset) {
                image[workersOffset + y_num * work - offs + yBlockBegin] = cache[work][offs];
            }
        }
        __syncthreads();
    }

}

template <typename ImgType>
void cudaFilterBsplineYdirection(MeshData<ImgType> &input, float lambda, float tolerance) {
    APRTimer timer;
    timer.verbose_flag=true;

    BsplineParams p = prepareBsplineStuff(input, lambda, tolerance);

    timer.start_timer("cuda: memory alloc + data transfer to device");
    size_t inputSize = input.mesh.size() * sizeof(ImgType);
    ImgType *cudaInput;
    cudaMalloc(&cudaInput, inputSize);
    cudaMemcpy(cudaInput, input.mesh.get(), inputSize, cudaMemcpyHostToDevice);
    float *boundary;
    int boundaryLen = sizeof(float) * 4 * input.x_num * input.z_num;
    cudaMalloc(&boundary, boundaryLen);

    thrust::device_vector<float> d_bc1_vec(p.bc1_vec);
    thrust::device_vector<float> d_bc2_vec(p.bc2_vec);
    thrust::device_vector<float> d_bc3_vec(p.bc3_vec);
    thrust::device_vector<float> d_bc4_vec(p.bc4_vec);
    timer.stop_timer();

    cudaDeviceSetCacheConfig(cudaFuncCachePreferShared);
    cudaDeviceSetSharedMemConfig(cudaSharedMemBankSizeFourByte);

    dim3 threadsPerBlock(numOfThreads, 1, 1);
    dim3 numBlocks((input.x_num * input.z_num + threadsPerBlock.x - 1)/threadsPerBlock.x,
                   1,
                   1);
    std::cout << "Number of blocks  (x/y/z):  " << numBlocks.x << "/" << numBlocks.y << "/" << numBlocks.z << std::endl;
    std::cout << "Number of threads (x/y/z): " << threadsPerBlock.x << "/" << threadsPerBlock.y << "/" << threadsPerBlock.z << std::endl;

    float *bc1 = thrust::raw_pointer_cast(d_bc1_vec.data());
    float *bc2 = thrust::raw_pointer_cast(d_bc2_vec.data());
    float *bc3 = thrust::raw_pointer_cast(d_bc3_vec.data());
    float *bc4 = thrust::raw_pointer_cast(d_bc4_vec.data());

    timer.start_timer("cuda: calculations on device ============================================================================ ");
    bsplineYdirBoundary<ImgType> <<<numBlocks,threadsPerBlock, (2 /*bc vectors*/) * (p.k0) * sizeof(float) + numOfThreads * (p.k0) * sizeof(ImgType)>>>(cudaInput, input.x_num, input.y_num, input.z_num, bc1, bc2, bc3, bc4, p.k0, p.b1, p.b2, p.norm_factor, boundary);
    float *boundaryHost = new float[boundaryLen]; //TODO: free it
    cudaMemcpy(boundaryHost, boundary, boundaryLen, cudaMemcpyDeviceToHost);
    bsplineYdirProcess<ImgType> <<<numBlocks,threadsPerBlock,numOfThreads * (1 + blockWidth) * sizeof(ImgType)>>>(cudaInput, input.x_num, input.y_num, input.z_num, p.k0, p.b1, p.b2, p.norm_factor, boundary);
    delete[] boundaryHost;
    cudaDeviceSynchronize();
    timer.stop_timer();

    timer.start_timer("cuda: transfer data from device and freeing memory");
    cudaError_t err = cudaGetLastError();
    if (err != cudaSuccess)printf("Error: %s\n", cudaGetErrorString(err));

    cudaMemcpy((void*)input.mesh.get(), cudaInput, inputSize, cudaMemcpyDeviceToHost);
    cudaFree(cudaInput);
    timer.stop_timer();
}

void emptyCallForTemplateInstantiation() {
    MeshData<float> f = MeshData<float>(0,0,0);
    cudaFilterBsplineYdirection(f, 3, 0.1);
    MeshData<uint16_t> u16 = MeshData<uint16_t>(0,0,0);
    cudaFilterBsplineYdirection(u16, 3, 0.1);
}