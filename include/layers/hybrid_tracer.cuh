#ifndef KOBRA_LAYERS_HYBRID_TRACER_H_
#define KOBRA_LAYERS_HYBRID_TRACER_H_

// Standard headers
#include <map>
#include <vector>

// OptiX headers
#include <optix.h>
#include <optix_stubs.h>

// Engine headers
#include "../backend.hpp"
#include "../optix/parameters.cuh"
#include "../timer.hpp"
#include "../vertex.hpp"

namespace kobra {

// Forward declarations
class ECS;
class Camera;
class Transform;
class Rasterizer;

namespace layers {

// Hybrid ray/path tracer:
//	Rasterizes the scene to get the G-buffer, which is then used for ray/path
//	tracing and producing effects like GI and reflections.
struct HybridTracer {
	// Critical Vulkan structures
	vk::raii::Device *device = nullptr;
	vk::raii::PhysicalDevice *phdev = nullptr;
	vk::raii::DescriptorPool *descriptor_pool = nullptr;

	vk::raii::CommandBuffer cmd = nullptr;
	vk::raii::Queue queue = nullptr;

	// Geometry buffers
	ImageData positions = nullptr;
	ImageData normals = nullptr;
	ImageData ids = nullptr;

	// Material buffers
	ImageData albedo = nullptr;
	ImageData specular = nullptr;
	ImageData extra = nullptr;

	// Buffers as CUDA textures
	struct {
		cudaTextureObject_t positions = 0;
		cudaTextureObject_t normals = 0;
		cudaTextureObject_t ids = 0;

		cudaTextureObject_t albedo = 0;
		cudaTextureObject_t specular = 0;
		cudaTextureObject_t extra = 0;

		cudaTextureObject_t envmap = 0;
	} cuda_tex;

	// CUDA launch stream
	CUstream optix_stream = 0;

	// Depth buffer
	DepthBuffer depth = nullptr;

	// Vulkan structures
	vk::raii::RenderPass gbuffer_render_pass = nullptr;
	vk::raii::RenderPass present_render_pass = nullptr;
	vk::raii::Framebuffer framebuffer = nullptr;

	vk::raii::Pipeline gbuffer_pipeline = nullptr;
	vk::raii::Pipeline present_pipeline = nullptr;

	vk::raii::PipelineLayout gbuffer_ppl = nullptr;
	vk::raii::PipelineLayout present_ppl = nullptr;

	vk::Extent2D extent = { 0, 0 };

	// Descriptor set bindings
	static const std::vector <DSLB> gbuffer_dsl_bindings;
	static const std::vector <DSLB> present_dsl_bindings;

	// Descriptor set layout
	vk::raii::DescriptorSetLayout gbuffer_dsl = nullptr;
	vk::raii::DescriptorSetLayout present_dsl = nullptr;

	// Descriptor sets
	using RasterizerDset = std::vector <vk::raii::DescriptorSet>;

	std::map <const Rasterizer *, RasterizerDset> gbuffer_dsets;
	vk::raii::DescriptorSet present_dset = nullptr;

	// Optix structures
	OptixDeviceContext optix_context = nullptr;
	OptixModule optix_module = nullptr;
	OptixPipeline optix_pipeline = nullptr;
	OptixShaderBindingTable optix_sbt = {};

	struct {
		OptixTraversableHandle handle = 0;
	} optix;

	// Program groups
	struct {
		OptixProgramGroup raygen = nullptr;
		OptixProgramGroup miss = nullptr;
		OptixProgramGroup hit = nullptr;

		OptixProgramGroup shadow_miss = nullptr;
		OptixProgramGroup shadow_hit = nullptr;
	} optix_programs;

	// Launch parameters
	optix::HT_Parameters launch_params;

	CUdeviceptr launch_params_buffer = 0;
	CUdeviceptr truncated = 0;

	// Host buffer analogues
	struct {
		std::vector <optix::QuadLight> quad_lights;
	} host;

	// Cached data
	struct {
		std::vector <const Rasterizer *> rasterizers;
	} cache;

	// Timer
	Timer timer;

	// Output buffer
	std::vector <uint32_t> color_buffer;

	// Data for rendering
	ImageData result_image = nullptr;
	BufferData result_buffer = nullptr;
	vk::raii::Sampler result_sampler = nullptr;

	// Functions
	static HybridTracer make(const Context &);
};

// Other methods
void set_envmap(HybridTracer &, const std::string &);
void capture(HybridTracer &, std::vector <uint8_t> &);

void compute(HybridTracer &, const ECS &, const Camera &, const Transform &, bool = false);

void render(HybridTracer &,
	const vk::raii::CommandBuffer &,
	const vk::raii::Framebuffer &,
	const RenderArea & = {{-1, -1}, {-1, -1}});

}

}

#endif
