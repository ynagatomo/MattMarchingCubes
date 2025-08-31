#include <metal_stdlib>
using namespace metal;

#include "VertexPositionNormalColor.h"
#include "MarchingCubesColorBlobParams.h"
#include "edgeTable.h"
#include "triTable.h"

inline float3 interpolateIsoSurfacePosition(float3 pA, float valueA,
                                            float3 pB, float valueB,
                                            float isoLevel) {
    float denom = (valueB - valueA);
    float t = (isoLevel - valueA) / (denom + 1e-6f);
    return mix(pA, pB, clamp(t, 0.0f, 1.0f));
}

inline float sdf_sphere(float3 p, float3 c, float r) {
    return length(p - c) - r;
}

inline float smin(float a, float b, float k) {
    float h = clamp(0.5f + 0.5f * (b - a) / max(k, 1e-6f), 0.0f, 1.0f);
    return mix(b, a, h) - k * h * (1.0f - h);
}

inline float fieldValue(float3 worldPos,
                        constant MarchingCubesColorBlobParams& P,
                        device const ColorSphere* spheres) {
    float d = 1e9f;
    uint count = P.sphereCount;
    for (uint i = 0; i < count; ++i) {
        float di = sdf_sphere(worldPos, spheres[i].center, spheres[i].radius);
        d = smin(d, di, P.smoothK);
    }
    return d;
}

inline float3 estimateNormalFromField(float3 worldPos,
                                      constant MarchingCubesColorBlobParams& P,
                                      device const ColorSphere* spheres) {
    float h = 0.5f * min(P.cellSize.x, min(P.cellSize.y, P.cellSize.z));
    float fx = fieldValue(worldPos + float3(h,0,0), P, spheres) - fieldValue(worldPos - float3(h,0,0), P, spheres);
    float fy = fieldValue(worldPos + float3(0,h,0), P, spheres) - fieldValue(worldPos - float3(0,h,0), P, spheres);
    float fz = fieldValue(worldPos + float3(0,0,h), P, spheres) - fieldValue(worldPos - float3(0,0,h), P, spheres);
    return normalize(float3(fx, fy, fz) / (2.0f * h));
}

inline float3 blendedColorAt(float3 worldPos,
                             constant MarchingCubesColorBlobParams& P,
                             device const ColorSphere* spheres) {
    float sumW = 0.0f;
    float3 sumC = float3(0.0f);
    float minD = 1e9f;
    float3 nearestC = float3(1.0f, 1.0f, 1.0f);

    uint count = P.sphereCount;
    float falloff = max(P.smoothK, 1e-4f);

    for (uint i = 0; i < count; ++i) {
        float d = length(worldPos - spheres[i].center);
        float sdf = d - spheres[i].radius;
        float w = clamp((falloff - max(sdf, 0.0f)) / falloff, 0.0f, 1.0f);

        sumW += w;
        sumC += w * spheres[i].color;

        if (d < minD) {
            minD = d;
            nearestC = spheres[i].color;
        }
    }

    return (sumW > 1e-6f) ? (sumC / sumW) : nearestC;
}

