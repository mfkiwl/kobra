// OptiX headers
#include <optix_device.h>
#include <optix_host.h>
#include <optix_stack_size.h>

// Engine headers
#include "../../include/camera.hpp"
#include "../../include/cuda/alloc.cuh"
#include "../../include/cuda/cast.cuh"
#include "../../include/cuda/color.cuh"
#include "../../include/cuda/interop.cuh"
#include "../../include/ecs.hpp"
#include "../../include/amadeus/armada.cuh"
#include "../../include/optix/core.cuh"
#include "../../include/texture_manager.hpp"
#include "../../include/transform.hpp"
#include "../../shaders/raster/bindings.h"
#include "../../include/profiler.hpp"

namespace kobra {

namespace amadeus {

// Create the layer
// TODO: all custom extent...
ArmadaRTX::ArmadaRTX(const Context &context,
		const std::shared_ptr <amadeus::System> &system,
		const std::shared_ptr <layers::MeshMemory> &mesh_memory,
		const vk::Extent2D &extent)
		: m_system(system), m_mesh_memory(mesh_memory),
		m_device(context.device), m_phdev(context.phdev),
		m_extent(extent), m_active_attachment()
{
	// Start the timer
	m_timer.start();

	// Initialize TLAS state
	m_tlas.null = true;
	m_tlas.last_updated = 0;

	// Configure launch parameters
	auto &params = m_launch_info;

	params.resolution = {
		extent.width,
		extent.height
	};
	
	params.samples = 0;
	params.accumulate = true;
	params.lights.quad_count = 0;
	params.lights.tri_count = 0;
	params.environment_map = 0;
	params.has_environment_map = false;

	// Allocate results
	int size = extent.width * extent.height;

	params.buffers.color = cuda::alloc <glm::vec4> (size);
	params.buffers.normal = cuda::alloc <glm::vec3> (size);
	params.buffers.albedo = cuda::alloc <glm::vec3> (size);
	params.buffers.position = cuda::alloc <glm::vec3> (size);
}

// Set the environment map
void ArmadaRTX::set_envmap(const std::string &path)
{
	// First load the environment map
	const auto &map = TextureManager::load_texture(
		*m_phdev, *m_device, path, true
	);

	m_launch_info.environment_map = cuda::import_vulkan_texture(*m_device, map);
	m_launch_info.has_environment_map = true;
}

// Update the light buffers if needed
void ArmadaRTX::update_light_buffers
		(const std::vector <const Light *> &lights,
		const std::vector <const Transform *> &light_transforms,
		const std::vector <const Submesh *> &submeshes,
		const std::vector <const Transform *> &submesh_transforms)
{
	// TODO: lighting system equivalent of System
	if (m_host.quad_lights.size() != lights.size()) {
		m_host.quad_lights.resize(lights.size());
	
		auto &quad_lights = m_host.quad_lights;
		for (int i = 0; i < lights.size(); i++) {
			const Light *light = lights[i];
			const Transform *transform = light_transforms[i];
			
			glm::vec3 a {-0.5f, 0, -0.5f};
			glm::vec3 b {0.5f, 0, -0.5f};
			glm::vec3 c {-0.5f, 0, 0.5f};

			a = transform->apply(a);
			b = transform->apply(b);
			c = transform->apply(c);

			quad_lights[i].a = cuda::to_f3(a);
			quad_lights[i].ab = cuda::to_f3(b - a);
			quad_lights[i].ac = cuda::to_f3(c - a);
			quad_lights[i].intensity = cuda::to_f3(light->power * light->color);
		}

		m_launch_info.lights.quad_lights = cuda::make_buffer(quad_lights);
		m_launch_info.lights.quad_count = quad_lights.size();

		KOBRA_LOG_FUNC(Log::INFO) << "Uploaded " << quad_lights.size()
			<< " quad lights to the GPU\n";
	}

	// Count number of emissive submeshes
	int emissive_count = 0;

	// TODO: compute before hand
	std::vector <std::pair <const Submesh *, int>> emissive_submeshes;
	for (int i = 0; i < submeshes.size(); i++) {
		const Submesh *submesh = submeshes[i];
		if (glm::length(submesh->material.emission) > 0
				|| submesh->material.has_emission()) {
			emissive_submeshes.push_back({submesh, i});
			emissive_count += submesh->triangles();
		}
	}

	if (m_host.tri_lights.size() != emissive_count) {
		for (const auto &pr : emissive_submeshes) {
			const Submesh *submesh = pr.first;
			const Transform *transform = submesh_transforms[pr.second];

			for (int i = 0; i < submesh->triangles(); i++) {
				uint32_t i0 = submesh->indices[i * 3 + 0];
				uint32_t i1 = submesh->indices[i * 3 + 1];
				uint32_t i2 = submesh->indices[i * 3 + 2];

				glm::vec3 a = transform->apply(submesh->vertices[i0].position);
				glm::vec3 b = transform->apply(submesh->vertices[i1].position);
				glm::vec3 c = transform->apply(submesh->vertices[i2].position);

				m_host.tri_lights.push_back(
					optix::TriangleLight {
						cuda::to_f3(a),
						cuda::to_f3(b - a),
						cuda::to_f3(c - a),
						cuda::to_f3(submesh->material.emission)
						// TODO: what if material has
						// textured emission?
					}
				);
			}
		}

		m_launch_info.lights.tri_lights = cuda::make_buffer(m_host.tri_lights);
		m_launch_info.lights.tri_count = m_host.tri_lights.size();

		// TODO: display logging in UI as well (add log routing)
		KOBRA_LOG_FUNC(Log::INFO) << "Uploaded " << m_host.tri_lights.size()
			<< " triangle lights to the GPU\n";
	}
}

// Update the SBT data
void ArmadaRTX::update_sbt_data
		(const std::vector <layers::MeshMemory::Cachelet> &cachelets,
		const std::vector <const Submesh *> &submeshes,
		const std::vector <const Transform *> &submesh_transforms)
{
	int submesh_count = submeshes.size();

	m_host.hit_records.clear();
	for (int i = 0; i < submesh_count; i++) {
		const Submesh *submesh = submeshes[i];

		// Material
		Material mat = submesh->material;

		// TODO: no need for a separate material??
		cuda::Material material;
		material.diffuse = cuda::to_f3(mat.diffuse);
		material.specular = cuda::to_f3(mat.specular);
		material.emission = cuda::to_f3(mat.emission);
		material.ambient = cuda::to_f3(mat.ambient);
		material.shininess = mat.shininess;
		material.roughness = mat.roughness;
		material.refraction = mat.refraction;
		material.type = mat.type;

		HitRecord hit_record {};

		hit_record.data.model = submesh_transforms[i]->matrix();
		hit_record.data.material = material;

		hit_record.data.triangles = cachelets[i].m_cuda_triangles;
		hit_record.data.vertices = cachelets[i].m_cuda_vertices;

		// Import textures if necessary
		// TODO: method?
		if (mat.has_albedo()) {
			const ImageData &diffuse = TextureManager::load_texture(
				*m_phdev, *m_device, mat.albedo_texture
			);

			hit_record.data.textures.diffuse
				= cuda::import_vulkan_texture(*m_device, diffuse);
			hit_record.data.textures.has_diffuse = true;
		}

		if (mat.has_normal()) {
			const ImageData &normal = TextureManager::load_texture(
				*m_phdev, *m_device, mat.normal_texture
			);

			hit_record.data.textures.normal
				= cuda::import_vulkan_texture(*m_device, normal);
			hit_record.data.textures.has_normal = true;
		}

		if (mat.has_specular()) {
			const ImageData &specular = TextureManager::load_texture(
				*m_phdev, *m_device, mat.specular_texture
			);

			hit_record.data.textures.specular
				= cuda::import_vulkan_texture(*m_device, specular);
			hit_record.data.textures.has_specular = true;
		}

		if (mat.has_emission()) {
			const ImageData &emission = TextureManager::load_texture(
				*m_phdev, *m_device, mat.emission_texture
			);

			hit_record.data.textures.emission
				= cuda::import_vulkan_texture(*m_device, emission);
			hit_record.data.textures.has_emission = true;
		}

		if (mat.has_roughness()) {
			const ImageData &roughness = TextureManager::load_texture(
				*m_phdev, *m_device, mat.roughness_texture
			);

			hit_record.data.textures.roughness
				= cuda::import_vulkan_texture(*m_device, roughness);
			hit_record.data.textures.has_roughness = true;
		}

		// Push back
		m_host.hit_records.push_back(hit_record);
	}
}

// Preprocess scene data

// TODO: get rid of this method..
std::optional <OptixTraversableHandle>
ArmadaRTX::preprocess_scene
		(const ECS &ecs,
		const Camera &camera,
		const Transform &transform)
{
	// To return
	std::optional <OptixTraversableHandle> handle;

	// Set viewing position
	m_launch_info.camera.center = transform.position;
	
	auto uvw = kobra::uvw_frame(camera, transform);

	m_launch_info.camera.ax_u = uvw.u;
	m_launch_info.camera.ax_v = uvw.v;
	m_launch_info.camera.ax_w = uvw.w;

	m_launch_info.camera.projection = camera.perspective_matrix();
	m_launch_info.camera.view = camera.view_matrix(transform);

	// Get time
	m_launch_info.time = m_timer.elapsed_start();

	// Update the raytracing system
	bool updated = m_system->update(ecs);

	// Preprocess the entities
	std::vector <const Renderable *> rasterizers;
	std::vector <const Transform *> rasterizer_transforms;

	std::vector <const Light *> lights;
	std::vector <const Transform *> light_transforms;

	for (int i = 0; i < ecs.size(); i++) {
		// TODO: one unifying renderer component, with options for
		// raytracing, etc
		if (ecs.exists <Renderable> (i)) {
			const auto *rasterizer = &ecs.get <Renderable> (i);
			const auto *transform = &ecs.get <Transform> (i);

			rasterizers.push_back(rasterizer);
			rasterizer_transforms.push_back(transform);
		}
		
		if (ecs.exists <Light> (i)) {
			const auto *light = &ecs.get <Light> (i);
			const auto *transform = &ecs.get <Transform> (i);

			lights.push_back(light);
			light_transforms.push_back(transform);
		}
	}

	// Update data if necessary 
	if (updated || m_tlas.null) {
		// Load the list of all submeshes
		std::vector <layers::MeshMemory::Cachelet> cachelets; // TODO: redo this
							      // method...
		std::vector <const Submesh *> submeshes;
		std::vector <const Transform *> submesh_transforms;

		for (int i = 0; i < rasterizers.size(); i++) {
			const Renderable *rasterizer = rasterizers[i];
			const Transform *transform = rasterizer_transforms[i];

			// Cache the renderables
			// TODO: all update functions should go to a separate methods
			m_mesh_memory->cache_cuda(rasterizer);

			for (int j = 0; j < rasterizer->mesh->submeshes.size(); j++) {
				const Submesh *submesh = &rasterizer->mesh->submeshes[j];

				cachelets.push_back(m_mesh_memory->get(rasterizer, j));
				submeshes.push_back(submesh);
				submesh_transforms.push_back(transform);
			}
		}

		// Update the data
		update_light_buffers(
			lights, light_transforms,
			submeshes, submesh_transforms
		);

		update_sbt_data(cachelets, submeshes, submesh_transforms);

		// Reset the number of samples stored
		m_launch_info.samples = 0;

		// Update TLAS state
		m_tlas.null = false;
		m_tlas.last_updated = clock();

		// Update the status
		updated = true;
	}
		
	// Create acceleration structure for the attachment if needed
	// assuming that there is currently a valid attachment
	long long int attachment_time = m_tlas.times[m_previous_attachment];
	if (attachment_time < m_tlas.last_updated) {
		// Create the acceleration structure
		m_tlas.times[m_previous_attachment] = m_tlas.last_updated;
		handle = m_system->build_tlas(
			rasterizers,
			m_attachments[m_previous_attachment]->m_hit_group_count
		);
	}

	return handle;
}

// Path tracing computation
void ArmadaRTX::render(const ECS &ecs,
		const Camera &camera,
		const Transform &transform,
		bool accumulate)
{
	// Skip and warn if no active attachment
	if (m_active_attachment.empty()) {
		KOBRA_LOG_FUNC(Log::WARN) << "No active attachment\n";
		return;
	}

	// Compare with previous attachment
	if (m_active_attachment != m_previous_attachment) {
		if (m_previous_attachment.size() > 0)
			m_attachments[m_previous_attachment]->unload();

		m_previous_attachment = m_active_attachment;
		m_attachments[m_previous_attachment]->load();
	}

	auto handle = preprocess_scene(ecs, camera, transform);

	// Reset the accumulation state if needed
	if (!accumulate)
		m_launch_info.samples = 0;

	// Invoke render for current attachment
	auto &attachment = m_attachments[m_previous_attachment];
	attachment->render(this, m_launch_info, handle, m_extent);

	// Increment number of samples
	m_launch_info.samples++;
}

}

}
