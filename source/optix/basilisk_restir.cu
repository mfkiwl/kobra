#include "../../include/optix/parameters.cuh"
#include "common.cuh"

extern "C"
{
	__constant__ kobra::optix::BasiliskParameters parameters;
}

// Target function
KCUDA_INLINE KCUDA_DEVICE
float target_function(float3 Li)
{
	return Li.x + Li.y + Li.z;
}

// Get direct lighting using RIS
__device__
float3 direct_lighting_ris(OptixTraversableHandle handle, const LightingContext &lc, const SurfaceHit &sh, Seed seed)
{
	const int M = 10;

	LightReservoir reservoir {
		.sample = LightSample {},
		.count = 0,
		.weight = 0.0f,
		.mis = 0.0f,
	};

	for (int k = 0; k < M; k++) {
		// Get direct lighting sample
		FullLightSample fls = sample_direct(lc, sh, seed);

		// Compute lighting
		float3 D = fls.point - sh.x;
		float d = length(D);
		D /= d;

		float3 Li = direct_occluded(handle, sh, fls.Le, fls.normal, fls.type, D, d);

		// Resampling
		// TODO: common target function...
		float target = target_function(Li);
		float pdf = fls.pdf;

		float w = (pdf > 0.0f) ? target/pdf : 0.0f;

		reservoir_update(&reservoir, LightSample {
			.value = Li,
			.target = target,
			.type = fls.type,
			.index = fls.index
		}, w, seed);
	}

	// Get final sample and contribution
	LightSample sample = reservoir.sample;
	float W = (sample.target > 0) ? reservoir.weight/(M * sample.target) : 0.0f;

	return W * sample.value;
}

// Get direct lighting using Temporal RIS
__device__
float3 direct_lighting_temporal_ris(OptixTraversableHandle handle,
		const LightingContext &lc,
		const SurfaceHit &sh, int index, Seed seed)
{
	// Get the reservoir
	LightReservoir *reservoir = &parameters.advanced.r_lights[index];
	if (parameters.samples == 0) {
		reservoir->sample = LightSample {};
		reservoir->count = 0;
		reservoir->weight = 0.0f;
		reservoir->mis = 0.0f;
	}

	// TODO: temporal reprojection?

	// Get direct lighting sample
	FullLightSample fls = sample_direct(lc, sh, seed);

	// Compute lighting
	float3 D = fls.point - sh.x;
	float d = length(D);
	D /= d;

	float3 Li = direct_occluded(handle, sh, fls.Le, fls.normal, fls.type, D, d);

	// Resampling
	float target = target_function(Li);
	float pdf = fls.pdf;

	float w = (pdf > 0.0f) ? target/pdf : 0.0f;

	reservoir_update(reservoir, LightSample {
		.value = Li,
		.target = target,
		.type = fls.type,
		.index = fls.index
	}, w, seed);

	// Get final sample and contribution
	LightSample sample = reservoir->sample;
	float denominator = reservoir->count * sample.target;
	float W = (sample.target > 0) ? reservoir->weight/denominator : 0.0f;

	return W * sample.value;
}

