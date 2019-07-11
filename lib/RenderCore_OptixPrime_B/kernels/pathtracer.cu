/* pathtracer.cu - Copyright 2019 Utrecht University

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

	   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.

   This file implements the shading stage of the wavefront algorithm.
   It takes a buffer of hit results and populates a new buffer with
   extension rays. Shadow rays are added with 'potential contributions'
   as fire-and-forget rays, to be traced later. Streams are compacted
   using simple atomics. The kernel is a 'persistent kernel': a fixed 
   number of threads fights for food by atomically decreasing a counter.

   The implemented path tracer is deliberately simple.
   This file is as similar as possible to the one in OptixRTX_B.
*/

#include "noerrors.h"

// path state flags
#define S_SPECULAR		1	// previous path vertex was specular
#define S_BOUNCED		2	// path encountered a diffuse vertex
#define S_VIASPECULAR	4	// path has seen at least one specular vertex

// readability defines; data layout is optimized for 128-bit accesses
#define INSTANCEIDX (prim >> 24)
#define HIT_U hitData.x
#define HIT_V hitData.y
#define HIT_T hitData.w
#define RAY_O make_float3( O4 )
#define FLAGS data
#define PATHIDX (data >> 8)

//  +-----------------------------------------------------------------------------+
//  |  shadeKernel                                                                |
//  |  Implements the shade phase of the wavefront path tracer.             LH2'19|
//  +-----------------------------------------------------------------------------+
LH2_DEVFUNC void shadeKernel( const int jobIndex, float4* accumulator, const uint stride,
	const Ray4* extensionRays, const float4* pathStateData, const Intersection* hits,
	Ray4* extensionRaysOut, float4* pathStateDataOut, Ray4* connections, float4* potentials,
	const uint R0, const int probePixelIdx, const int pathLength, const int w, const int h, const float spreadAngle,
	const float3 p1, const float3 p2, const float3 p3, const float3 pos )
{
	// gather data by reading sets of four floats for optimal throughput
	const float4 O4 = extensionRays[jobIndex].O4;		// ray origin xyz, w can be ignored
	const float4 D4 = extensionRays[jobIndex].D4;		// ray direction xyz
	const float4 T4 = pathLength == 1 ? make_float4( 1 ) : pathStateData[jobIndex * 2 + 0];	// path thoughput rgb 
	const float4 Q4 = pathStateData[jobIndex * 2 + 1];	// x, y: pd of the previous bounce, normal at the previous vertex
	const Intersection hd = hits[jobIndex];				// TODO: when using instances, Optix Prime needs 5x4 bytes here...
	const float4 hitData = make_float4( hd.u, hd.v, __int_as_float( hd.triid + (hd.triid == -1 ? 0 : (hd.instid << 24)) ), hd.t );
	uint data = __float_as_uint( T4.w );

	// derived data
	const float bsdfPdf = Q4.x;							// prob.density of the last sampled dir, postponed because of MIS
	const float3 D = make_float3( D4 );
	const int prim = __float_as_int( hitData.z );
	const int primIdx = prim == -1 ? prim : (prim & 0xffffff);
	float3 throughput = make_float3( T4 );
	const CoreTri4* instanceTriangles = (const CoreTri4*)instanceDescriptors[INSTANCEIDX].triangles;
	const uint pathIdx = PATHIDX;
	const uint pixelIdx = pathIdx % (w * h);
	const uint sampleIdx = pathIdx / (w * h);

	// initialize depth in accumulator for DOF shader
	if (pathLength == 1) accumulator[pixelIdx].w += primIdx == NOHIT ? 10000 : HIT_T;

	// use skydome if we didn't hit any geometry
	if (primIdx == NOHIT)
	{
		float3 contribution = throughput * make_float3( SampleSkydome( D, pathLength ) ) * (1.0f / bsdfPdf);
		CLAMPINTENSITY; // limit magnitude of thoughput vector to combat fireflies
		FIXNAN_FLOAT3( contribution );
		accumulator[pixelIdx] += make_float4( contribution, 0 );
		return;
	}

	// object picking
	if (pixelIdx == probePixelIdx && pathLength == 1 && sampleIdx == 0)
		counters->probedInstid = INSTANCEIDX,	// record instace id at the selected pixel
		counters->probedTriid = primIdx,		// record primitive id at the selected pixel
		counters->probedDist = HIT_T;			// record primary ray hit distance

	// get shadingData and normals
	ShadingData shadingData;
	float3 N, iN, fN, T;
	const float3 I = RAY_O + HIT_T * D;
	const float coneWidth = spreadAngle * HIT_T;
	GetShadingData( D, HIT_U, HIT_V, coneWidth, instanceTriangles[primIdx], INSTANCEIDX, shadingData, N, iN, fN, T );

	// we need to detect alpha in the shading code.
	if (shadingData.flags & 1)
	{
		if (pathLength < MAXPATHLENGTH)
		{
			const uint extensionRayIdx = atomicAdd( &counters->extensionRays, 1 );
			extensionRaysOut[extensionRayIdx].O4 = make_float4( I, EPSILON );
			extensionRaysOut[extensionRayIdx].D4 = make_float4( D, 1e34f );
			FIXNAN_FLOAT3( throughput );
			pathStateDataOut[extensionRayIdx * 2 + 0] = make_float4( throughput, __uint_as_float( data ) );
			pathStateDataOut[extensionRayIdx * 2 + 1] = make_float4( bsdfPdf, 0, 0, 0 );
		}
		return;
	}

	// path regularization
	if (FLAGS & S_BOUNCED) shadingData.roughness2 = max( 0.7f, shadingData.roughness2 );

	// stop on light
	if (shadingData.IsEmissive() /* r, g or b exceeds 1 */)
	{
		const float DdotNL = -dot( D, N );
		float3 contribution = make_float3( 0 ); // initialization required.
		if (DdotNL > 0 /* lights are not double sided */)
		{
			if (pathLength == 1 || (FLAGS & S_SPECULAR) > 0)
			{
				// only camera rays will be treated special
				contribution = shadingData.diffuse;
			}
			else
			{
				// last vertex was not specular: apply MIS
				const float3 lastN = UnpackNormal( __float_as_uint( Q4.y ) );
				const CoreTri& tri = (const CoreTri&)instanceTriangles[primIdx];
				const float lightPdf = CalculateLightPDF( D, HIT_T, tri.area, N );
				const float pickProb = LightPickProb( tri.ltriIdx, RAY_O, lastN, I /* the N at the previous vertex */ );
				if ((bsdfPdf + lightPdf * pickProb) > 0) contribution = throughput * shadingData.diffuse * (1.0f / (bsdfPdf + lightPdf * pickProb));
				contribution = throughput * shadingData.diffuse * (1.0f / (bsdfPdf + lightPdf));
			}
			CLAMPINTENSITY;
			FIXNAN_FLOAT3( contribution );
			accumulator[pixelIdx] += make_float4( contribution, 0 );
		}
		return;
	}

	// detect specular surfaces
	if (shadingData.roughness2 < 0.01f) FLAGS |= S_SPECULAR; else FLAGS &= ~S_SPECULAR;

	// initialize seed based on pixel index
	uint seed = WangHash( pathIdx + R0 /* well-seeded xor32 is all you need */ );

	// normal alignment for backfacing polygons
	const float flip = (dot( D, N ) > 0) ? -1 : 1;
	N *= flip;		// fix geometric normal
	iN *= flip;		// fix interpolated normal (consistent normal interpolation)
	fN *= flip;		// fix final normal (includes normal map)

	// apply postponed bsdf pdf
	throughput *= 1.0f / bsdfPdf;

	// next event estimation: connect eye path to light
	if (!(FLAGS & S_SPECULAR)) // skip for specular vertices
	{
		float3 lightColor;
		float r0 = RandomFloat( seed ), r1 = RandomFloat( seed ), pickProb, lightPdf = 0;
		float3 L = RandomPointOnLight( r0, r1, I, fN, pickProb, lightPdf, lightColor ) - I;
		const float dist = length( L );
		L *= 1.0f / dist;
		const float NdotL = dot( L, fN );
		if (NdotL > 0 && dot( fN, L ) > 0 && lightPdf > 0)
		{
			float bsdfPdf;
			const float3 sampledBSDF = EvaluateBSDF( shadingData, fN, D * -1.0f, L, 0, bsdfPdf );
			if (bsdfPdf > 0)
			{
				// calculate potential contribution
				float3 contribution = throughput * sampledBSDF * lightColor * (NdotL / (pickProb * lightPdf + bsdfPdf));
				FIXNAN_FLOAT3( contribution );
				CLAMPINTENSITY;
				// add fire-and-forget shadow ray to the connections buffer
				const uint shadowRayIdx = atomicAdd( &counters->shadowRays, 1 ); // compaction
				connections[shadowRayIdx].O4 = make_float4( SafeOrigin( I, L, N, geometryEpsilon ), 0 );
				connections[shadowRayIdx].D4 = make_float4( L, dist - 2 * geometryEpsilon );
				potentials[shadowRayIdx] = make_float4( contribution, __int_as_float( pixelIdx ) );
			}
		}
	}

	// cap at one diffuse bounce (because of this we also don't need Russian roulette)
	if (FLAGS & S_BOUNCED) return;

	// depth cap
	if (pathLength == MAXPATHLENGTH /* don't fill arrays with rays we won't trace */) return;

	// evaluate bsdf to obtain direction for next path segment
	float3 R;
	float newBsdfPdf, r0 = RandomFloat( seed ), r1 = RandomFloat( seed );
	const float3 bsdf = SampleBSDF( shadingData, fN, N, D * -1.0f, r0, r1, R, newBsdfPdf );
	if (newBsdfPdf < EPSILON || isnan( newBsdfPdf )) return;

	// write extension ray
	const uint extensionRayIdx = atomicAdd( &counters->extensionRays, 1 ); // compact
	const uint packedNormal = PackNormal( fN );
	if (!(FLAGS & S_SPECULAR)) FLAGS |= S_BOUNCED; else FLAGS |= S_VIASPECULAR;
	extensionRaysOut[extensionRayIdx].O4 = make_float4( SafeOrigin( I, R, N, geometryEpsilon ), 0 );
	extensionRaysOut[extensionRayIdx].D4 = make_float4( R, 1e34f );
	FIXNAN_FLOAT3( throughput );
	pathStateDataOut[extensionRayIdx * 2 + 0] = make_float4( throughput * bsdf * abs( dot( fN, R ) ), __uint_as_float( data ) );
	pathStateDataOut[extensionRayIdx * 2 + 1] = make_float4( newBsdfPdf, packedNormal, 0, 0 );
}