kernel void generateMarchingCubesColorBlobMesh(device VertexPositionNormalColor* outVertices      [[buffer(0)]],
                                               device uint*                 outIndices       [[buffer(1)]],
                                               device atomic_uint*          outVertexCounter [[buffer(2)]],
                                               constant MarchingCubesColorBlobParams& P [[buffer(3)]],
                                               device const ColorSphere* spheres          [[buffer(4)]],
                                               uint3 cellCoord [[thread_position_in_grid]]) {
    if (cellCoord.x >= P.cells.x || cellCoord.y >= P.cells.y || cellCoord.z >= P.cells.z) {
        return;
    }

    const int3 cornerOffsets[8] = {
        int3(0,0,0), int3(1,0,0), int3(1,1,0), int3(0,1,0),
        int3(0,0,1), int3(1,0,1), int3(1,1,1), int3(0,1,1)
    };

    const int2 edgeCornerIndexPairs[12] = {
        int2(0,1), int2(1,2), int2(2,3), int2(3,0),
        int2(4,5), int2(5,6), int2(6,7), int2(7,4),
        int2(0,4), int2(1,5), int2(2,6), int2(3,7)
    };

    const float3 cellOriginWS = P.origin + float3(cellCoord) * P.cellSize;

    float   cornerScalar[8];
    float3  cornerPositionWS[8];
    for (int i = 0; i < 8; ++i) {
        float3 cp = cellOriginWS + float3(cornerOffsets[i]) * P.cellSize;
        cornerPositionWS[i] = cp;
        cornerScalar[i]     = fieldValue(cp, P, spheres);
    }

    int cubeIndex = 0;
    if (cornerScalar[0] > P.isoLevel) cubeIndex |=   1;
    if (cornerScalar[1] > P.isoLevel) cubeIndex |=   2;
    if (cornerScalar[2] > P.isoLevel) cubeIndex |=   4;
    if (cornerScalar[3] > P.isoLevel) cubeIndex |=   8;
    if (cornerScalar[4] > P.isoLevel) cubeIndex |=  16;
    if (cornerScalar[5] > P.isoLevel) cubeIndex |=  32;
    if (cornerScalar[6] > P.isoLevel) cubeIndex |=  64;
    if (cornerScalar[7] > P.isoLevel) cubeIndex |= 128;

    int edgeMask = edgeTable[cubeIndex];
    if (edgeMask == 0) { return; }

    float3 edgeIntersectionWS[12];
    for (int edge = 0; edge < 12; ++edge) {
        if (edgeMask & (1 << edge)) {
            const int a = edgeCornerIndexPairs[edge].x;
            const int b = edgeCornerIndexPairs[edge].y;
            edgeIntersectionWS[edge] = interpolateIsoSurfacePosition(
                cornerPositionWS[a], cornerScalar[a],
                cornerPositionWS[b], cornerScalar[b],
                P.isoLevel
            );
        }
    }

    constant int* triangleEdgesRow = &triTable[cubeIndex][0];

    for (int triIdx = 0; triIdx < 16 && triangleEdgesRow[triIdx] != -1; triIdx += 3) {
        const int e0 = triangleEdgesRow[triIdx + 0];
        const int e1 = triangleEdgesRow[triIdx + 1];
        const int e2 = triangleEdgesRow[triIdx + 2];

        const float3 p0 = edgeIntersectionWS[e0];
        const float3 p1 = edgeIntersectionWS[e1];
        const float3 p2 = edgeIntersectionWS[e2];

        const float3 n0 = estimateNormalFromField(p0, P, spheres);
        const float3 n1 = estimateNormalFromField(p1, P, spheres);
        const float3 n2 = estimateNormalFromField(p2, P, spheres);

        const float3 c0 = blendedColorAt(p0, P, spheres);
        const float3 c1 = blendedColorAt(p1, P, spheres);
        const float3 c2 = blendedColorAt(p2, P, spheres);

        const uint baseVertexIndex = atomic_fetch_add_explicit(outVertexCounter, (uint)3, memory_order_relaxed);

        outVertices[baseVertexIndex + 0].position = p0;
        outVertices[baseVertexIndex + 0].normal   = n0;
        outVertices[baseVertexIndex + 0].color    = c0;

        outVertices[baseVertexIndex + 1].position = p1;
        outVertices[baseVertexIndex + 1].normal   = n1;
        outVertices[baseVertexIndex + 1].color    = c1;

        outVertices[baseVertexIndex + 2].position = p2;
        outVertices[baseVertexIndex + 2].normal   = n2;
        outVertices[baseVertexIndex + 2].color    = c2;

        outIndices[baseVertexIndex + 0] = baseVertexIndex + 0;
        outIndices[baseVertexIndex + 1] = baseVertexIndex + 1;
        outIndices[baseVertexIndex + 2] = baseVertexIndex + 2;
    }
}