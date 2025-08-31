#ifndef MarchingCubesColorBlobParams_h
#define MarchingCubesColorBlobParams_h
#include <simd/simd.h>

typedef struct {
    simd_float3 center;
    float       radius;
    simd_float3 color;
    float _pad;
    
} ColorSphere;

typedef struct {
    simd_uint3  cells;
    simd_float3 origin;
    simd_float3 cellSize;
    float       isoLevel;
    uint32_t    sphereCount;
    float       smoothK;
} MarchingCubesColorBlobParams;

#endif /* MarchingCubesColorBlobParams_h */