// Get direct lighting using Spatio-Temporal RIS (ReSTIR)
__device__
float3 direct_lighting_restir(OptixTraversableHandle handle,
		const LightingContext &lc,
		const SurfaceHit &sh, int index, Seed seed, int spatial_samples,
		bool indirect = false)
{
	// Get the reservoir
	// TODO: option to copy resrvoir and update locally rather than
	//       updating the global reservoir
	// TODO: do we actually need to worry about empty reservoirs?
	LightReservoir *temporal = &parameters.advanced.r_lights[index];
	LightReservoir *spatial = &parameters.advanced.r_spatial[index];
	
	LightReservoir indirect_temporal = *temporal;

	// Cannot use the global spatial reservoir,
	// which is local to the primary intersections
	LightReservoir indirect_spatial {
		.sample = LightSample {},
		.count = 0,
		.weight = 0.0f,
		.mis = 0.0f,
	};

	// TODO: take into account local spatial reservoir with occlusion?
	// Or is the overhead too high, and spatial resampling done later
	// is enough?

	if (indirect) {
		// Copy so we do not disturb the global reservoirs
		temporal = &indirect_temporal;
		spatial = &indirect_spatial;
	}

	if (parameters.samples == 0) {
		temporal->sample = LightSample {};
		temporal->count = 0;
		temporal->weight = 0.0f;
		temporal->mis = 0.0f;

		spatial->sample = LightSample {};
		spatial->count = 0;
		spatial->weight = 0.0f;
		spatial->mis = 0.0f;
	}

	for (int i = 0; i < 32; i++) {
		// Get direct lighting sample
		FullLightSample fls = sample_direct(lc, sh, seed);

		// Compute target function (unocculted lighting)
		float3 D = fls.point - sh.x;
		float d = length(D);
		D /= d;

		float3 Li = direct_unoccluded(sh, fls.Le, fls.normal, fls.type, D, d);

		// Temporal Resampling
		float target = target_function(Li);
		float pdf = fls.pdf;

		float w = (pdf > 0.0f) ? target/pdf : 0.0f;

		reservoir_update(temporal, LightSample {
			.value = fls.Le,
			.point = fls.point,
			.normal = fls.normal,
			.target = target,
			.type = fls.type,
			.index = fls.index
		}, w, seed);
	}

	// Add current sample
	int Z = 0;

	{
		// Compute unbiased weight
		LightSample sample = temporal->sample;
		float denominator = temporal->count * sample.target;
		float W = (denominator > 0) ? temporal->weight/denominator : 0.0f;

		// Compute value and target
		float3 D = sample.point - sh.x;
		float d = length(D);
		D /= d;

		float3 Li = direct_occluded(handle, sh, sample.value, sample.normal, sample.type, D, d);

		// Add to the reservoir
		float target = target_function(Li);
		float w = target * W * temporal->count;

		spatial->weight += w;

		float p = w/spatial->weight;
		float eta = rand_uniform(seed);

		if (eta < p) {
			spatial->sample = LightSample {
				.value = Li,
				.point = sample.point,
				.normal = sample.normal,
				.target = target,
				.type = sample.type,
				.index = sample.index
			};
		}

		spatial->count += temporal->count;
		if (target > 0.0f)
			Z += temporal->count;
	}

	// Sample various neighboring reservoirs
	const int WIDTH = parameters.resolution.x;
	const int HEIGHT = parameters.resolution.y;

	const float SAMPLING_RADIUS = min(WIDTH, HEIGHT) * 0.1f;
	// const float SAMPLING_RADIUS = 20.0f;

	int ix = index % WIDTH;
	int iy = index / WIDTH;

	for (int i = 0; i < spatial_samples; i++) {
		// Get offset
		float3 eta = rand_uniform_3f(seed);

		float radius = SAMPLING_RADIUS * sqrt(eta.x);
		float theta = 2.0f * M_PI * eta.y;

		int offx = (int) floorf(radius * cosf(theta));
		int offy = (int) floorf(radius * sinf(theta));

		int nix = ix + offx;
		int niy = iy + offy;

		if (niy < 0 || niy >= HEIGHT || nix < 0 || nix >= WIDTH)
			continue;

		int ni = niy * WIDTH + nix;

		// Get the reservoir
		// NOTE: one side effect of dual buffering is
		// that we retain some of the old samlpes even
		// we move around
		// TODO: alternate sampling method following the papers exact
		// strategy -- occluded weight for the reservoirs, etc
		// Also add W to the reservoirs...
		LightReservoir *reservoir = &parameters.advanced.r_lights_prev[ni];

		// Get sample and resample
		LightSample sample = reservoir->sample;
		float denominator = reservoir->count * sample.target;
		float W = (denominator > 0) ? reservoir->weight/denominator : 0.0f;

		// Compute value and target
		float3 D = sample.point - sh.x;
		float d = length(D);
		D /= d;

		float3 Li = direct_occluded(handle, sh, sample.value, sample.normal, sample.type, D, d);

		// Add to the reservoir
		float target = target_function(Li);
		float w = target * W * reservoir->count;

		spatial->weight += w;

		float p = w/spatial->weight;
		if (eta.z < p) {
			spatial->sample = LightSample {
				.value = Li,
				.point = sample.point,
				.normal = sample.normal,
				.target = target,
				.type = sample.type,
				.index = sample.index
			};
		}

		spatial->count += reservoir->count;
		if (target > 0.0f)
			Z += reservoir->count;
	}

	// Get final sample's contribution	
	LightSample sample = spatial->sample;
	float denominator = spatial->count * sample.target;
	float W = (denominator > 0) ? spatial->weight/denominator : 0.0f;

	// Evaluate the integrand
	return W * sample.value;
}

// Direct lighting for indirect rays, possible reuse
__device__
float3 direct_indirect(OptixTraversableHandle handle, const LightingContext &lc, const SurfaceHit &surface_hit, Seed seed)
{
	if (!parameters.options.reprojected_reuse)
		return Ld(lc, surface_hit, seed);

	// TODO: method
	const float3 U = parameters.cam_u;
	const float3 V = parameters.cam_v;
	const float3 W = parameters.cam_w;

	float3 D = surface_hit.x - parameters.camera;
	float d = length(D);
	D /= d;

	float D_W = dot(D, W);
	float u = dot(D, U)/(dot(D, W) * dot(U, U));
	float v = dot(D, V)/(dot(D, W) * dot(V, V));

	bool in_u_bounds = (u >= -1.0f && u <= 1.0f);
	bool in_v_bounds = (v >= -1.0f && v <= 1.0f);

	// TODO: how much does checking for occlusion matter?
	if (in_u_bounds && in_v_bounds) {
		u = (u + 1.0f) * 0.5f;
		v = (v + 1.0f) * 0.5f;

		int ix = (int) floorf(u * parameters.resolution.x);
		int iy = (int) floorf(v * parameters.resolution.y);

		int index = iy * parameters.resolution.x + ix;

		return direct_lighting_restir(handle, lc, surface_hit, index, seed, 3, true);
	}
	
	return Ld(lc, surface_hit, seed);
}

