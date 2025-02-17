#include "../../include/optix/parameters.cuh"
#include "common.cuh"

extern "C"
{
	__constant__ kobra::optix::BasiliskParameters parameters;
}

__forceinline__ __device__
float get(float3 a, int axis)
{
	if (axis == 0) return a.x;
	if (axis == 1) return a.y;
	if (axis == 2) return a.z;
}

extern "C" __global__ void __closesthit__voxel()
{
	LOAD_RAYPACKET();
	LOAD_INTERSECTION_DATA();

	// Check if primary ray
	bool primary = (rp->depth == 0);

	// TODO: first pass of rays is proxy for initialization?
	// TODO: extra buffer for direct lighting only, so that we can continue
	// with full lighting and show actual results?

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

	// Reservoir for spatial sampling
	LightReservoir spatial {
		.sample = LightSample {},
		.count = 0,
		.weight = 0.0f,
	};

	// TODO: combine with vanilla ReSTIR

	// Obtain direct lighting sample
	// NOTE: decorrelating samples places into local and world space
	// reservoirs by using different samples for each
	// TODO: observe whether this is actually beneficial
	FullLightSample fls = sample_direct(lc, surface_hit, rp->seed);

	// Compute target function (unocculted lighting)
	float3 D = fls.point - surface_hit.x;
	float d = length(D);
	D /= d;

	float3 Li = direct_occluded(parameters.traversable, surface_hit, fls.Le, fls.normal, fls.type, D, d);
		
	// Contribution and weight
	float target = Li.x + Li.y + Li.z; // Luminance
	float pdf = fls.pdf;
	
	float w = (pdf > 0.0f) ? target/pdf : 0.0f;
		
	// Update reservoir
	// TODO: initialize sample to use
	reservoir_update(&spatial, LightSample {
		.value = Li,
		.target = target,
		.type = fls.type,
		.index = fls.index
	}, w, rp->seed);

	// World space resampling
	float3 direct = make_float3(0);

	if (parameters.kd_tree) {
		FullLightSample fls = sample_direct(lc, surface_hit, rp->seed);

		// Compute target function (unocculted lighting)
		float3 D = fls.point - surface_hit.x;
		float d = length(D);
		D /= d;

		float3 Li = direct_unoccluded(surface_hit, fls.Le, fls.normal, fls.type, D, d);
			
		// Contribution and weight
		float target = Li.x + Li.y + Li.z; // Luminance
		float pdf = fls.pdf;
		
		float w = (pdf > 0.0f) ? target/pdf : 0.0f;

		// TODO: skip traversal if w is zero?

		// Traverse the kd-tree
		WorldNode *kd_node = nullptr;

		int root = 0;
		int depth = 0;

		int lefts = 0;
		int rights = 0;

		float3 pos = surface_hit.x;
		
		while (root >= 0) {
			depth++;
			kd_node = &parameters.kd_tree[root];
			
			// If no valid branches, exit
			int left = kd_node->left;
			int right = kd_node->right;

			if (left == -1 && right == -1)
				break;

			// If only one valid branch, traverse it
			if (left == -1) {
				root = right;
				rights++;
				continue;
			}

			if (right == -1) {
				root = left;
				lefts++;
				continue;
			}

			// Otherwise, choose the branch according to the split
			float split = kd_node->split;
			int axis = kd_node->axis;

			if (get(pos, axis) < split) {
				root = left;
				lefts++;
			} else {
				root = right;
				rights++;
			}
		}

		// TODO: visualization mode...
		// rp->value = make_float3(lefts, rights, 0)/depth;
		// return;

		// Lock and update the reservoir
		// TODO: similar scoped lock as std::lock_guard, in cuda/sync.h
		int res_idx = kd_node->data;
		
		int *lock = parameters.kd_locks[res_idx];

		auto *reservoir = &parameters.kd_reservoirs[res_idx];
		auto *sample = &reservoir->sample;

		/* reservoir_update(reservoir, LightSample {
			.value = fls.Le,
			.point = fls.point,
			.normal = fls.normal,
			.target = target,
			.type = fls.type,
			.index = fls.index
		}, w, rp->seed); */

		// Atomic update
		// TODO: method
		float wold = atomicAdd(&reservoir->weight, w);
		atomicAdd(&reservoir->count, 1);
		float wnew = wold + w;

		float eta = rand_uniform(rp->seed);
		bool select = (wnew * eta < w);

		if (select) {
			reservoir->sample = LightSample {
				.value = fls.Le,
				.point = fls.point,
				.normal = fls.normal,
				.target = target,
				.type = fls.type,
				.index = fls.index
			};
		}

		const int SPATIAL_SAMPLES = 3;

		// Choose a root node a few level up and randomly
		// traverse the tree to obtain a sample
		const int LEVELS = 10;

		// TODO: adaptive levels if success rate is low

		int levels = min(depth, LEVELS);
		while (levels--) {
			kd_node = &parameters.kd_tree[root];

			if (kd_node->parent == -1)
				break;

			root = kd_node->parent;
		}

		int successes = 0;
		for (int i = 0; i < SPATIAL_SAMPLES; i++) {
			int node = root;

			while (true) {
				kd_node = &parameters.kd_tree[node];

				float split = kd_node->split;
				int axis = kd_node->axis;

				// If no valid branches, exit
				int left = kd_node->left;
				int right = kd_node->right;

				if (left == -1 && right == -1)
					break;

				// If only one valid branch, go there
				if (left == -1) {
					node = right;
					continue;
				}

				if (right == -1) {
					node = left;
					continue;
				}

				// Otherwise, choose a random branch
				float eta = rand_uniform(rp->seed);

				if (eta < 0.5f)
					node = left;
				else
					node = right;
			}

			// Get necessary data
			// TODO: maybe lock?
			res_idx = kd_node->data;

			// TODO: syncronized pipeline, this one is copied
			// because no lock is used
			LightReservoir rsampled = parameters.kd_reservoirs_prev[res_idx];
			LightSample sample = rsampled.sample;

			// Compute value and target
			D = sample.point - surface_hit.x;
			d = length(D);
			D /= d;

			assert(!isnan(D.x) && !isnan(D.y) && !isnan(D.z));

			Li = direct_occluded(parameters.traversable,
				surface_hit, sample.value,
				sample.normal, sample.type, D, d
			);

			float denom = rsampled.count * sample.target;
			float W = (denom > 0.0f) ? rsampled.weight/denom : 0.0f;

			// Insert into spatial reservoir
			target = Li.x + Li.y + Li.z; // Luminance
			w = target * W * rsampled.count; // TODO: compute without doing repeated work

			int pcount = spatial.count;
			reservoir_update(&spatial, LightSample {
				.value = Li,
				.target = target,
				.type = sample.type,
				.index = sample.index
			}, w, rp->seed);

			// spatial.count = pcount + (target > 0.0f ? reservoir->count : 0);
			spatial.count = pcount + rsampled.count;
			successes += (target > 0.0f);
		}
	}

	// Final direct lighting result
	float denom = spatial.count * spatial.sample.target;
	float W = (denom > 0) ? spatial.weight/denom : 0.0f;
	// assert(!isnan(W));

	direct = material.emission + spatial.sample.value * W;

	// Also compute indirect lighting
	// TODO: method...
	Shading out;
	float3 wi;

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
		trace <eVoxel> (
			parameters.traversable,
			eCount,
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
}