//  +-----------------------------------------------------------------------------+
//  |  shadePersistent                                                            |
//  |  Persistent kernel, calling shadeKernel.                              LH2'19|
//  +-----------------------------------------------------------------------------+
__global__  void __launch_bounds__( 128 /* max block size */, 4 /* min blocks per sm */ )
shadePersistent( float4* accumulator, const uint stride,
	const Ray4* extensionRays, const float4* pathStateData, const Intersection* hits,
	Ray4* extensionRaysOut, float4* pathStateDataOut, Ray4* connections, float4* potentials,
	const uint R0, const int probePixelIdx, const int pathLength, const int w, const int h, const float spreadAngle,
	const float3 p1, const float3 p2, const float3 p3, const float3 pos )
{
	__shared__ volatile int baseIdx[32];
	const int lane = threadIdx.x & 31, warp = threadIdx.x >> 5;
	const int pathCount = counters->activePaths;
	__syncthreads();
	while (1)
	{
		if (lane == 0) baseIdx[warp] = atomicAdd( &counters->shaded, 32 );
		int jobIndex = baseIdx[warp] + lane;
		if (__all_sync( THREADMASK, jobIndex >= pathCount )) break; // need to do the path with all threads in the warp active
		if (jobIndex < pathCount) shadeKernel( jobIndex, accumulator, stride,
			extensionRays, pathStateData, hits, extensionRaysOut, pathStateDataOut, connections, potentials,
			R0, probePixelIdx, pathLength, w, h, spreadAngle, p1, p2, p3, pos );
	}
}

//  +-----------------------------------------------------------------------------+
//  |  shadeKernel                                                                |
//  |  Host-side access point for the shadeKernel code.                     LH2'19|
//  +-----------------------------------------------------------------------------+
__host__ void shade( const int smcount, float4* accumulator, const uint stride,
	const Ray4* extensionRays, const float4* pathStateData, const Intersection* hits,
	Ray4* extensionRaysOut, float4* pathStateDataOut,
	Ray4* connections, float4* potentials,
	const uint R0, const int probePixelIdx, const int pathLength, const int scrwidth, const int scrheight, const float spreadAngle,
	const float3 p1, const float3 p2, const float3 p3, const float3 pos )
{
	shadePersistent << < smcount * 4, 128 >> > (accumulator, stride,
		extensionRays, pathStateData, hits,
		extensionRaysOut, pathStateDataOut, connections, potentials,
		R0, probePixelIdx, pathLength, scrwidth, scrheight, spreadAngle, p1, p2, p3, pos);
}

// EOF