// Closest hit program for ReSTIR
extern "C" __global__ void __closesthit__restir()
{
	LOAD_RAYPACKET();
	LOAD_INTERSECTION_DATA();

	// Check if primary ray
	bool primary = (rp->depth == 0);

	// Offset by normal
	x += (material.type == Shading::eTransmission ? -1 : 1) * n * eps;

	// Construct SurfaceHit instance for lighting calculations
	SurfaceHit surface_hit {
		.mat = material,
		.entering = entering,
		.n = n,
		.wo = wo,
		.x = x,
	};
	
	LightingContext lc {
		parameters.traversable,
		parameters.lights.quads,
		parameters.lights.triangles,
		parameters.lights.quad_count,
		parameters.lights.triangle_count,
		parameters.has_envmap,
		parameters.envmap,
	};

	// Compute direct ligting
	float3 direct = make_float3(0.0f);

	if (primary) {
		// direct = direct_lighting_ris(surface_hit, rp->seed);
		// direct = direct_lighting_temporal_ris(surface_hit, rp);

		int spatial_samples = 5;
		if (parameters.options.reprojected_reuse)
			spatial_samples = 3;

		direct = direct_lighting_restir(
			lc.handle, lc,
			surface_hit,
			rp->index, rp->seed,
			spatial_samples
		);
	} else {
		direct = direct_indirect(
			lc.handle, lc,
			surface_hit, rp->seed
		);
	}

	if (material.type == Shading::eEmissive)
		direct += material.emission;
	
	// Generate new ray
	Shading out;
	float3 wi;
	float pdf;

	float3 f = eval(surface_hit, wi, pdf, out, rp->seed);

	// Get threshold value for current ray
	float3 T = f * abs(dot(wi, n))/pdf;

	// Update for next ray
	rp->ior = material.refraction;
	rp->pdf *= pdf;
	rp->depth++;
	
	// Trace the next ray
	float3 indirect = make_float3(0.0f);
	if (pdf > 0) {
		// trace <eRegular> (x, wi, i0, i1);
		trace <eReSTIR> (
			parameters.traversable, eCount,
			x, wi, i0, i1
		);

		indirect = rp->value;
	}

	// Update the value
	bool skip_direct = (primary && parameters.options.indirect_only);
	if (!skip_direct)
		rp->value = direct;

	if (pdf > 0)
		rp->value += T * indirect;

	rp->position = make_float4(x, 1);
	rp->normal = n;
	rp->albedo = material.diffuse;
	rp->wi = wi;
}

// Closest hit program for ReSTIR PT
extern "C" __global__ void __closesthit__restir_pt()
{
	LOAD_RAYPACKET();
	LOAD_INTERSECTION_DATA();

	// Offset by normal
	x += (material.type == Shading::eTransmission ? -1 : 1) * n * eps;

	// Construct SurfaceHit instance for lighting calculations
	SurfaceHit surface_hit {
		.mat = material,
		.entering = entering,
		.n = n,
		.wo = wo,
		.x = x,
	};
	
	LightingContext lc {
		parameters.traversable,
		parameters.lights.quads,
		parameters.lights.triangles,
		parameters.lights.quad_count,
		parameters.lights.triangle_count,
		parameters.has_envmap,
		parameters.envmap,
	};

	// Compute direct ligting
	float3 direct = material.emission + Ld(lc, surface_hit, rp->seed);
	
	// Generate new ray
	Shading out;
	float3 wi;
	float pdf;

	float3 f = eval(surface_hit, wi, pdf, out, rp->seed);

	// Get threshold value for current ray
	float3 T = f * abs(dot(wi, n))/pdf;

	// Update for next ray
	rp->ior = material.refraction;
	rp->pdf *= pdf;
	rp->depth++;
	
	// Trace the next ray
	float3 indirect = make_float3(0.0f);
	if (pdf > 0) {
		trace <eRegular> (
			parameters.traversable, eCount,
			x, wi, i0, i1
		);

		indirect = rp->value;
	}

	// Update the value
	bool skip_direct = (parameters.options.indirect_only);
	if (!skip_direct)
		rp->value = direct;

	if (pdf > 0)
		rp->value += T * indirect;

	rp->position = make_float4(x, 1);
	rp->normal = n;
	rp->albedo = material.diffuse;
	rp->wi = wi;
}
