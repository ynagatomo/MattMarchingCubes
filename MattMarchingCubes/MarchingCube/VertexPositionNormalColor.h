#import "MarchingCubesColorBlobParams.h"
#include <simd/simd.h>

#ifndef VertexPositionNormalColor_h
#define VertexPositionNormalColor_h

struct VertexPositionNormalColor {
    simd_float3 position;
    simd_float3 normal;
    simd_float3 color;
};

#endif /* VertexPositionNormalColor_h */
